import AppKit
import SwiftUI

// `BitbucketPRNotifier --export-iconset <dir>` renders the app icon for the build script.
let args = CommandLine.arguments
if args.count == 3, args[1] == "--export-iconset" {
    try IconArt.exportIconset(to: URL(fileURLWithPath: args[2]))
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.setUp()
        Notifier.shared.onOpenWindow = { WindowManager.shared.showMain() }
        statusMenu = StatusMenu()
        AppModel.shared.start()
        Updater.shared.start()

        WindowManager.shared.showMain()
        if AppModel.shared.status == .signedOut { WindowManager.shared.showSettings() }
    }

    // Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showMain() }
        return true
    }

    // Closing the window keeps the app alive in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Windows and the status menu are AppKit-managed (see WindowManager); the
/// SwiftUI app only supplies the standard main menu (Edit menu for paste, etc.).
struct BitbucketPRNotifierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { WindowManager.shared.showSettings() }
                        .keyboardShortcut(",")
                    Button("Check for Updates…") { Updater.shared.checkFromMenu() }
                }
            }
    }
}

BitbucketPRNotifierApp.main()
