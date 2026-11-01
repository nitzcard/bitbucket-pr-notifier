import AppKit
import OSLog

private let log = Logger(subsystem: "io.github.bitbucketprnotifier", category: "slack")

/// Someone the app can message on Slack, by their member ID ("U0123ABCD":
/// their profile → ⋯ → Copy member ID).
struct SlackPerson: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var memberID: String

    private enum CodingKeys: String, CodingKey { case name, memberID }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

/// Sends a DM through a Slack Workflow Builder webhook: a workflow that starts
/// "From a webhook" with the variables `user_id` (Slack user ID) and `message`
/// (text), and one step, "Send a message to" `user_id` saying `message`.
/// No Slack app or token involved; the webhook URL is the only secret.
struct SlackWebhook {
    let url: URL

    struct Failure: LocalizedError {
        let status: Int
        let message: String?
        var errorDescription: String? { "Slack returned HTTP \(status)" + (message.map { ": \($0)" } ?? ".") }
    }

    func send(_ text: String, to memberID: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["user_id": memberID, "message": text])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Body: Decodable { let error: String? }
            throw Failure(status: status, message: (try? JSONDecoder().decode(Body.self, from: data))?.error)
        }
    }
}

/// Sends a DM as the user, through the Slack Web API with a user token
/// (`xoxp-…`) of a Slack app with the user scopes `im:write` and `chat:write`.
struct SlackUserAPI {
    let token: String
    var base = URL(string: "https://slack.com/api")!

    struct Failure: LocalizedError {
        let error: String
        var errorDescription: String? { "Slack returned “\(error)”." }
    }

    private struct Reply: Decodable {
        struct Channel: Decodable { let id: String }
        let ok: Bool
        let error: String?
        let channel: Channel?
    }

    func send(_ text: String, to memberID: String) async throws {
        let dm = try await call("conversations.open", ["users": memberID])
        guard let channel = dm.channel?.id else { throw Failure(error: "no_channel") }
        _ = try await call("chat.postMessage", ["channel": channel, "text": text])
    }

    private func call(_ method: String, _ body: [String: String]) async throws -> Reply {
        var request = URLRequest(url: base.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.ok else { throw Failure(error: reply.error ?? "unknown_error") }
        return reply
    }
}

enum Slack {
    /// Without a webhook: puts `text` on the clipboard and opens the person's DM,
    /// ready for ⌘V and Return. With no workspace ID, Slack just opens.
    static func openDM(memberID: String, team: String, text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let dm = team.isEmpty ? nil : URL(string: "slack://user?team=\(team)&id=\(memberID)")
        NSWorkspace.shared.open(dm ?? URL(string: "slack://open")!)
    }

    static func nagText(_ pr: PullRequest, to person: SlackPerson) -> String {
        "Hi \(person.firstName), could you review my pull request \"\(pr.title)\"? \(pr.url.absoluteString)"
    }

    static func mergeText(_ pr: PullRequest, to person: SlackPerson) -> String {
        "Hi \(person.firstName), \"\(pr.title)\" is approved. Could you merge it? \(pr.url.absoluteString)"
    }
}

extension AppModel {
    var slackWebhookURL: URL? {
        let text = slackWebhook.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : URL(string: text)
    }

    var slackUserToken: String? {
        let text = slackToken.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Sends as the user with their token, else through the webhook. Without either, `interactive` (the user just
    /// clicked) opens the DM right away; otherwise a notification offers to.
    @discardableResult
    func sendSlack(_ text: String, to person: SlackPerson, interactive: Bool) async -> Bool {
        if let token = slackUserToken {
            do {
                var api = SlackUserAPI(token: token)
                if let base = ProcessInfo.processInfo.environment["SLACK_API_BASE"].flatMap(URL.init(string:)) { api.base = base }
                try await api.send(text, to: person.memberID)
                log.info("sent slack message as user to \(person.memberID, privacy: .public)")
                return true
            } catch {
                log.error("slack send failed: \(error.localizedDescription, privacy: .public)")
                Notifier.reportSlackFailure(error, to: person)
                return false
            }
        }
        guard let webhook = slackWebhookURL else {
            if interactive {
                Slack.openDM(memberID: person.memberID, team: slackTeam, text: text)
            } else {
                Notifier.offerSlackMessage(text, to: person, team: slackTeam)
            }
            return true
        }
        do {
            try await SlackWebhook(url: webhook).send(text, to: person.memberID)
            log.info("sent slack message to \(person.memberID, privacy: .public)")
            return true
        } catch {
            log.error("slack send failed: \(error.localizedDescription, privacy: .public)")
            Notifier.reportSlackFailure(error, to: person)
            return false
        }
    }
}

/// Filling in member IDs with an AI assistant that can search Slack: the
/// prompt names everyone still missing one, and its answer ("Name: U0123…"
/// lines) is pasted back.
extension AppModel {
    /// Mergers without a member ID yet.
    var peopleMissingMemberIDs: [String] {
        let names = mergers.filter { $0.memberID.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.name.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    var memberIDPrompt: String {
        """
        Using Slack's user search, find the Slack member ID (it starts with U) of each person below. \
        If someone has more than one account, use the one with my company email. \
        Reply with one line per person, exactly "Name: ID", and nothing else.

        """ + peopleMissingMemberIDs.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Fills in member IDs from "Name: U0123ABCD" lines, matching names
    /// without regard to case. Returns how many it filled.
    @discardableResult
    func fillMemberIDs(from answer: String) -> Int {
        var found: [String: String] = [:]
        for line in answer.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: #/\b([UW][A-Z0-9]{6,})\b/#) else { continue }
            let name = line[..<match.range.lowerBound]
                .trimmingCharacters(in: CharacterSet(charactersIn: "-–—:|*•` ").union(.whitespaces))
            if !name.isEmpty { found[name.lowercased()] = String(match.1) }
        }
        var filled = 0
        for i in mergers.indices where mergers[i].memberID.trimmingCharacters(in: .whitespaces).isEmpty {
            if let id = found[mergers[i].name.trimmingCharacters(in: .whitespaces).lowercased()] {
                mergers[i].memberID = id
                filled += 1
            }
        }
        return filled
    }
}
