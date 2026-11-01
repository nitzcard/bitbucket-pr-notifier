import AppKit
import OSLog
import UserNotifications

private let log = Logger(subsystem: "io.github.bitbucketprnotifier", category: "notifications")

/// Posts Slack-style banners and routes clicks: a single PR opens in the
/// browser, a grouped notification opens the main window.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onOpenWindow: (() -> Void)?
    /// Opens the Ask to Merge sheet for a PR id.
    var onAskToMerge: ((Int) -> Void)?

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            log.info("authorization granted=\(granted, privacy: .public) error=\(String(describing: error), privacy: .public)")
            self.checkAuthorization()
        }
        // The user may toggle notifications in System Settings while we run.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in self.checkAuthorization() }
    }

    func checkAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
            Task { @MainActor in AppModel.shared.notificationsAllowed = allowed }
        }
    }

    /// System Settings → Notifications → Bitbucket PR Notifier.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!

    static func notify(_ prs: [PullRequest]) {
        guard !prs.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.sound = .default

        if prs.count == 1, let pr = prs.first {
            content.title = pr.title
            content.body = pr.author
            content.userInfo = ["url": pr.url.absoluteString]
        } else {
            content.title = "\(prs.count) Pull Requests"
            content.body = prs.map { "• \($0.title) — \($0.author)" }.joined(separator: "\n")
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        log.info("posting notification for \(prs.count, privacy: .public) new PR(s)")
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log.error("post failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// One of my PRs got its first approval; clicking opens Ask to Merge.
    static func offerToAskToMerge(_ pr: PullRequest) {
        let content = UNMutableNotificationContent()
        content.sound = .default
        let names = ListFormatter.localizedString(byJoining: pr.approverNames)
        let who = names.isEmpty ? "Someone has" : pr.approverNames.count == 1 ? "\(names) has" : "\(names) have"
        content.title = "Approved"
        content.body = "\(who) approved \u{201C}\(pr.title)\u{201D}. Click to ask someone to merge it."
        content.userInfo = ["askToMerge": pr.id]
        post(content, "approval for #\(pr.id)")
    }

    /// One of my PRs was merged; clicking opens it.
    static func announceMerge(title: String, url: URL) {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.title = "Merged"
        content.body = "\u{201C}\(title)\u{201D} has been merged."
        content.userInfo = ["url": url.absoluteString]
        post(content, "merge")
    }

    /// With no Slack webhook, a scheduled message can't send itself: clicking
    /// this copies it and opens the person's DM.
    static func offerSlackMessage(_ text: String, to person: SlackPerson, team: String) {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.title = "Message \(person.name) on Slack"
        content.body = text
        content.userInfo = ["slackMember": person.memberID, "slackTeam": team, "slackText": text]
        post(content, "slack prompt")
    }

    static func reportSlackFailure(_ error: Error, to person: SlackPerson) {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't Message \(person.name) on Slack"
        content.body = error.localizedDescription
        post(content, "slack failure")
    }

    private static func post(_ content: UNNotificationContent, _ what: String) {
        log.info("posting \(what, privacy: .public)")
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { log.error("post failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // Show banners even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        DispatchQueue.main.async {
            if let prID = info["askToMerge"] as? Int {
                self.onAskToMerge?(prID)
            } else if let member = info["slackMember"] as? String, let text = info["slackText"] as? String {
                Slack.openDM(memberID: member, team: info["slackTeam"] as? String ?? "", text: text)
            } else if let url {
                NSWorkspace.shared.open(url)
            } else {
                self.onOpenWindow?()
            }
            completionHandler()
        }
    }
}
