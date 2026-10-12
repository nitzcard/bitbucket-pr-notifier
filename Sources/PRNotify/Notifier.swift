import AppKit
import OSLog
import UserNotifications

private let log = Logger(subsystem: "io.github.prnotify", category: "notifications")

/// Posts Slack-style banners and routes clicks: a single PR opens in the
/// browser, a grouped notification opens the main window.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onOpenWindow: (() -> Void)?

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

    /// System Settings → Notifications → PR Notify.
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

    // Show banners even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let url = (response.notification.request.content.userInfo["url"] as? String).flatMap(URL.init(string:))
        DispatchQueue.main.async {
            if let url {
                NSWorkspace.shared.open(url)
            } else {
                self.onOpenWindow?()
            }
            completionHandler()
        }
    }
}
