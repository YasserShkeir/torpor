// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Torpor",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle ships as a binaryTarget XCFramework, so plain `swift build`
        // handles it — no Xcode project required.
        //
        // Chosen over a hand-rolled "here is a download link" updater for one
        // reason that matters more than code size: Sparkle's installer strips
        // com.apple.quarantine from the replacement bundle. Torpor is ad-hoc
        // signed, so every downloaded build is quarantined and blocked by
        // Gatekeeper — with a link-based updater the user re-pays that dance on
        // every single release; with Sparkle they pay it once, at first install.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Torpor",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Torpor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
