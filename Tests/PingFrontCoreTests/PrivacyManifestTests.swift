import Foundation
import Testing

/// The privacy manifests App Review reads: they parse, declare no tracking, list what the SDK collects
/// (https://pingfront.sh/docs/data-and-privacy), and list every required-reason API the shipped sources use.
@Suite("Privacy manifests")
struct PrivacyManifestTests {
    static let sources = TestPaths.package.appending(path: "Sources")

    /// Every shipped module that has resources carries its own manifest.
    static let manifests = ["PingFrontCore", "PingFrontUI"]

    /// Apple's required-reason API categories and the source symbols that use them.
    static let requiredReasonAPIs: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults", "@AppStorage", "NSUbiquitousKeyValueStore"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": [
            "creationDate", "modificationDate", "contentModificationDate", "fileModificationDate", "NSFileCreationDate",
            "NSFileModificationDate", "attributesOfItem", "getattrlist", "fstat(", "lstat(",
        ],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time", "kern.boottime"],
        "NSPrivacyAccessedAPICategoryDiskSpace": [
            "volumeAvailableCapacity", "volumeTotalCapacity", "NSFileSystemFreeSize", "NSFileSystemSize", "statfs(", "statvfs(",
        ],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"],
    ]

    /// What the SDK sends, as the privacy labels guide maps it to Apple's data types.
    static let collected: Set = [
        "NSPrivacyCollectedDataTypeCustomerSupport", "NSPrivacyCollectedDataTypePhotosorVideos", "NSPrivacyCollectedDataTypeName",
        "NSPrivacyCollectedDataTypeEmailAddress", "NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeDeviceID",
        "NSPrivacyCollectedDataTypeProductInteraction", "NSPrivacyCollectedDataTypePurchaseHistory",
        "NSPrivacyCollectedDataTypeOtherDiagnosticData", "NSPrivacyCollectedDataTypeOtherDataTypes",
        // The server derives country, region and city from the session request's address (person context).
        "NSPrivacyCollectedDataTypeCoarseLocation",
    ]

    static func manifest(_ module: String) throws -> [String: Any] {
        let data = try Data(contentsOf: sources.appending(path: "\(module)/Resources/PrivacyInfo.xcprivacy"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("Each manifest parses and declares no tracking", arguments: manifests)
    func noTracking(_ module: String) throws {
        let manifest = try Self.manifest(module)
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
    }

    @Test("Core declares every collected data type: linked, not tracking, for App Functionality")
    func collectedTypes() throws {
        let types = try #require(try Self.manifest("PingFrontCore")["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(Set(types.compactMap { $0["NSPrivacyCollectedDataType"] as? String }) == Self.collected)
        for type in types {
            let name = type["NSPrivacyCollectedDataType"] as? String ?? "?"
            #expect(type["NSPrivacyCollectedDataTypeLinked"] as? Bool == true, "\(name) linked")
            #expect(type["NSPrivacyCollectedDataTypeTracking"] as? Bool == false, "\(name) tracking")
            let purposes = type["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []
            #expect(purposes.contains("NSPrivacyCollectedDataTypePurposeAppFunctionality"), "\(name) purpose")
            // Analytics only where the labels doc says so: moments and purchases feed lift and revenue reports.
            let analytics = name == "NSPrivacyCollectedDataTypeProductInteraction" || name == "NSPrivacyCollectedDataTypePurchaseHistory"
            #expect(purposes.contains("NSPrivacyCollectedDataTypePurposeAnalytics") == analytics, "\(name) analytics")
            #expect(!purposes.contains("NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising"))
            #expect(!purposes.contains("NSPrivacyCollectedDataTypePurposeDeveloperAdvertising"))
        }
    }

    @Test("Every required-reason API used in a module's sources is declared in its product's manifest", arguments: manifests)
    func requiredReasonAPIs(_ module: String) throws {
        let declared = Set(
            (try Self.manifest(module)["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [])
                .compactMap { $0["NSPrivacyAccessedAPIType"] as? String })
        // Core's manifest covers the modules without resources of their own (Push, StoreKit, Reports, the umbrella).
        let modules =
            module == "PingFrontCore"
            ? ["PingFrontCore", "PingFrontPush", "PingFrontStoreKit", "PingFrontReports", "PingFront"] : [module]
        var used: Set<String> = []
        for name in modules {
            for file in try Self.swiftFiles(in: Self.sources.appending(path: name)) {
                let text = try String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                for (category, symbols) in Self.requiredReasonAPIs where symbols.contains(where: text.contains) { used.insert(category) }
            }
        }
        #expect(used.isSubset(of: declared), "Undeclared required-reason APIs in \(module): \(used.subtracting(declared).sorted())")
        // Each declared category carries at least one reason code.
        for entry in try Self.manifest(module)["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [] {
            #expect((entry["NSPrivacyAccessedAPITypeReasons"] as? [String])?.isEmpty == false)
        }
    }

    /// Free disk space never leaves the device.
    ///
    /// The session context has no `freeStorage` on iOS: Apple's
    /// disk-space reasons E174.1 and 85F4.1 forbid sending the value or anything derived from it off the device,
    /// and 7D9E.1 covers only bug reports the person chooses to send. No module reads it, and no manifest declares it.
    @Test("No shipped module reads free disk space, and no manifest declares the disk space category")
    func diskSpaceUnused() throws {
        let symbols = try #require(Self.requiredReasonAPIs["NSPrivacyAccessedAPICategoryDiskSpace"])
        let root = Self.sources
        let modules = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") && $0 != "PingFrontTestSupport" }
        for name in modules {
            for file in try Self.swiftFiles(in: root.appending(path: name)) {
                let text = try String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                for symbol in symbols { #expect(!text.contains(symbol), "\(name)/\(file.lastPathComponent) uses \(symbol)") }
            }
        }
        for module in Self.manifests {
            let declared = (try Self.manifest(module)["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [])
                .compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
            #expect(!declared.contains("NSPrivacyAccessedAPICategoryDiskSpace"), "\(module) declares disk space")
        }
    }

    static func swiftFiles(in directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }
}
