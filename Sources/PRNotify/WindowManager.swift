import AppKit
import SwiftUI

/// Owns the main and Settings windows, so the status menu, notifications and
/// the Dock can always open them (SwiftUI scenes can only be opened from views).
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var reminderWindow: NSWindow?

    func showMain() {
        let window = mainWindow ?? makeWindow(
            title: "PR Notify",
            root: PRListView().frame(minWidth: 380, minHeight: 300),
            size: NSSize(width: 440, height: 520),
            resizable: true)
        mainWindow = window
        present(window)
    }

    func showSettings() {
        // The window follows the content's size, which changes when signing in/out.
        let window = settingsWindow ?? makeWindow(
            title: "PR Notify Settings",
            root: SettingsView(),
            size: NSSize(width: 480, height: 400),
            resizable: false)
        settingsWindow = window
        present(window)
    }

    /// A fresh "Remind Me" window each time, with `pr` preselected if given.
    func showReminder(for pr: PullRequest?) {
        reminderWindow?.close()
        let window = makeWindow(
            title: "Remind Me",
            root: ReminderView(preselected: pr?.id) { [weak self] in self?.reminderWindow?.close() },
            size: nil,
            resizable: false,
            fitsContent: false)
        reminderWindow = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// `fitsContent` makes the window track the content's size. Only for content
    /// whose size doesn't change while the window is first laid out: a resize
    /// during layout makes AppKit throw (that crashed the Remind Me window).
    /// `size: nil` sizes the window to the content's fitting size once, at creation.
    private func makeWindow(title: String, root: some View, size: NSSize?, resizable: Bool,
                            fitsContent: Bool = true) -> NSWindow {
        let controller = NSHostingController(rootView: root.environment(AppModel.shared))
        controller.sizingOptions = !resizable && fitsContent ? [.preferredContentSize] : []
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = resizable
            ? [.titled, .closable, .miniaturizable, .resizable]
            : [.titled, .closable]
        window.setContentSize(size ?? controller.view.fittingSize)
        window.isReleasedWhenClosed = false
        return window
    }
}
