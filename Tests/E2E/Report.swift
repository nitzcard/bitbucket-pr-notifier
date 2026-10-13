import Foundation

/// Writes the results three ways: JUnit XML for CI test reporters, an HTML
/// report with each test's recording, and a Markdown summary for GitHub.
enum Report {
    static func write(_ results: [TestResult], to dir: URL) throws {
        try junit(results).write(to: dir.appending(path: "junit.xml"), atomically: true, encoding: .utf8)
        try html(results).write(to: dir.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try markdown(results).write(to: dir.appending(path: "summary.md"), atomically: true, encoding: .utf8)
    }

    private static func junit(_ results: [TestResult]) -> String {
        let failures = results.filter { $0.failure != nil }.count
        let total = results.reduce(0) { $0 + $1.duration }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites tests="\(results.count)" failures="\(failures)" time="\(seconds(total))">
          <testsuite name="E2E" tests="\(results.count)" failures="\(failures)" time="\(seconds(total))">

        """
        for r in results {
            xml += "    <testcase classname=\"E2E\" name=\"\(escape(r.name))\" time=\"\(seconds(r.duration))\">\n"
            if let failure = r.failure {
                xml += "      <failure message=\"\(escape(failure))\">\(escape(failure))</failure>\n"
            }
            let log = r.steps.map { "[\(seconds($0.seconds))s] \($0.text)" }.joined(separator: "\n")
            let attachment = r.recording.map { "\nRecording: \($0)\n[[ATTACHMENT|\($0)]]" } ?? ""
            xml += "      <system-out>\(escape(log + attachment))</system-out>\n"
            xml += "    </testcase>\n"
        }
        xml += "  </testsuite>\n</testsuites>\n"
        return xml
    }

    private static func html(_ results: [TestResult]) -> String {
        let passed = results.filter { $0.failure == nil }.count
        var body = ""
        for (i, r) in results.enumerated() {
            let ok = r.failure == nil
            body += """
            <section class="\(ok ? "pass" : "fail")">
              <h2>\(ok ? "✔" : "✘") \(escape(r.name)) <small>\(seconds(r.duration))s</small></h2>

            """
            if let failure = r.failure { body += "  <pre class=\"error\">\(escape(failure))</pre>\n" }
            body += "  <div class=\"row\">\n"
            if let video = r.recording {
                body += "    <video id=\"v\(i)\" src=\"\(escape(video))\" controls muted preload=\"metadata\"></video>\n"
            } else {
                body += "    <p class=\"novideo\">No recording.</p>\n"
            }
            body += "    <ol>\n"
            for step in r.steps {
                let seek = "document.getElementById('v\(i)').currentTime=\(seconds(step.seconds));return false"
                body += "      <li><a href=\"#\" onclick=\"\(seek)\">\(seconds(step.seconds))s</a> \(escape(step.text))</li>\n"
            }
            body += "    </ol>\n  </div>\n</section>\n"
        }
        return """
        <!doctype html>
        <meta charset="utf-8">
        <title>E2E: \(passed)/\(results.count) passed</title>
        <style>
          body { font: 14px -apple-system, sans-serif; margin: 24px; color: #222 }
          section { border: 1px solid #ccc; border-left: 6px solid #2a2; border-radius: 6px; padding: 8px 16px; margin: 16px 0 }
          section.fail { border-left-color: #d22 }
          h2 { font-size: 16px } small { color: #888; font-weight: normal }
          .row { display: flex; gap: 16px; align-items: flex-start }
          video { width: 640px; max-width: 60vw; background: #000 }
          ol { margin: 0; padding-left: 20px } li { margin: 2px 0 } a { font-family: monospace }
          .error { color: #d22; white-space: pre-wrap }
        </style>
        <h1>E2E tests: \(passed) of \(results.count) passed</h1>
        <p>Click a step's time to jump to it in the recording.</p>
        \(body)
        """
    }

    private static func markdown(_ results: [TestResult]) -> String {
        let passed = results.filter { $0.failure == nil }.count
        var md = "## E2E tests: \(passed) of \(results.count) passed\n\n| | Test | Time | Recording |\n|---|---|---|---|\n"
        for r in results {
            let detail = r.failure.map { "<br>`\($0.replacingOccurrences(of: "|", with: "\\|"))`" } ?? ""
            md += "| \(r.failure == nil ? "✅" : "❌") | \(r.name)\(detail) | \(seconds(r.duration))s | \(r.recording ?? "–") |\n"
        }
        return md
    }

    private static func seconds(_ t: TimeInterval) -> String { String(format: "%.1f", t) }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
