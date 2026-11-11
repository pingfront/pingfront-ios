// swift-tools-version: 6.2
import PackageDescription

/// Upcoming language features enabled on every target.
let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"), // SE-0461
    .enableUpcomingFeature("InferIsolatedConformances"), // SE-0470
    .enableUpcomingFeature("ExistentialAny"), // SE-0335
    .enableUpcomingFeature("MemberImportVisibility"), // SE-0444
    .enableUpcomingFeature("InternalImportsByDefault"), // SE-0409
]

/// UI-facing targets run on the main actor unless they opt out (SE-0466).
let mainActorByDefault: [SwiftSetting] = upcoming + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "PingFront",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // The default product: Core + UI (+ the opt-in modules, inactive until `config.use(...)`).
        .library(name: "PingFront", targets: ["PingFront"]),
        // Headless: models, API client, session, outbox, live channel. Foundation only.
        .library(name: "PingFrontCore", targets: ["PingFrontCore"]),
        // The SwiftUI chat.
        .library(name: "PingFrontUI", targets: ["PingFrontUI"]),
        // UNUserNotificationCenter helpers.
        .library(name: "PingFrontPush", targets: ["PingFrontPush"]),
        // StoreKit 2 entitlement detection, offers and the native review prompt.
        .library(name: "PingFrontStoreKit", targets: ["PingFrontStoreKit"]),
        // Shake to report, screenshot with markup, log tail.
        .library(name: "PingFrontReports", targets: ["PingFrontReports"]),
    ],
    targets: [
        .target(
            name: "PingFrontCore",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],
            swiftSettings: upcoming
        ),
        .target(
            name: "PingFrontUI",
            dependencies: ["PingFrontCore"],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .process("Resources/Assets.xcassets"),
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: mainActorByDefault
        ),
        .target(name: "PingFrontPush", dependencies: ["PingFrontCore"], swiftSettings: mainActorByDefault),
        // The chat UI for its native store views (product view, subscription store); headless parts never touch it.
        .target(name: "PingFrontStoreKit", dependencies: ["PingFrontCore", "PingFrontUI"], swiftSettings: upcoming),
        .target(name: "PingFrontReports", dependencies: ["PingFrontCore", "PingFrontUI"], swiftSettings: mainActorByDefault),
        .target(
            name: "PingFront",
            dependencies: ["PingFrontCore", "PingFrontUI", "PingFrontPush", "PingFrontStoreKit", "PingFrontReports"],
            swiftSettings: upcoming
        ),
        // Test doubles (stub transport, test clock, in-memory stores). Not a product: never shipped.
        .target(name: "PingFrontTestSupport", dependencies: ["PingFrontCore"], swiftSettings: upcoming),
        .testTarget(
            name: "PingFrontCoreTests",
            dependencies: ["PingFrontCore", "PingFrontPush", "PingFrontStoreKit", "PingFrontTestSupport"],
            resources: [.copy("Fixtures")],
            swiftSettings: upcoming
        ),
        // README.md snippets, compiled (iOS); the drift check lives in PingFrontCoreTests.
        .testTarget(name: "PingFrontDocSnippetTests", dependencies: ["PingFront"], swiftSettings: upcoming),
        .testTarget(
            name: "PingFrontSnapshotTests",
            dependencies: ["PingFront"],
            swiftSettings: upcoming
        ),
    ],
    swiftLanguageModes: [.v6]
)
