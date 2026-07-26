// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Torpor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Torpor",
            path: "Sources/Torpor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
