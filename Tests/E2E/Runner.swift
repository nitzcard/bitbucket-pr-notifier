import Foundation

struct TestCase {
    let name: String
    /// Starts signed in and watching acme/web, instead of from a first launch.
    var signedIn = true
    let body: (TestContext) throws -> Void
}

/// What a test gets: the running app, the mock server, and `step` to log
/// progress (each step links to its moment in the recording).
final class TestContext {
    let app: AppUnderTest
    var mock: MockBitbucket { app.mock }
    fileprivate var steps: [Step] = []
    fileprivate let recordingStart: Date

    init(app: AppUnderTest, recordingStart: Date) {
        self.app = app
        self.recordingStart = recordingStart
    }

    func step(_ text: String) {
        let seconds = Date().timeIntervalSince(recordingStart)
        steps.append(Step(text: text, seconds: seconds))
        print("  · \(text)")
    }
}

struct Step {
    let text: String
    let seconds: TimeInterval
}

struct TestResult {
    let name: String
    let duration: TimeInterval
    let failure: String?
    let steps: [Step]
    /// Relative to the report folder.
    let recording: String?
}

struct Runner {
    let appURL: URL
    let outDir: URL

    func run(_ tests: [TestCase]) throws -> [TestResult] {
        let recordings = outDir.appending(path: "recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let mock = try MockBitbucket()
        try mock.start()
        let app = AppUnderTest(appURL: appURL,
                               supportDir: outDir.appending(path: "app-support"),
                               mock: mock)

        return tests.map { test in
            print("▶ \(test.name)")
            mock.reset()
            app.resetState()
            let recorder = Recorder()
            recorder.start(to: recordings.appending(path: "\(test.name).mov"))
            let context = TestContext(app: app, recordingStart: recorder.startedAt)
            let started = Date()
            var failure: String?
            do {
                if test.signedIn { try app.seedSignedIn() }
                context.step("Launch the app")
                try app.launch()
                try test.body(context)
            } catch {
                failure = "\(error)"
                context.step("FAILED: \(error)")
                // What the app showed at the time, to debug from CI's artifacts.
                try? app.dump().write(to: outDir.appending(path: "\(test.name).ax.txt"), atomically: true, encoding: .utf8)
            }
            let duration = Date().timeIntervalSince(started)
            let video = recorder.stop()
            app.quit()
            print(failure.map { "✘ \(test.name): \($0)" } ?? "✔ \(test.name)")
            return TestResult(name: test.name, duration: duration, failure: failure, steps: context.steps,
                              recording: video.map { "recordings/\($0.lastPathComponent)" })
        }
    }
}
