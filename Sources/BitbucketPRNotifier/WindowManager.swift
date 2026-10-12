import AppKit
import SwiftUI

/// Owns the main and Settings windows, so the status menu, notifications and
/// the Dock can always open them (SwiftUI scenes can only be opened from views).
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var reminderSheet: NSWindow?

    func showMain() {
        let window = mainWindow ?? makeWindow(
            title: "Bitbucket PR Notifier",
            root: PRListView().frame(minWidth: 380, minHeight: 300),
            size: NSSize(width: 440, height: 520),
            resizing: .both)
        mainWindow = window
        present(window)
    }

    func showSettings() {
        let window = settingsWindow ?? makeWindow(
            title: "Bitbucket PR Notifier Settings",
            root: SettingsView(),
            size: nil,
            resizing: .horizontal)
        settingsWindow = window
        present(window)
    }

    /// "Remind Me" is a sheet on the PR list window: it always stays in front
    /// of the list and must be answered before the list is used again.
    func showReminder(for pr: PullRequest?) {
        showMain()
        guard let main = mainWindow else { return }
        if let reminderSheet { main.endSheet(reminderSheet) }
        let sheet = makeWindow(
            title: "Remind Me",
            root: ReminderView(preselected: pr?.id) { [weak self] in self?.closeReminder() },
            size: nil,
            resizing: .none)
        reminderSheet = sheet
        main.beginSheet(sheet)
    }

    private func closeReminder() {
        guard let sheet = reminderSheet else { return }
        mainWindow?.endSheet(sheet)
        reminderSheet = nil
    }

    /// A window that opens cascades from the app's frontmost open window (the
    /// standard Mac placement, slightly below and right of it); with none open,
    /// it opens centered on the screen.
    private func present(_ window: NSWindow) {
        if !window.isVisible {
            let open = [mainWindow, settingsWindow].compactMap { $0 }.filter { $0 !== window && $0.isVisible }
            if let anchor = open.first(where: \.isKeyWindow) ?? open.first {
                // Passing .zero doesn't move the anchor; it returns the next cascade point.
                window.cascadeTopLeft(from: anchor.cascadeTopLeft(from: .zero))
            } else {
                window.center()
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    enum Resizing { case none, horizontal, both }

    /// `size: nil` makes the window fit its content and follow it as it changes;
    /// with `.horizontal` the user sets the width and the height follows the content.
    /// The window is resized after layout finishes, never during it: AppKit throws
    /// when a hosting view resizes its window mid-layout (that crashed the app).
    private func makeWindow(title: String, root: some View, size: NSSize?, resizing: Resizing) -> NSWindow {
        let box = WeakWindow()
        let content = root
            .environment(AppModel.shared)
            .fixedSize(horizontal: size == nil && resizing != .horizontal, vertical: size == nil)
            .background(GeometryReader { geo in
                Color.clear.onChange(of: geo.size, initial: true) { _, newSize in
                    guard size == nil else { return }
                    DispatchQueue.main.async { box.window?.fit(contentSize: newSize, lockHeight: resizing == .horizontal) }
                }
            })
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        box.window = window
        window.title = title
        window.styleMask = switch resizing {
        case .none: [.titled, .closable]
        case .horizontal: [.titled, .closable, .resizable]
        case .both: [.titled, .closable, .miniaturizable, .resizable]
        }
        window.setContentSize(size ?? controller.view.fittingSize)
        // Never narrower than the content's natural width.
        if resizing == .horizontal { window.contentMinSize = controller.view.fittingSize }
        window.isReleasedWhenClosed = false
        return window
    }
}

private final class WeakWindow {
    weak var window: NSWindow?
}

private extension NSWindow {
    /// Resizes to `contentSize` keeping the top edge in place. A sheet only
    /// changes size: AppKit positions it, and moving it detaches it from its
    /// window (it went invisible and blocked the window). `lockHeight` stops the
    /// user dragging the height away from the content's.
    func fit(contentSize: NSSize, lockHeight: Bool) {
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        var contentSize = contentSize
        if lockHeight {
            contentSize.width = contentRect(forFrameRect: frame).width
            contentMinSize.height = contentSize.height
            contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: contentSize.height)
        }
        guard contentRect(forFrameRect: frame).size != contentSize else { return }
        if sheetParent != nil {
            setContentSize(contentSize)
            return
        }
        var newFrame = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        newFrame.origin = NSPoint(x: frame.minX, y: frame.maxY - newFrame.height)
        setFrame(newFrame, display: true)
    }
}
