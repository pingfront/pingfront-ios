import Foundation

// The protocol's `DeviceContext` and `ContextCollection` (https://pingfront.sh/docs/person-context).
// Coarse buckets only. The SDK sends them with requests it makes anyway and never logs them.

/// What the SDK knows about the device right now, in coarse buckets (`Device.context`, `DevicePatch.context`).
///
/// Every group is optional: a group that is present replaces the stored one on the server.
package struct DeviceContext: Codable, Sendable, Equatable {
    package var build: BuildContext?
    package var display: DisplayContext?
    package var connection: ConnectionContext?
    package var health: HealthContext?
    package var notifications: NotificationContext?

    package init(
        build: BuildContext? = nil, display: DisplayContext? = nil, connection: ConnectionContext? = nil, health: HealthContext? = nil,
        notifications: NotificationContext? = nil
    ) {
        self.build = build
        self.display = display
        self.connection = connection
        self.health = health
        self.notifications = notifications
    }

    package var isEmpty: Bool { build == nil && display == nil && connection == nil && health == nil && notifications == nil }
}

/// Where this build came from.
package struct BuildContext: Codable, Sendable, Equatable {
    package enum InstallSource: String, Sendable, TolerantStringEnum {
        case appStore = "app_store"
        case testflight
        case development
        case playStore = "play_store"
        case otherStore = "other_store"
        case sideloaded
        case other
        /// A source this SDK version does not know. Never sent.
        case unknown
        package static var fallback: InstallSource { .unknown }
    }
    package var installSource: InstallSource?
    /// Android only.
    package var installer: String?
    package var debuggable: Bool?

    package init(installSource: InstallSource? = nil, installer: String? = nil, debuggable: Bool? = nil) {
        self.installSource = installSource
        self.installer = installer
        self.debuggable = debuggable
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeKnown(installSource, forKey: .installSource)
        try c.encodeIfPresent(installer, forKey: .installer)
        try c.encodeIfPresent(debuggable, forKey: .debuggable)
    }

    private enum CodingKeys: String, CodingKey { case installSource, installer, debuggable }
}

