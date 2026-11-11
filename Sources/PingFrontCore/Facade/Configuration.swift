public import Foundation

/// Options for `PingFront.configure(_:_:)`.
///
/// Every field has a sensible default.
///
/// ```swift
/// PingFront.configure("pk_live_…") { config in
///     config.topics = [.billing, .bug, .idea]
///     config.appearance.accent = .indigo
///     config.use(.storeKit, .push, .reports)
///     config.logLevel = .debug
/// }
/// ```
public struct PingFrontConfiguration: Sendable {
    /// Topic chips on the welcome screen (up to six).
    ///
    /// Default: Billing, Report a bug, Ideas.
    /// A published remote look with topics replaces these.
    public var topics: [ChatTopic]?
    /// Look values set in code.
    ///
    /// The published remote look wins; unset values come from the host app, then defaults.
    public var appearance = ChatAppearance()
    /// How much the SDK logs.
    ///
    /// Default `.info`.
    public var logLevel: PingFrontLogLevel = .info
    /// The cross-platform bridge this SDK runs inside, sent as `PF-Wrapper` on every request.
    ///
    /// Set only by the React Native and Flutter bridges; a native app leaves it `nil` and sends nothing.
    public var wrapper: PingFrontWrapper?
    /// Routes SDK log lines into your own logger, in addition to unified logging.
    ///
    /// Lines are already redacted: ids, names, emails, URLs, tokens, server text and user input appear
    /// as `<private>`. Called from any thread, for lines at or above `logLevel`.
    ///
    /// ```swift
    /// config.logHandler = { entry in AppLog.info("[pingfront/\(entry.category)] \(entry.message)") }
    /// ```
    public var logHandler: PingFrontLogHandler?
    /// The chat's language, for apps with their own language picker (a BCP 47 tag such as `"de"` or `"pt-BR"`).
    ///
    /// Default `nil`: follow the app's and the system's language. Change it later with `PingFront.shared.language`.
    public var language: String?
    /// The API base URL.
    ///
    /// Leave the default, pingfront's API. Another value is only for testing against a different server.
    public var baseURL = PingFrontConfiguration.productionURL

    /// The production API.
    public static var productionURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.pingfront.sh"
        components.path = "/v1"
        // A constant URL built from valid parts; the fallback can never be reached.
        return components.url ?? URL(filePath: "/")
    }
    /// Present the chat when the server answers a moment with `open`.
    ///
    /// Default `true`.
    public var presentsChatForMoments = true
    /// The APNs environment for push tokens.
    ///
    /// Default: sandbox in debug builds, production otherwise.
    public var pushEnvironment: PushEnvironment?
    /// Optional modules, in the order they were added.
    public private(set) var modules: [PingFrontModule] = []

    package var dependencies: Dependencies?

    /// Defaults.
    public init() {}

    /// Adds optional modules, for example `config.use(.storeKit, .push, .reports)`.
    public mutating func use(_ modules: PingFrontModule...) {
        for module in modules where !self.modules.contains(where: { $0.id == module.id }) {
            self.modules.append(module)
        }
    }
}

/// The APNs environment.
public enum PushEnvironment: String, Sendable {
    /// Development builds.
    case sandbox
    /// TestFlight and App Store builds.
    case production
}

/// The injectable seams.
///
/// Tests replace the network, Keychain, files and clock.
package struct Dependencies: Sendable {
    package var transport: any Transport
    package var secure: any SecureStore
    package var persistence: any Persistence
    package var time: TimeSource
    package var device: SessionStore.DeviceProvider
    /// Reads the device context that rides on session requests and `PATCH /me` (`nil`: send none).
    package var context: ContextSource?

    package init(
        transport: any Transport, secure: any SecureStore, persistence: any Persistence, time: TimeSource,
        device: @escaping SessionStore.DeviceProvider = DeviceInfo.current(installId:), context: ContextSource? = nil
    ) {
        self.transport = transport
        self.secure = secure
        self.persistence = persistence
        self.time = time
        self.device = device
        self.context = context
    }

    /// Production seams.
    ///
    /// Keychain items and files are namespaced per app key, so data from a
    /// `pk_test` key never leaks into a `pk_live` install (or another app key) on the same device.
    package static func live(namespace: String) -> Dependencies {
        Dependencies(
            transport: URLSessionTransport(),
            secure: KeychainStore(service: "dev.pingfront.sdk.\(namespace)"),
            persistence: FilePersistence(
                directory: URL.applicationSupportDirectory.appending(path: "PingFront/\(namespace)", directoryHint: .isDirectory)),
            time: .continuous,
            context: .system()
        )
    }

    /// `test-1a2b3c4d`: the key's mode and a checksum of the full key (no secret material).
    package static func namespace(for key: AppKey) -> String {
        "\(key.mode.rawValue)-\(String(KeyCheck.crc32(key.rawValue), radix: 16))"
    }
}

/// A configuration problem found at configure time.
///
/// In debug builds the chat shows it in a red banner.
public struct ConfigurationProblem: Sendable, Equatable, CustomStringConvertible {
    /// What kind of problem.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Kind: Sendable, Equatable {
        /// The app key failed the offline check.
        case invalidKey(KeyProblem)
        /// No key was passed and `PingFrontAppKey` is not in Info.plist.
        case missingKey
        /// The server does not know the key (found later, at the first request).
        case unknownKey
        /// The app is paused in the dashboard.
        case appPaused
        /// Another option is wrong.
        case option
        /// The Keychain refused to store the install (usually an unsigned build or a missing entitlement):
        /// every launch starts a new guest and the thread looks empty.
        case keychain
        /// An offer card arrived but nothing can show offers (no `onOffer`, no store module).
        case offerHandler
    }
    /// What kind of problem.
    public let kind: Kind
    /// The exact problem and what to do, in plain words.
    public let message: String
    /// True when the SDK disabled itself because of it.
    public let disablesSDK: Bool

    /// The message.
    public var description: String { message }

    package init(kind: Kind, message: String, disablesSDK: Bool) {
        self.kind = kind
        self.message = message
        self.disablesSDK = disablesSDK
    }
}

extension PingFront {
    /// Options for `configure(_:_:)`.
    public typealias Configuration = PingFrontConfiguration
    /// Look values set in code.
    public typealias Appearance = ChatAppearance
    /// How much the SDK logs.
    public typealias LogLevel = PingFrontLogLevel
}

/// The cross-platform bridge the SDK runs inside (`PF-Wrapper: react-native/1.0.0`).
public struct PingFrontWrapper: Sendable, Equatable {
    /// The bridge, for example `react-native` or `flutter`.
    public var name: String
    /// The bridge's version, for example `1.0.0`.
    public var version: String

    /// Creates a wrapper value.
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    /// The header value, or `nil` when the name or version doesn't fit the contract's pattern
    /// (`[A-Za-z0-9._-]{1,40}/[A-Za-z0-9.+_-]{1,20}`), so a malformed value is never sent.
    package var headerValue: String? {
        let nameOK = (1...40).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        let versionOK =
            (1...20).contains(version.count) && version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".+_-".contains($0)) }
        return nameOK && versionOK ? "\(name)/\(version)" : nil
    }
}
