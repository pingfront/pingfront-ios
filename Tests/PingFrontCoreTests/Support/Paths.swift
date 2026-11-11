import Foundation

/// Where the tests find files that are not in their own bundle.
///
/// The protocol fixtures are the language-neutral cases the server and every SDK run. The cross-checks against the
/// protocol's endpoint table, the table of shipped locales and the Android SDK's strings need files that sit beside
/// this package only where the SDKs are developed together; elsewhere they are `nil` and those tests are skipped.
enum TestPaths {
    /// The folder with Package.swift.
    static let package = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The protocol fixtures these tests read (`Tests/ProtocolFixtures`).
    static let protocolFixtures = package.appending(path: "Tests/ProtocolFixtures")
    /// The protocol's endpoint table: not part of this package.
    static let protocolDoc: URL? = nil
    /// The table of locales every SDK ships: not part of this package.
    static let localesDoc: URL? = nil
    /// The Android SDK's string resources: not part of this package.
    static let androidStrings: URL? = nil
}
