import Foundation

/// How a PR is described, shared by the menu bar menu and the window so both
/// read the same. Text only, per the 1987 HIG.
extension AppModel {
    /// "Rachel Green · 7 comments · Approved · Nag every 6 min". The window
    /// passes `includeReminder: false` because it shows the reminder on its bell.
    func details(for pr: PullRequest, includeReminder: Bool) -> String {
        var parts = [pr.author]
        let comments = myCommentCount(pr)
        if comments > 0 { parts.append(comments == 1 ? "1 comment" : "\(comments) comments") }
        if let userUUID, pr.approvers.contains(userUUID) { parts.append("Approved") }
        if includeReminder, let reminder = reminder(for: pr) { parts.append(reminder.text) }
        return parts.joined(separator: " · ")
    }

    /// "Grace Hopper: Approved · Alan Turing: Waiting · Asked Linus to merge".
    func myDetails(for pr: PullRequest, includeNag: Bool) -> String {
        var parts = pr.reviewers.map { "\($0.name): \($0.stateText)" }
        if parts.isEmpty { parts = ["No reviewers"] }
        if let merger = mergeAsked[pr.id] { parts.append("Asked \(merger) to merge") }
        if includeNag, let nag = nags[pr.id] { parts.append(nag.text) }
        return parts.joined(separator: " · ")
    }

    /// What the list shows instead of both sections, if anything: a dimmed
    /// line and the command that fixes it (opens Settings).
    var listPlaceholder: (text: String, action: String?)? {
        switch status {
        case .signedOut: ("Not Signed In", "Sign In…")
        case .noRepo: ("No Repository Chosen", "Choose Repository…")
        case .error(let text) where pullRequests.isEmpty && myPullRequests.isEmpty: (text, nil)
        default: nil
        }
    }

    static let noReviewsText = "No Pull Requests to Review"
    static let noMyPullRequestsText = "No Pull Requests of Yours"

    func remindCommand(for pr: PullRequest) -> String {
        reminder(for: pr) == nil ? "Remind Me About This…" : "Edit Reminder…"
    }

    func nagCommand(for pr: PullRequest) -> String {
        nags[pr.id] == nil ? "Nag Mergers…" : "Edit Nag…"
    }
}
