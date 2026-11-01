import Foundation
import OSLog

private let log = Logger(subsystem: "io.github.bitbucketprnotifier", category: "nags")

/// Slack messages about one of my PRs to the repo's mergers: once at a time, or
/// now and then every interval, until the PR is merged or declined. Sent by the
/// app itself, so only while it runs (a missed one goes out at the next launch).
struct ReviewerNag: Codable, Equatable {
    var kind: Reminder.Kind
    /// Slack member IDs of the mergers to message.
    var recipients: Set<String>
    var next: Date

    /// Fewer messages to a coworker than this would be spam.
    static let minSeconds: TimeInterval = 15 * 60

    /// "Nag mergers at 15:30", "Nag mergers every 2 hr".
    var text: String {
        switch kind {
        case .once: "Nag mergers at \(kind.shortText)"
        case .nag: "Nag mergers \(kind.shortText)"
        }
    }
}

extension AppModel {

    /// My PRs someone has approved, the ones a merger can be asked about.
    var approvedPullRequests: [PullRequest] { myPullRequests.filter { !$0.approvers.isEmpty } }

    /// Mergers with a member ID filled in, trimmed.
    var readyMergers: [SlackPerson] {
        mergers.compactMap { person in
            let id = person.memberID.trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : SlackPerson(id: person.id, name: person.name, memberID: id)
        }
    }

    /// Messages the chosen mergers (by member ID) now, without scheduling anything.
    func nagNow(_ pr: PullRequest, recipients: Set<String>) async {
        for person in readyMergers where recipients.contains(person.memberID) {
            await sendSlack(Slack.nagText(pr, to: person), to: person, interactive: recipients.count == 1)
        }
    }

    /// A repeating nag sends its first message now.
    func setNag(_ kind: Reminder.Kind, recipients: Set<String>, for pr: PullRequest) {
        let next: Date = if case .once(let date) = kind { date } else { Date() }
        nags[pr.id] = ReviewerNag(kind: kind, recipients: recipients, next: next)
        Task { await sendDueNags() }
    }

    func clearNag(for prID: Int) {
        log.info("clear nag pr=\(prID, privacy: .public)")
        nags[prID] = nil
    }

    /// Drops nags whose PR was merged or declined.
    func pruneNags(_ prs: [PullRequest]) {
        let open = Set(prs.map(\.id))
        for id in nags.keys where !open.contains(id) { clearNag(for: id) }
    }

    /// Sends every nag that's due. Each nag's next time is moved on before
    /// sending, so overlapping calls never send the same one twice.
    func sendDueNags() async {
        let now = Date()
        let due = nags.filter { $0.value.next <= now }
        for (id, nag) in due {
            switch nag.kind {
            case .once: nags[id] = nil
            case .nag(let interval): nags[id]?.next = now.addingTimeInterval(max(interval, ReviewerNag.minSeconds))
            }
        }
        for (id, nag) in due {
            guard let pr = myPullRequests.first(where: { $0.id == id }) else { continue }
            for person in readyMergers where nag.recipients.contains(person.memberID) {
                await sendSlack(Slack.nagText(pr, to: person), to: person, interactive: false)
            }
        }
    }

    /// Checks for due nags every 30 seconds while the app runs.
    func startNagging() {
        guard nagTask == nil else { return }
        nagTask = Task {
            while !Task.isCancelled {
                await sendDueNags()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func askToMerge(_ pr: PullRequest, merger: SlackPerson) async {
        if await sendSlack(Slack.mergeText(pr, to: merger), to: merger, interactive: true) {
            mergeAsked[pr.id] = merger.name
        }
    }

    /// When "ask to merge" is on for this repo, offers to ask a merger the
    /// first time each of my PRs is approved. The first check of a repo only
    /// notes which are already approved.
    func announceApprovals(_ prs: [PullRequest]) {
        let approved = Set(prs.filter { !$0.approvers.isEmpty }.map(\.id))
        if let known = approvedIDs, askToMerge, !readyMergers.isEmpty {
            for pr in prs where approved.contains(pr.id) && !known.contains(pr.id) {
                Notifier.offerToAskToMerge(pr)
            }
        }
        // Once approved stays announced (even if the approval is withdrawn) while the PR is open.
        let open = Set(prs.map(\.id))
        approvedIDs = (approvedIDs ?? []).union(approved).intersection(open)
        mergeAsked = mergeAsked.filter { open.contains($0.key) }
    }

    static func loadNags(repo: String?) -> [Int: ReviewerNag] {
        guard let repo, let data = UserDefaults.standard.data(forKey: "nags.\(repo)"),
              let stored = try? JSONDecoder().decode([Int: ReviewerNag].self, from: data) else { return [:] }
        return stored
    }

    static func loadMergers(repo: String?) -> [SlackPerson] {
        guard let repo, let data = UserDefaults.standard.data(forKey: "mergers.\(repo)"),
              let stored = try? JSONDecoder().decode([SlackPerson].self, from: data) else { return [] }
        return stored
    }
}
