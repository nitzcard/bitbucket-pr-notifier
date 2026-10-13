// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BitbucketPRNotifier",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BitbucketPRNotifier", path: "Sources/BitbucketPRNotifier"),
        // End-to-end tests: drives the built app through the Accessibility API
        // against a mock Bitbucket. Run with scripts/e2e.sh.
        .executableTarget(name: "BitbucketPRNotifierE2E", path: "Tests/E2E"),
    ]
)
