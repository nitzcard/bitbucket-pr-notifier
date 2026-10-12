import AppKit
import Observation

/// The menu bar item: icon + PR count, with a native menu that's rebuilt each
/// time it opens. Native menus highlight on hover and close after a click.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model = AppModel.shared
    private var openMenu: NSMenu?
    /// Menus grow to their widest item, so long PR titles are cut to one line.
    private static let maxTitleLength = 60

    override init() {
        super.init()
        item.button?.image = IconArt.menuBarImage()
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateButton()
    }

    /// Keeps the count next to the icon in sync with the model, and refreshes
    /// the menu's items live if it's open (e.g. when loading finishes).
    private func updateButton() {
        withObservationTracking {
            let count = model.pullRequests.count
            item.button?.title = count > 0 ? " \(count)" : ""
            _ = model.showsSkeleton
            _ = model.status
            _ = model.notificationsAllowed
            _ = model.autoRefresh
            if let openMenu { menuNeedsUpdate(openMenu) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateButton() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        openMenu = menu
        Notifier.shared.checkAuthorization()
    }
    func menuDidClose(_ menu: NSMenu) { openMenu = nil }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let me = model.userUUID

        // Only worth a line when something is wrong: new PRs would go unannounced.
        if !model.notificationsAllowed {
            menu.addItem(action("Turn On Notifications…", #selector(openNotificationSettings)))
            menu.addItem(.separator())
        }

        if let repo = model.repo {
            let header = action(repo, #selector(openRepo))
            header.attributedTitle = NSAttributedString(string: repo, attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            ])
            menu.addItem(header)
            menu.addItem(.separator())
        }

        switch model.status {
        case _ where model.showsSkeleton:
            for width in [34, 27, 31] { menu.addItem(Self.skeletonItem(width: width)) }
        case .signedOut:
            menu.addItem(action("Sign In…", #selector(openSettings)))
        case .noRepo:
            menu.addItem(action("Choose Repository…", #selector(openSettings)))
        case .error(let text) where model.pullRequests.isEmpty:
            menu.addItem(disabled(text))
        default:
            if model.pullRequests.isEmpty {
                menu.addItem(disabled("No Pull Requests to Review"))
            }
            for pr in model.pullRequests {
                let row = action(pr.title, #selector(openPR(_:)))
                row.representedObject = pr.url
                row.attributedTitle = Self.twoLineTitle(pr.title, details: NSAttributedString(string: model.details(for: pr, includeReminder: true)))
                menu.addItem(row)
                // Holding ⌥ swaps the row for its reminder action (standard Mac alternate item).
                if pr.isUnreviewed(by: me) {
                    let alt = action(model.reminder(for: pr) == nil ? "Remind Me About This…" : "Edit Reminder…",
                                     #selector(remindAbout(_:)))
                    alt.attributedTitle = Self.twoLineTitle(alt.title, details: NSAttributedString(string: Self.truncate(pr.title)))
                    alt.representedObject = pr.id
                    alt.isAlternate = true
                    alt.keyEquivalentModifierMask = [.option]
                    menu.addItem(alt)
                }
            }
        }

        // Commands that act on the list sit right below it. Item names stay
        // fixed; an item that can't apply is dimmed rather than renamed or hidden.
        menu.addItem(.separator())
        let openAll = action("Open Unreviewed Pull Requests", #selector(openUnreviewed))
        if !model.pullRequests.contains(where: { $0.isUnreviewed(by: me) }) { openAll.action = nil }
        menu.addItem(openAll)
        let remind = action("Remind Me…", #selector(openReminder))
        if !model.pullRequests.contains(where: { $0.isUnreviewed(by: me) }) { remind.action = nil }
        menu.addItem(remind)
        // Only needed when the app isn't checking on its own.
        if !model.autoRefresh { menu.addItem(action("Refresh", #selector(refresh), key: "r")) }

        menu.addItem(.separator())
        menu.addItem(action("Open PR List", #selector(openWindow)))
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit), key: "q"))

        // Classic menus: text only, no images beside titles.
        if #available(macOS 27, *) {
            for item in menu.items { item.preferredImageVisibility = .hidden }
        }
    }

    /// A disabled two-line placeholder drawn with block characters, since
    /// native menu items can't host animated views.
    private static func skeletonItem(width: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        let text = NSMutableAttributedString(string: String(repeating: "▀", count: width), attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.quaternaryLabelColor,
        ])
        text.append(NSAttributedString(string: "\n" + String(repeating: "▀", count: width / 3), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.systemFontSize - 1), .foregroundColor: NSColor.quaternaryLabelColor,
        ]))
        item.attributedTitle = text
        return item
    }

    private static let detailsFont = NSFont.menuFont(ofSize: NSFont.systemFontSize - 1)

    private static func twoLineTitle(_ title: String, details: NSAttributedString) -> NSAttributedString {
        let text = NSMutableAttributedString(string: truncate(title),
                                             attributes: [.font: NSFont.menuFont(ofSize: 0)])
        let second = NSMutableAttributedString(string: "\n")
        second.append(details)
        second.addAttributes([.font: detailsFont, .foregroundColor: NSColor.secondaryLabelColor],
                             range: NSRange(location: 0, length: second.length))
        text.append(second)
        return text
    }

    private static func truncate(_ text: String) -> String {
        text.count > maxTitleLength ? text.prefix(maxTitleLength - 1).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    @objc private func openPR(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func openUnreviewed() {
        for pr in model.pullRequests where pr.isUnreviewed(by: model.userUUID) {
            NSWorkspace.shared.open(pr.url)
        }
    }

    @objc private func openRepo() {
        if let repo = model.repo, let url = URL(string: "https://bitbucket.org/\(repo)/pull-requests/?state=OPEN&user_filter=REVIEWING") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func remindAbout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int,
              let pr = model.pullRequests.first(where: { $0.id == id }) else { return }
        WindowManager.shared.showReminder(for: pr)
    }

    @objc private func openReminder() { WindowManager.shared.showReminder(for: nil) }
    @objc private func refresh() { Task { await model.refresh(userInitiated: true) } }
    @objc private func openWindow() { WindowManager.shared.showMain() }
    @objc private func openSettings() { WindowManager.shared.showSettings() }
    @objc private func openNotificationSettings() { NSWorkspace.shared.open(Notifier.settingsURL) }
    @objc private func quit() { NSApp.terminate(nil) }
}
