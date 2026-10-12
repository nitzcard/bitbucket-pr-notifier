import AppKit
import Network

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var isExpiring: Bool { expiresAt < Date().addingTimeInterval(60) }
}

/// "Sign in with Bitbucket": Authorization Code flow with a loopback redirect.
/// Bitbucket has no PKCE, so the consumer key and secret are baked into the app
/// at build time (see scripts/build-app.sh). Without them the option is hidden.
struct OAuthConfig {
    let clientID: String
    let secret: String

    static let bundled: OAuthConfig? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let id = info["BPRNOAuthClientID"] as? String, !id.isEmpty,
              let secret = info["BPRNOAuthClientSecret"] as? String, !secret.isEmpty else { return nil }
        return OAuthConfig(clientID: id, secret: secret)
    }()

    private static let authorizeURL = URL(string: "https://bitbucket.org/site/oauth2/authorize")!
    private static let tokenURL = URL(string: "https://bitbucket.org/site/oauth2/access_token")!

    /// Opens the browser, waits for Bitbucket to redirect back, and exchanges the code.
    func signIn() async throws -> OAuthTokens {
        let state = UUID().uuidString
        let server = LoopbackServer(state: state)
        let port = try await server.start()
        // Bitbucket ignores the port for loopback redirects, so the consumer's
        // callback URL is registered as plain http://localhost.
        let redirect = "http://localhost:\(port)/callback"

        var authorize = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "state", value: state),
            .init(name: "redirect_uri", value: redirect),
        ]
        NSWorkspace.shared.open(authorize.url!)

        let callback = try await server.waitForCallback()
        // The server only returns callbacks carrying our `state`.
        guard let code = callback.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw BitbucketError.unauthorized("The browser sign-in was not completed.")
        }
        return try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
        ])
    }

    /// Refresh tokens rotate: the response carries a new one to store.
    func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        try await requestTokens(["grant_type": "refresh_token", "refresh_token": tokens.refreshToken])
    }

    private func requestTokens(_ form: [String: String]) async throws -> OAuthTokens {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        let basic = Data("\(clientID):\(secret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 400 here means the code or refresh token is invalid: treat it as signed out.
        if (400..<500).contains(status) { throw BitbucketError.unauthorized(BitbucketError.message(from: data)) }
        guard (200..<300).contains(status) else { throw BitbucketError.http(status, BitbucketError.message(from: data)) }
        let tokens = try JSONDecoder().decode(Response.self, from: data)
        return OAuthTokens(accessToken: tokens.access_token,
                           refreshToken: tokens.refresh_token,
                           expiresAt: Date().addingTimeInterval(TimeInterval(tokens.expires_in)))
    }
}

/// A one-shot HTTP server on a random loopback port that catches the OAuth redirect.
/// It ignores requests without the expected `state`, so another local process or
/// a web page probing the port can't end the sign-in.
/// All mutable state is only touched on `queue`.
private final class LoopbackServer: @unchecked Sendable {
    private let state: String
    private let queue = DispatchQueue(label: "BitbucketPRNotifier.LoopbackServer")
    private var listener: NWListener?
    private var callback: CheckedContinuation<URLComponents, Error>?
    private var result: Result<URLComponents, Error>? // arrived before anyone waited

    init(state: String) { self.state = state }

    func start() async throws -> UInt16 {
        // Loopback only (IPv4 and IPv6, since "localhost" may resolve to either);
        // by default NWListener accepts connections on every interface.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            // Clearing the handler after the first terminal state guarantees a single resume.
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.handle($0) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URLComponents {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result) } else { self.callback = continuation }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            // Request line: "GET /callback?code=...&state=... HTTP/1.1"
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                .split(separator: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : ""

            guard target.hasPrefix("/callback"), let components = URLComponents(string: target),
                  components.queryItems?.first(where: { $0.name == "state" })?.value == self?.state else {
                Self.respond(connection, status: "404 Not Found", body: "")
                return
            }
            Self.respond(connection, status: "200 OK", body: """
                <html><body style="font-family: -apple-system; text-align: center; padding-top: 80px">
                <h2>Bitbucket PR Notifier is signed in</h2><p>You can close this tab.</p></body></html>
                """)
            self?.finish(.success(components))
        }
    }

    private func finish(_ result: Result<URLComponents, Error>) {
        guard self.result == nil else { return }
        self.result = result
        callback?.resume(with: result)
        callback = nil
        listener?.cancel()
        listener = nil
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
