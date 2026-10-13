import Foundation
import Network

/// A tiny HTTP server standing in for api.bitbucket.org (and GitHub's
/// releases API). Tests change its state to make PRs appear or tokens expire.
final class MockBitbucket: @unchecked Sendable {
    struct PR {
        var id: Int
        var title: String
        var author: String
        var approvedByMe = false
        var myComments = 0
    }

    static let email = "ada@example.com"
    static let token = "good-token"
    static let userUUID = "{ada-uuid}"
    static let displayName = "Ada Lovelace"
    static let latestVersion = "99.0.0"

    private let lock = NSLock()
    private var _pullRequests: [PR] = []
    private var _rejectsTokens = false
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock-bitbucket")
    private(set) var port: UInt16 = 0

    var apiURL: String { "http://127.0.0.1:\(port)/2.0" }
    var releasesURL: String { "http://127.0.0.1:\(port)/releases/latest" }

    var pullRequests: [PR] {
        get { lock.withLock { _pullRequests } }
        set { lock.withLock { _pullRequests = newValue } }
    }
    /// Answers every Bitbucket request with 401, like an expired token.
    var rejectsTokens: Bool {
        get { lock.withLock { _rejectsTokens } }
        set { lock.withLock { _rejectsTokens = newValue } }
    }

    static let defaultPullRequests = [
        PR(id: 2, title: "Add dark mode to the dashboard", author: "Grace Hopper", approvedByMe: true, myComments: 2),
        PR(id: 1, title: "Fix login redirect loop", author: "Alan Turing"),
    ]

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] in self?.handle($0) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw TestFailure("Mock server didn't start")
        }
        self.port = port
    }

    func reset() {
        lock.withLock {
            _pullRequests = Self.defaultPullRequests
            _rejectsTokens = false
        }
    }

    // MARK: HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let (status, body) = self.respond(to: head)
                let response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
                    + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                    + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String) -> (Int, String) {
        let lines = head.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let path = URLComponents(string: target)?.path ?? target
        let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }
            .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) }

        if path == "/releases/latest" {
            return (200, json(["tag_name": "v\(Self.latestVersion)", "html_url": "https://example.com/releases"]))
        }
        let expected = "Basic " + Data("\(Self.email):\(Self.token)".utf8).base64EncodedString()
        guard authorization == expected, !rejectsTokens else {
            return (401, json(["error": ["message": "Invalid credentials"]]))
        }

        let parts = path.split(separator: "/").map(String.init)
        switch parts {
        case ["2.0", "user"]:
            return (200, json(["uuid": Self.userUUID, "display_name": Self.displayName]))
        case ["2.0", "user", "workspaces"]:
            return (200, page([["workspace": ["slug": "acme"]]]))
        case ["2.0", "repositories", "acme"]:
            return (200, page([["full_name": "acme/api"], ["full_name": "acme/web"]]))
        case ["2.0", "repositories", "acme", "web", "pullrequests"]:
            return (200, page(pullRequests.map(prJSON)))
        case ["2.0", "repositories", "acme", "api", "pullrequests"]:
            return (200, page([]))
        default:
            if parts.count == 7, parts[3] == "web", parts[6] == "comments", let id = Int(parts[5]),
               let pr = pullRequests.first(where: { $0.id == id }) {
                return (200, page((0..<pr.myComments).map { ["id": $0] }))
            }
            return (404, json(["error": ["message": "Not found: \(path)"]]))
        }
    }

    private func prJSON(_ pr: PR) -> [String: Any] {
        // Newer PRs (higher ids) were opened later.
        let created = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: Double(pr.id - 100) * 3600))
        var participants: [[String: Any]] = []
        if pr.approvedByMe || pr.myComments > 0 {
            participants.append(["user": ["uuid": Self.userUUID], "approved": pr.approvedByMe, "participated_on": created])
        }
        return [
            "id": pr.id,
            "title": pr.title,
            "links": ["html": ["href": "https://bitbucket.example/acme/web/pull-requests/\(pr.id)"]],
            "author": ["display_name": pr.author],
            "created_on": created,
            "updated_on": created,
            "participants": participants,
        ]
    }

    private func page(_ values: [[String: Any]]) -> String { json(["values": values]) }

    private func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
