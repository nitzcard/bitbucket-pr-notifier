import Foundation

/// Environment variables the end-to-end tests (Tests/E2E) launch the app with,
/// so it talks to a local mock server and keeps its files out of the real ones.
/// Unset in normal use.
enum TestOverrides {
    static func url(_ name: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value)
    }
}