/// Display and accessibility settings, in buckets.
package struct DisplayContext: Codable, Sendable, Equatable {
    package enum ScreenClass: String, Sendable, TolerantStringEnum {
        case compact, regular
        /// A class this SDK version does not know. Never sent.
        case unknown
        package static var fallback: ScreenClass { .unknown }
    }
    package enum TextSize: String, Sendable, TolerantStringEnum {
        case `default`, large, accessibility
        /// A size this SDK version does not know. Never sent.
        case unknown
        package static var fallback: TextSize { .unknown }
    }
    package var screenClass: ScreenClass?
    /// Points to pixels, 1 to 4.
    package var scale: Double?
    package var darkMode: Bool?
    package var textSize: TextSize?
    package var screenReader: Bool?
    package var reduceMotion: Bool?
    package var boldText: Bool?
    /// At most three BCP 47 tags, most preferred first.
    package var languages: [String]?

    package init(
        screenClass: ScreenClass? = nil, scale: Double? = nil, darkMode: Bool? = nil, textSize: TextSize? = nil, screenReader: Bool? = nil,
        reduceMotion: Bool? = nil, boldText: Bool? = nil, languages: [String]? = nil
    ) {
        self.screenClass = screenClass
        self.scale = scale
        self.darkMode = darkMode
        self.textSize = textSize
        self.screenReader = screenReader
        self.reduceMotion = reduceMotion
        self.boldText = boldText
        self.languages = languages
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeKnown(screenClass, forKey: .screenClass)
        try c.encodeIfPresent(scale, forKey: .scale)
        try c.encodeIfPresent(darkMode, forKey: .darkMode)
        try c.encodeKnown(textSize, forKey: .textSize)
        try c.encodeIfPresent(screenReader, forKey: .screenReader)
        try c.encodeIfPresent(reduceMotion, forKey: .reduceMotion)
        try c.encodeIfPresent(boldText, forKey: .boldText)
        try c.encodeIfPresent(languages, forKey: .languages)
    }

    private enum CodingKeys: String, CodingKey {
        case screenClass, scale, darkMode, textSize, screenReader, reduceMotion, boldText, languages
    }

    /// The first three of `tags` that are valid wire language tags (`^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$`, at
    /// most 20 characters).
    package static func languages(from tags: [String]) -> [String] {
        Array(tags.filter(isLanguageTag).prefix(3))
    }

    private static func isLanguageTag(_ tag: String) -> Bool {
        guard tag.count <= 20 else { return false }
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (1...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }
}

/// The connection when the SDK last sent it.
package struct ConnectionContext: Codable, Sendable, Equatable {
    package enum Network: String, Sendable, TolerantStringEnum {
        case wifi, cellular, wired, none, other
        /// A network this SDK version does not know. Never sent.
        case unknown
        package static var fallback: Network { .unknown }
    }
    package var network: Network?
    /// Low Data Mode.
    package var constrained: Bool?
    /// A metered connection (cellular or a hotspot).
    package var expensive: Bool?
    /// Low Power Mode.
    package var lowPower: Bool?

    package init(network: Network? = nil, constrained: Bool? = nil, expensive: Bool? = nil, lowPower: Bool? = nil) {
        self.network = network
        self.constrained = constrained
        self.expensive = expensive
        self.lowPower = lowPower
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeKnown(network, forKey: .network)
        try c.encodeIfPresent(constrained, forKey: .constrained)
        try c.encodeIfPresent(expensive, forKey: .expensive)
        try c.encodeIfPresent(lowPower, forKey: .lowPower)
    }

    private enum CodingKeys: String, CodingKey { case network, constrained, expensive, lowPower }
}

/// Device health at session start, in buckets.
///
/// The iOS SDK never sends `freeStorage`: Apple's required reasons for disk space forbid sending it off the device.
package struct HealthContext: Codable, Sendable, Equatable {
    package enum FreeStorage: String, Sendable, TolerantStringEnum {
        case under1GB = "under_1gb"
        case from1To5GB = "from_1_to_5gb"
        case from5To20GB = "from_5_to_20gb"
        case over20GB = "over_20gb"
        /// A bucket this SDK version does not know. Never sent.
        case unknown
        package static var fallback: FreeStorage { .unknown }
    }
    package enum Thermal: String, Sendable, TolerantStringEnum {
        case nominal, fair, serious, critical
        /// A state this SDK version does not know. Never sent.
        case unknown
        package static var fallback: Thermal { .unknown }
    }
    package enum MemoryPressure: String, Sendable, TolerantStringEnum {
        case normal, warning, critical
        /// A level this SDK version does not know. Never sent.
        case unknown
        package static var fallback: MemoryPressure { .unknown }
    }
    /// Decoded for conformance only; the iOS SDK never sets it.
    package var freeStorage: FreeStorage?
    /// Rounded down to a multiple of 10.
    package var battery: Int?
    package var charging: Bool?
    package var thermal: Thermal?
    package var memoryPressure: MemoryPressure?

    package init(
        freeStorage: FreeStorage? = nil,
        battery: Int? = nil,
        charging: Bool? = nil,
        thermal: Thermal? = nil,
        memoryPressure: MemoryPressure? = nil
    ) {
        self.freeStorage = freeStorage
        self.battery = battery
        self.charging = charging
        self.thermal = thermal
        self.memoryPressure = memoryPressure
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeKnown(freeStorage, forKey: .freeStorage)
        try c.encodeIfPresent(battery, forKey: .battery)
        try c.encodeIfPresent(charging, forKey: .charging)
        try c.encodeKnown(thermal, forKey: .thermal)
        try c.encodeKnown(memoryPressure, forKey: .memoryPressure)
    }

    private enum CodingKeys: String, CodingKey { case freeStorage, battery, charging, thermal, memoryPressure }

    /// A battery level from 0...1 as a multiple of 10 (rounded down); `nil` when unknown (negative).
    package static func batteryBucket(_ level: Float) -> Int? {
        guard level >= 0 else { return nil }
        return min(100, Int((Double(level) * 100).rounded(.down)) / 10 * 10)
    }
}

/// Notification permission.
package struct NotificationContext: Codable, Sendable, Equatable {
    package enum Authorization: String, Sendable, TolerantStringEnum {
        case authorized, provisional, ephemeral, denied
        case notDetermined = "not_determined"
        /// A status this SDK version does not know. Never sent.
        case unknown
        package static var fallback: Authorization { .unknown }
    }
    package var authorization: Authorization?
    /// Android only.
    package var channelEnabled: Bool?

    package init(authorization: Authorization? = nil, channelEnabled: Bool? = nil) {
        self.authorization = authorization
        self.channelEnabled = channelEnabled
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeKnown(authorization, forKey: .authorization)
        try c.encodeIfPresent(channelEnabled, forKey: .channelEnabled)
    }

    private enum CodingKeys: String, CodingKey { case authorization, channelEnabled }
}

/// Which `DeviceContext` groups the app collects (`CreateSessionResponse.collect`, `RefreshSessionResponse.collect`).
///
/// Absent (older servers) means every group.
package struct ContextCollection: Codable, Sendable, Equatable {
    package var build: Bool
    package var display: Bool
    package var connection: Bool
    package var health: Bool
    package var notifications: Bool

    package init(build: Bool = true, display: Bool = true, connection: Bool = true, health: Bool = true, notifications: Bool = true) {
        self.build = build
        self.display = display
        self.connection = connection
        self.health = health
        self.notifications = notifications
    }

    /// Every group: before the first answer, and for servers that do not send `collect`.
    package static let all = ContextCollection()

    package init(from decoder: any Decoder) throws {
        // Every field is required on the wire; a missing one (a newer server that split a group) collects.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        build = try c.decodeIfPresent(Bool.self, forKey: .build) ?? true
        display = try c.decodeIfPresent(Bool.self, forKey: .display) ?? true
        connection = try c.decodeIfPresent(Bool.self, forKey: .connection) ?? true
        health = try c.decodeIfPresent(Bool.self, forKey: .health) ?? true
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
    }

    private enum CodingKeys: String, CodingKey { case build, display, connection, health, notifications }
}

extension KeyedEncodingContainer {
    /// Encodes a wire enum unless it is absent or the `unknown` fallback (never sent).
    fileprivate mutating func encodeKnown<T: TolerantStringEnum & Equatable>(_ value: T?, forKey key: Key) throws {
        guard let value, value != T.fallback else { return }
        try encode(value.rawValue, forKey: key)
    }
}
