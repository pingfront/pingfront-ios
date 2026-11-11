import Foundation

package enum DeviceInfo {
    package static func current(installId: String) -> Device {
        let bundle = Bundle.main
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
            let platform = Platform.macos
            let osName = "macOS"
        #else
            let platform = Platform.ios
            let osName = "iOS"
        #endif
        return Device(
            installId: installId,
            platform: platform,
            sdk: .init(name: PingFrontVersion.name, version: PingFrontVersion.current),
            app: .init(
                version: String((bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0").prefix(40)),
                build: String((bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0").prefix(40)),
                bundleId: String((bundle.bundleIdentifier ?? "unknown").prefix(200))
            ),
            os: "\(osName) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            model: String(modelIdentifier().prefix(60)),
            locale: String(LanguageOverride.effectiveLocale.identifier(.bcp47).prefix(40)),
            language: String(LanguageOverride.effectiveTag.prefix(20)),
            timeZone: String(TimeZone.current.identifier.prefix(60))
        )
    }

    package static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "0") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    package static var appDisplayName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName
    }

    /// The person's preferred language tag, for `LocalizedText` lookup.
    package static var languageTag: String { LanguageOverride.effectiveTag }

    private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
