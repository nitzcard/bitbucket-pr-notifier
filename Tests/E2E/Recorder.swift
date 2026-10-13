import Foundation

/// Records the screen while a test runs, with `screencapture -v`, then shrinks
/// it to a 720p MP4 that browsers play in the report.
final class Recorder {
    private var process: Process?
    private var raw: URL?
    private(set) var startedAt = Date()

    func start(to url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -v video, -C show the cursor, -k show clicks, -x no sounds.
        process.arguments = ["-v", "-C", "-k", "-x", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
            raw = url
            Thread.sleep(forTimeInterval: 1) // recording starts a moment after launch
        } catch {
            print("  (no recording: \(error))")
        }
        startedAt = Date()
    }

    /// Stops recording and returns the file to attach, if any.
    func stop() -> URL? {
        guard let process, let raw else { return nil }
        self.process = nil
        Thread.sleep(forTimeInterval: 0.5) // keep the last frame visible
        process.interrupt()
        process.waitUntilExit()
        guard FileManager.default.fileExists(atPath: raw.path) else { return nil }
        return compress(raw) ?? raw
    }

    /// macOS's own avconvert, so CI needs nothing installed.
    private func compress(_ mov: URL) -> URL? {
        let mp4 = mov.deletingPathExtension().appendingPathExtension("mp4")
        let status = shell("/usr/bin/avconvert", "--source", mov.path, "--preset", "Preset1280x720",
                           "--output", mp4.path, "--replace")
        guard status == 0, FileManager.default.fileExists(atPath: mp4.path) else { return nil }
        try? FileManager.default.removeItem(at: mov)
        return mp4
    }
}
