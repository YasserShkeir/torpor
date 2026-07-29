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
        ),
        // Tests depend on the executable target directly. SwiftPM links its
        // objects into the test bundle, so no TorporCore library split is
        // needed — and no `public` on the several hundred symbols the UI reads,
        // which is what that split would actually have cost.
        //
        // `.swiftLanguageMode(.v5)` matches the target under test: v6 mode
        // rejects `@testable` use of the non-Sendable values these tests pass
        // across isolation boundaries.
        .testTarget(
            name: "TorporCoreTests",
            dependencies: ["Torpor"],
            path: "Tests/TorporCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
