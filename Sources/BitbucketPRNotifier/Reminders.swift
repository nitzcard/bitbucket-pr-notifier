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
    /// My comments and approval when it was set: a nag stops once I add a
    /// comment or approve. Reminders saved before these were kept count as 0.
    var myCommentsWhenSet: Int?
    var approvedWhenSet: Bool?

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

    /// "Remind at 15:30", "Remind at Tue 9:00", "Nag every 6 sec", "Nag every 1.5 hr".
    var text: String {
        switch kind {
        case .once: "Remind at \(kind.shortText)"
        case .nag: "Nag \(kind.shortText)"
        }
    }

    /// A sub-minute nag, kept going as a series of one-time notifications.
    var isFast: Bool { if case .nag(let s) = kind { s < 60 } else { false } }

    var symbol: String { kind.symbol }
    var shortText: String { kind.shortText }

    static func duration(_ seconds: TimeInterval) -> String {
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        if seconds < 60 { return "\(seconds.formatted(style)) sec" }
        if seconds < 3600 { return "\((seconds / 60).formatted(style)) min" }
        return "\((seconds / 3600).formatted(style)) hr"
    }
}

extension Reminder.Kind {
    /// Bell for a one-time reminder; the two-arrow circle for a nag.
    var symbol: String {
        if case .nag = self { "arrow.triangle.2.circlepath" } else { "bell" }
    }

    /// The time or interval alone ("15:30", "Tue 9:00", "every 6 min"), shown
    /// beside or under the symbol.
    var shortText: String {
        switch self {
        case .once(let date):
            let formatter = DateFormatter()
            formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE H:mm"
            return formatter.string(from: date)
        case .nag(let interval):
            return "every \(Reminder.duration(interval))"
        }
    }
}

extension AppModel {
    func reminder(for pr: PullRequest) -> Reminder? { reminders[pr.id] }

    func setReminder(_ kind: Reminder.Kind, for pr: PullRequest) {
        guard let repo else { return }
        let approved = userUUID.map { pr.approvers.contains($0) } ?? false
        let reminder = Reminder(kind: kind, title: pr.title, author: pr.author, url: pr.url,
                                myCommentsWhenSet: myCommentCount(pr), approvedWhenSet: approved)
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

    /// Drops reminders for PRs that are gone (merged or declined), one-time
    /// reminders that already fired, and nags on PRs I've since commented on
    /// or approved. A one-time reminder stays when I review the PR.
    func pruneReminders(_ prs: [PullRequest]) {
        let byID = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0) })
        for (id, reminder) in reminders {
            guard let pr = byID[id] else { clearReminder(for: id); continue }
            switch reminder.kind {
            case .once(let date):
                if date < Date() { clearReminder(for: id, keepDelivered: true) }
            case .nag:
                let approved = userUUID.map { pr.approvers.contains($0) } ?? false
                if myCommentCount(pr) > reminder.myCommentsWhenSet ?? 0 || (approved && reminder.approvedWhenSet != true) {
                    clearReminder(for: id)
                }
            }
        }
        removeOrphanedReminderNotifications()
    }

    /// Removes scheduled reminder notifications with no saved reminder behind
    /// them, such as a nag left by an older version of the app.
    private func removeOrphanedReminderNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ids = pending.map(\.identifier).filter { $0.hasPrefix("reminder.") }
            Task { @MainActor in
                let orphans = ids.filter { !Self.isSavedReminder($0) }
                guard !orphans.isEmpty else { return }
                log.info("removing \(orphans.count, privacy: .public) orphaned reminder notification(s)")
                center.removePendingNotificationRequests(withIdentifiers: orphans)
            }
        }
    }

    /// `reminder.<repo>.<pr>`, or `reminder.<repo>.<pr>.<n>` in a fast nag's series.
    private static func isSavedReminder(_ id: String) -> Bool {
        let parts = id.dropFirst("reminder.".count).components(separatedBy: ".")
        for series in [false, true] {
            let head = series ? parts.dropLast() : parts[...]
            guard head.count >= 2, let pr = Int(head.last!) else { continue }
            if loadReminders(repo: head.dropLast().joined(separator: "."))[pr] != nil { return true }
        }
        return false
    }

    /// Restarts each sub-minute nag's series so it never runs dry while the app
    /// runs. They share 48 of the 64 pending-notification slots.
    func topUpFastNags() {
        guard let repo else { return }
        let fast = reminders.filter { $0.value.isFast }
        guard !fast.isEmpty else { return }
        for (id, reminder) in fast {
            Notifier.schedule(reminder, id: Self.reminderID(repo: repo, pr: id), slots: max(4, 48 / fast.count))
        }
    }

    /// Clears every pending notification, then schedules this repo's saved
    /// reminders again. The system keeps scheduled notifications after the app
    /// forgets them (another repo's reminders, sign-out, older builds), and a
    /// repeating one would fire forever.
    func rescheduleReminders() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        guard let repo, isSignedIn else { return }
        for (id, reminder) in reminders where !reminder.isFast {
            Notifier.schedule(reminder, id: Self.reminderID(repo: repo, pr: id))
        }
        topUpFastNags()
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
