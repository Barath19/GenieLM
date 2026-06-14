// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GenieLM",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GenieLM",
            path: "Sources/GenieLM"
        )
    ]
)
