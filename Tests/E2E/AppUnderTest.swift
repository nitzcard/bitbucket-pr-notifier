import AppKit

/// The built app, launched fresh for each test with its own defaults domain
/// and support folder, so tests never touch a real install's data.
final class AppUnderTest {
    static let bundleID = "io.github.bitbucketprnotifier.e2e"
    static let mainTitle = "Bitbucket PR Notifier"
    static let settingsTitle = "Bitbucket PR Notifier Settings"

    let appURL: URL
    let supportDir: URL
    let mock: MockBitbucket
    private var process: Process?

    var pid: pid_t { process?.processIdentifier ?? 0 }
    var ax: Element { Element.application(pid: pid) }

    init(appURL: URL, supportDir: URL, mock: MockBitbucket) {
        self.appURL = appURL
        self.supportDir = supportDir
        self.mock = mock
    }

    /// Clears everything the app saved, like a first launch.
    func resetState() {
        shell("/usr/bin/defaults", "delete", Self.bundleID)
        try? FileManager.default.removeItem(at: supportDir)
    }

    /// Saves a signed-in account watching acme/web, as if the user had set it up earlier.
    func seedSignedIn() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let credentials = ["apiToken": ["email": MockBitbucket.email, "token": MockBitbucket.token]]
        try JSONSerialization.data(withJSONObject: credentials).write(to: supportDir.appending(path: "credentials.json"))
        shell("/usr/bin/defaults", "write", Self.bundleID, "repo", "-string", "acme/web")
        shell("/usr/bin/defaults", "write", Self.bundleID, "accountName", "-string", MockBitbucket.displayName)
        shell("/usr/bin/defaults", "write", Self.bundleID, "email", "-string", MockBitbucket.email)
    }

    func launch() throws {
        let process = Process()
        process.executableURL = appURL.appending(path: "Contents/MacOS/BitbucketPRNotifier")
        var env = ProcessInfo.processInfo.environment
        env["BPRN_API_URL"] = mock.apiURL
        env["BPRN_RELEASES_URL"] = mock.releasesURL
        env["BPRN_SUPPORT_DIR"] = supportDir.path
        process.environment = env
        try process.run()
        self.process = process
        try waitFor("the main window to open", timeout: 20) { window(Self.mainTitle) }
    }

    func quit() {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        self.process = nil
    }

    func window(_ title: String) -> Element? {
        ax.windows.first { $0.title == title }
    }

    func waitForWindow(_ title: String) throws -> Element {
        try waitFor("the \"\(title)\" window") { window(title) }
    }

    var mainWindow: Element { get throws { try waitForWindow(Self.mainTitle) } }
    var settingsWindow: Element { get throws { try waitForWindow(Self.settingsTitle) } }

    /// The app's windows and everything in them, one element per line.
    func dump() -> String {
        ax.windows.map { window in
            "WINDOW \(window)\n" + window.descendants().map { "  \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: Status menu

    /// The menu bar item: the icon and the PR count beside it.
    var statusItem: Element {
        get throws {
            try waitFor("the menu bar item") {
                (ax.attribute("AXExtrasMenuBar") as! AXUIElement?).map(Element.init)?.children.first
            }
        }
    }

    /// Opens the menu bar menu and returns its items.
    func openStatusMenu() throws -> [Element] {
        let item = try statusItem
        try item.press()
        return try waitFor("the menu bar menu to open") {
            let items = item.children.first { $0.role == kAXMenuRole }?.children ?? []
            return items.isEmpty ? nil : items
        }
    }

    func closeStatusMenu() throws {
        let item = try statusItem
        // The closed menu stays in the tree, so there's nothing to wait for but the animation.
        if let menu = item.children.first(where: { $0.role == kAXMenuRole }) { try menu.perform(kAXCancelAction) }
        Thread.sleep(forTimeInterval: 0.7)
    }

    /// Opens the menu bar menu and chooses the item titled `title`.
    func chooseFromStatusMenu(_ title: String) throws {
        let items = try openStatusMenu()
        guard let item = items.first(where: { $0.title == title }) else {
            throw TestFailure("No menu item \"\(title)\" in \(items.map(\.title))")
        }
        try expect(item.isEnabled, "\"\(title)\" is dimmed")
        try item.press()
    }

    // MARK: Main window

    func button(_ label: String, in root: Element) throws -> Element {
        try waitFor("a \"\(label)\" button") {
            root.all(kAXButtonRole).first { $0.label.contains(label) }
        }
    }

    func waitForText(_ text: String, in root: Element, timeout: TimeInterval = 10) throws {
        try waitUntil("\"\(text)\" to show", timeout: timeout) { root.shows(text) }
    }
}

@discardableResult
func shell(_ path: String, _ args: String...) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
