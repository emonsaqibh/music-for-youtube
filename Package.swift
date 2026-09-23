// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YouTubeMusic",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "YouTubeMusic",
            path: "Sources/YouTubeMusic",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
