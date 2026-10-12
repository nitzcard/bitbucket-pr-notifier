import AppKit
import Observation
import os

private let log = Logger(subsystem: "io.github.bitbucketprnotifier", category: "updates")

/// Checks GitHub Releases for a newer version at launch and once a day.
/// Updating is manual: the app only links to the release page.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let releasesAPI = URL(string: "https://api.github.com/repos/nitzcard/bitbucket-pr-notifier/releases/latest")!

    struct Release { let version: String; let url: URL }
    /// A release newer than the running app, once a check has found one.
    private(set) var available: Release?

    private var timer: Task<Void, Never>?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// Menu command: always answers, even when there's nothing new.
    func checkFromMenu() {
        Task {
            await check()
            NSApp.activate()
            let alert = NSAlert()
            if let available {
                alert.messageText = "Version \(available.version) is available."
                alert.informativeText = "You have version \(Self.currentVersion)."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { download() }
            } else {
                alert.messageText = "Bitbucket PR Notifier is up to date."
                alert.informativeText = "Version \(Self.currentVersion) is the newest version available."
                alert.runModal()
            }
        }
    }

    func download() {
        if let available { NSWorkspace.shared.open(available.url) }
    }

    private func check() async {
        struct Latest: Decodable { let tag_name: String; let html_url: URL }
        do {
            var request = URLRequest(url: Self.releasesAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let latest = try JSONDecoder().decode(Latest.self, from: data)
            let version = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            available = Self.isNewer(version, than: Self.currentVersion) ? Release(version: version, url: latest.html_url) : nil
        } catch {
            log.error("Update check failed: \(error.localizedDescription)")
        }
    }

    /// Compares dotted versions numerically, so 1.10.0 is newer than 1.9.0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}
