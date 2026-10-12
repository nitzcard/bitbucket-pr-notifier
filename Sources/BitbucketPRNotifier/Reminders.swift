import AppKit
import OSLog
import UserNotifications

private let log = Logger(subsystem: "io.github.bitbucketprnotifier", category: "reminders")

/// A per-PR reminder: once at a time, or repeating ("nag"). Deleted when I
/// comment on or approve the PR, or when it leaves my list.
struct Reminder: Codable, Equatable {
    enum Kind: Codable, Equatable {
        case once(Date)
        case nag(TimeInterval)
    }

    var kind: Kind
    var title: String
    var author: String
    var url: URL

    static let presets: [(title: String, date: () -> Date)] = [
        ("In 1 Hour", { Date().addingTimeInterval(3600) }),
        ("In 2 Hours", { Date().addingTimeInterval(2 * 3600) }),
        ("Tomorrow at 11:00", {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            return Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: tomorrow)!
        }),
    ]

    /// Shortest nag. Under a minute macOS can't repeat a notification itself,
    /// so those nags are a topped-up series of one-time notifications.
    static let minNagSeconds: TimeInterval = 5

    /// "Remind at 15:30", "Remind Tue 9:00", "Nag every 6 sec", "Nag every 1.5 hr".
    var text: String {
        switch kind {
        case .once(let date):
            let formatter = DateFormatter()
            formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE H:mm"
            return "Remind at \(formatter.string(from: date))"
        case .nag(let interval):
            return "Nag every \(Self.duration(interval))"
        }
    }

    /// Bell for a one-time reminder; the two-arrow circle for a nag.
    var symbol: String {
        if case .nag = kind { "arrow.triangle.2.circlepath" } else { "bell" }
    }

    /// The time or interval alone, shown beside or under the reminder's symbol.
    var shortText: String {
        switch kind {
        case .once: return text.replacingOccurrences(of: "Remind at ", with: "")
        case .nag(let interval): return "every \(Self.duration(interval))"
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        if seconds < 60 { return "\(seconds.formatted(style)) sec" }
        if seconds < 3600 { return "\((seconds / 60).formatted(style)) min" }
        return "\((seconds / 3600).formatted(style)) hr"
    }
}

extension AppModel {
    func reminder(for pr: PullRequest) -> Reminder? { reminders[pr.id] }

    func setReminder(_ kind: Reminder.Kind, for pr: PullRequest) {
        guard let repo else { return }
        let reminder = Reminder(kind: kind, title: pr.title, author: pr.author, url: pr.url)
        reminders[pr.id] = reminder
        saveReminders()
        Notifier.schedule(reminder, id: Self.reminderID(repo: repo, pr: pr.id))
        Notifier.confirm(reminder)
    }

    /// `keepDelivered` leaves an already-shown reminder in Notification Center.
    func clearReminder(for prID: Int, keepDelivered: Bool = false) {
        guard let repo else { return }
        log.info("clear reminder pr=\(prID, privacy: .public) keepDelivered=\(keepDelivered, privacy: .public)")
        reminders[prID] = nil
        saveReminders()
        Notifier.cancel(id: Self.reminderID(repo: repo, pr: prID), keepDelivered: keepDelivered)
    }

    /// Drops reminders for PRs that are gone (merged or declined), and one-time
    /// reminders that already fired. Reviewing a PR keeps its reminder.
    func pruneReminders(_ prs: [PullRequest]) {
        let byID = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0) })
        for (id, reminder) in reminders {
            let gone = byID[id] == nil
            var fired = false
            if case .once(let date) = reminder.kind { fired = date < Date() }
            if gone { clearReminder(for: id) } else if fired { clearReminder(for: id, keepDelivered: true) }
        }
    }

    /// Restarts each sub-minute nag's series so it never runs dry while the app
    /// runs. They share 48 of the 64 pending-notification slots.
    func topUpFastNags() {
        guard let repo else { return }
        let fast = reminders.filter { if case .nag(let s) = $0.value.kind { return s < 60 } else { return false } }
        guard !fast.isEmpty else { return }
        for (id, reminder) in fast {
            Notifier.schedule(reminder, id: Self.reminderID(repo: repo, pr: id), slots: max(4, 48 / fast.count))
        }
    }

    static func reminderID(repo: String, pr: Int) -> String { "reminder.\(repo).\(pr)" }

    static func loadReminders(repo: String?) -> [Int: Reminder] {
        guard let repo, let data = UserDefaults.standard.data(forKey: "reminders.\(repo)"),
              let stored = try? JSONDecoder().decode([Int: Reminder].self, from: data) else { return [:] }
        return stored
    }

    private func saveReminders() {
        guard let repo, let data = try? JSONEncoder().encode(reminders) else { return }
        UserDefaults.standard.set(data, forKey: "reminders.\(repo)")
    }
}

extension Notifier {
    /// The system delivers these, so they fire even while the app isn't running.
    /// `slots` caps how many one-time notifications a sub-minute nag queues
    /// (macOS keeps at most 64 pending per app); refreshes top them up.
    static func schedule(_ reminder: Reminder, id: String, slots: Int = 48) {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.title = reminder.title
        content.body = reminder.author
        content.userInfo = ["url": reminder.url.absoluteString]
        content.threadIdentifier = id

        let center = UNUserNotificationCenter.current()
        removePending(prefix: id) {
            switch reminder.kind {
            case .once(let date):
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            case .nag(let interval) where interval >= 60:
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: true)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            case .nag(let interval):
                let step = max(interval, Reminder.minNagSeconds)
                for n in 1...max(slots, 1) {
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: step * Double(n), repeats: false)
                    center.add(UNNotificationRequest(identifier: "\(id).\(n)", content: content, trigger: trigger))
                }
            }
        }
    }

    /// Immediate confirmation that a reminder was set: PR title, then "Nag every 6 min".
    static func confirm(_ reminder: Reminder) {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.text
        content.userInfo = ["url": reminder.url.absoluteString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "confirm.\(UUID().uuidString)", content: content, trigger: nil))
    }

    static func cancel(id: String, keepDelivered: Bool = false) {
        removePending(prefix: id) {}
        guard !keepDelivered else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { $0 == id || $0.hasPrefix(id + ".") }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Removes the pending request `prefix` and its series (`prefix.1`, `prefix.2`…).
    private static func removePending(prefix: String, then: @escaping @Sendable () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ids = pending.map(\.identifier).filter { $0 == prefix || $0.hasPrefix(prefix + ".") }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            then()
        }
    }
}
