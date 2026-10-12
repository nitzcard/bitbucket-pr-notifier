import AppKit
import UserNotifications

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

    /// "⏰ 15:30" / "⏰ Tue 9:00" / "🔁 1h", for the PR's details line.
    var badge: String {
        switch kind {
        case .once(let date):
            let format = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE H:mm"
            let formatter = DateFormatter()
            formatter.dateFormat = format
            return "⏰ \(formatter.string(from: date))"
        case .nag(let interval):
            let minutes = Int(interval / 60)
            return "🔁 " + (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m")
        }
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
    }

    /// `keepDelivered` leaves an already-shown reminder in Notification Center.
    func clearReminder(for prID: Int, keepDelivered: Bool = false) {
        guard let repo else { return }
        reminders[prID] = nil
        saveReminders()
        Notifier.cancel(id: Self.reminderID(repo: repo, pr: prID), keepDelivered: keepDelivered)
    }

    /// Drops reminders for PRs that are gone or that I've reviewed, and one-time
    /// reminders that already fired.
    func pruneReminders(_ prs: [PullRequest]) {
        let byID = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0) })
        for (id, reminder) in reminders {
            let gone = byID[id].map { !$0.isUnreviewed(by: userUUID) } ?? true
            var fired = false
            if case .once(let date) = reminder.kind { fired = date < Date() }
            if gone { clearReminder(for: id) } else if fired { clearReminder(for: id, keepDelivered: true) }
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
    static func schedule(_ reminder: Reminder, id: String) {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.body = "by \(reminder.author)"
        content.userInfo = ["url": reminder.url.absoluteString]

        let trigger: UNNotificationTrigger
        switch reminder.kind {
        case .once(let date):
            content.title = "Reminder: \(reminder.title)"
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        case .nag(let interval):
            content.title = "Still waiting for your review: \(reminder.title)"
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 60), repeats: true)
        }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel(id: String, keepDelivered: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        if !keepDelivered { center.removeDeliveredNotifications(withIdentifiers: [id]) }
    }
}
