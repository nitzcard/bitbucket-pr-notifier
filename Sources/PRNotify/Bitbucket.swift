import Foundation

struct PullRequest: Identifiable, Equatable, Decodable {
    let id: Int
    let title: String
    let url: URL
    let author: String
    let createdOn: Date
    let updatedOn: Date
    /// UUIDs of participants who approved.
    let approvers: Set<String>
    /// UUIDs of participants who commented or approved (Bitbucket sets
    /// `participated_on` for either).
    let participants: Set<String>

    private enum CodingKeys: String, CodingKey { case id, title, links, author, created_on, updated_on, participants }
    private struct Participant: Decodable {
        struct User: Decodable { let uuid: String? }
        let user: User?
        let approved: Bool?
        let participated_on: String?
    }
    private struct Links: Decodable { let html: Href }
    private struct Href: Decodable { let href: URL }
    private struct Author: Decodable { let display_name: String }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(Links.self, forKey: .links).html.href
        author = (try? c.decode(Author.self, forKey: .author).display_name) ?? "Unknown"
        createdOn = try c.decode(Date.self, forKey: .created_on)
        updatedOn = (try? c.decode(Date.self, forKey: .updated_on)) ?? createdOn
        let participants = (try? c.decode([Participant].self, forKey: .participants)) ?? []
        approvers = Set(participants.filter { $0.approved == true }.compactMap { $0.user?.uuid })
        self.participants = Set(participants.filter { $0.approved == true || $0.participated_on != nil }
            .compactMap { $0.user?.uuid })
    }

    /// "Maya Gal · 💬 3 · ✅ · ⏰ 15:30": my comments, approval and reminder, when present.
    func details(me: String?, myComments: Int, reminder: Reminder?) -> String {
        var parts = [author]
        if myComments > 0 { parts.append("💬 \(myComments)") }
        if let me, approvers.contains(me) { parts.append("✅") }
        if let reminder { parts.append(reminder.badge) }
        return parts.joined(separator: " · ")
    }

    /// Unreviewed by `me`: no comment and no approval yet.
    func isUnreviewed(by me: String?) -> Bool {
        guard let me else { return true }
        return !participants.contains(me)
    }
}

struct BitbucketUser: Decodable {
    let uuid: String
    let display_name: String
}

enum BitbucketError: LocalizedError {
    /// 401: wrong email/token, or the token expired or was revoked.
    case unauthorized(String? = nil)
    /// Any other failure, with Bitbucket's own error message when it sent one.
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let message):
            return "Bitbucket rejected the sign-in (HTTP 401)" + (message.map { ": \($0)" } ?? ".")
                + " Check the email is your Atlassian account email and the token is a Bitbucket-scoped API token."
        case .http(403, let message):
            return "Permission denied (HTTP 403)" + (message.map { ": \($0)" } ?? ".")
                + " The token may be missing a scope."
        case .http(let code, let message):
            return "Bitbucket returned HTTP \(code)" + (message.map { ": \($0)" } ?? ".")
        }
    }

    /// Extracts `error.message` from Bitbucket's JSON error body.
    static func message(from data: Data) -> String? {
        struct Body: Decodable { struct Detail: Decodable { let message: String? }; let error: Detail? }
        if let message = (try? JSONDecoder().decode(Body.self, from: data))?.error?.message { return message }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty || text.hasPrefix("<") ? nil : String(text.prefix(200))
    }
}

struct BitbucketClient {
    /// Value of the Authorization header: Basic for API tokens, Bearer for OAuth.
    let authorization: String

    init(email: String, token: String) {
        authorization = "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }

    init(accessToken: String) {
        authorization = "Bearer \(accessToken)"
    }

    private static let base = URL(string: "https://api.bitbucket.org/2.0")!

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }()

    func currentUser() async throws -> BitbucketUser {
        try await get(Self.base.appending(path: "user"))
    }

    /// Full names ("workspace/repo") of every repo the user is a member of.
    func repositories() async throws -> [String] {
        struct Workspace: Decodable { let workspace: Slug }
        struct Slug: Decodable { let slug: String }
        struct Repo: Decodable { let full_name: String }

        var workspaces = Self.base.appending(path: "user/workspaces")
        workspaces.append(queryItems: [.init(name: "pagelen", value: "100")])
        let slugs = try await getAllPages(workspaces, as: Workspace.self).map(\.workspace.slug)

        var names: [String] = []
        for slug in slugs {
            var url = Self.base.appending(path: "repositories/\(slug)")
            url.append(queryItems: [
                .init(name: "role", value: "member"),
                .init(name: "pagelen", value: "100"),
                .init(name: "fields", value: "next,values.full_name"),
            ])
            names += try await getAllPages(url, as: Repo.self).map(\.full_name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Open PRs in `repo` where `reviewerUUID` is a reviewer, newest first.
    func pullRequests(repo: String, reviewerUUID: String) async throws -> [PullRequest] {
        var url = Self.base.appending(path: "repositories/\(repo)/pullrequests")
        url.append(queryItems: [
            .init(name: "q", value: "state=\"OPEN\" AND reviewers.uuid=\"\(reviewerUUID)\""),
            .init(name: "pagelen", value: "50"),
            .init(name: "fields", value: "next,values.id,values.title,values.links.html,values.author.display_name,values.created_on,values.updated_on,values.participants.user.uuid,values.participants.approved,values.participants.participated_on"),
        ])
        return try await getAllPages(url, as: PullRequest.self).sorted { $0.createdOn > $1.createdOn }
    }

    /// Number of (non-deleted) comments `uuid` left on a PR.
    func commentCount(repo: String, prID: Int, by uuid: String) async throws -> Int {
        struct Comment: Decodable {}
        var url = Self.base.appending(path: "repositories/\(repo)/pullrequests/\(prID)/comments")
        url.append(queryItems: [
            .init(name: "q", value: "user.uuid=\"\(uuid)\" AND deleted=false"),
            .init(name: "pagelen", value: "100"),
            .init(name: "fields", value: "next,values.id"),
        ])
        return try await getAllPages(url, as: Comment.self).count
    }

    private struct Page<T: Decodable>: Decodable {
        let values: [T]
        let next: URL?
    }

    private func getAllPages<T: Decodable>(_ url: URL, as: T.Type) async throws -> [T] {
        var results: [T] = []
        var next: URL? = url
        while let url = next {
            let page: Page<T> = try await get(url)
            results += page.values
            next = page.next
        }
        return results
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw BitbucketError.unauthorized(BitbucketError.message(from: data)) }
        guard (200..<300).contains(status) else { throw BitbucketError.http(status, BitbucketError.message(from: data)) }
        return try Self.decoder.decode(T.self, from: data)
    }
}
