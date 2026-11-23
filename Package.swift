// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickMark",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "QuickMark",
            path: "Sources/QuickMark"
        )
    ]
)
