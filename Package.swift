// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BitbucketPRNotifier",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BitbucketPRNotifier", path: "Sources/BitbucketPRNotifier")
    ]
)
