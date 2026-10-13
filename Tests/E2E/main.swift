import ApplicationServices
import Foundation

// BitbucketPRNotifierE2E --app <path to .app> --out <report folder> [test name…]
// Usually run through scripts/e2e.sh.
setvbuf(stdout, nil, _IOLBF, 0)

var options: [String: String] = [:]
var only: [String] = []
var argv = CommandLine.arguments.dropFirst()
while let arg = argv.popFirst() {
    if arg.hasPrefix("--"), let value = argv.popFirst() { options[String(arg.dropFirst(2))] = value } else { only.append(arg) }
}
guard let app = options["app"], let out = options["out"] else {
    print("Usage: BitbucketPRNotifierE2E --app <path to .app> --out <report folder> [test name…]")
    exit(2)
}
guard AXIsProcessTrusted() else {
    print("This process needs Accessibility access: System Settings → Privacy & Security → Accessibility.")
    exit(2)
}

let tests = only.isEmpty ? allTests : allTests.filter { only.contains($0.name) }
let outDir = URL(fileURLWithPath: out)
let results = try Runner(appURL: URL(fileURLWithPath: app), outDir: outDir).run(tests)
try Report.write(results, to: outDir)

let failed = results.filter { $0.failure != nil }
print("\n\(results.count - failed.count) of \(results.count) passed. Report: \(outDir.appending(path: "index.html").path)")
exit(failed.isEmpty ? 0 : 1)
