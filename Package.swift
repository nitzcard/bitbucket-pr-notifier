// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PRNotify",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PRNotify", path: "Sources/PRNotify")
    ]
)
