public import Foundation

/// An sRGB color with components from 0 to 1.
///
/// Platform-independent, so Core can merge looks and check contrast.
public struct RGBColor: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    /// Red, 0...1.
    public var red: Double
    /// Green, 0...1.
    public var green: Double
    /// Blue, 0...1.
    public var blue: Double

    /// Creates a color from sRGB components in 0...1.
    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// A color from a `0xRRGGBB` literal, for constants.
    public init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    /// Parses `#RRGGBB`.
    public init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// `#RRGGBB`, uppercase.
    public var hex: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return "#" + [r, g, b].map { String(format: "%02X", $0) }.joined()
    }

    /// The hex string.
    public var description: String { hex }

    /// WCAG 2.x relative luminance.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio between two colors (1...21).
    public static func contrast(_ a: RGBColor, _ b: RGBColor) -> Double {
        let (l1, l2) = (a.luminance, b.luminance)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// Mixes toward `other` by `amount` (0 = self, 1 = other).
    public func mixed(with other: RGBColor, amount: Double) -> RGBColor {
        RGBColor(
            red: red + (other.red - red) * amount, green: green + (other.green - green) * amount, blue: blue + (other.blue - blue) * amount)
    }

    /// Decodes the wire format; values this SDK version does not know are kept as unknown.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let color = RGBColor(hex: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected #RRGGBB, got \(string)")
        }
        self = color
    }

    /// Encodes the wire format.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    /// White.
    public static let white = RGBColor(red: 1, green: 1, blue: 1)
    /// Black.
    public static let black = RGBColor(red: 0, green: 0, blue: 0)
}

/// Light or dark appearance.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum ColorMode: Sendable, Equatable {
    /// Light appearance.
    case light
    /// Dark appearance.
    case dark
}

/// A color with a light and a dark variant (`PerMode` on the wire).
public struct PingFrontColor: Sendable, Equatable, Hashable, Codable {
    /// Light mode value.
    public var light: RGBColor
    /// Dark mode value.
    public var dark: RGBColor

    /// A color with explicit light and dark values.
    public init(light: RGBColor, dark: RGBColor) {
        self.light = light
        self.dark = dark
    }

    /// A color from two `#RRGGBB` literals.
    ///
    /// For colors written in code. Invalid hex is a programming error: debug builds stop with an
    /// assertion; release builds use the brand reply blue. For values from elsewhere use `init?(hex:)`.
    public init(light: String, dark: String) {
        let parsedLight = RGBColor(hex: light)
        let parsedDark = RGBColor(hex: dark)
        if parsedLight == nil || parsedDark == nil {
            assertionFailure("PingFrontColor: \"\(light)\" / \"\(dark)\" is not #RRGGBB")
        }
        self.light = parsedLight ?? PingFrontColor.reply.light
        self.dark = parsedDark ?? PingFrontColor.reply.dark
    }

    /// The same `#RRGGBB` in both modes, or `nil` when the text is not a valid hex color.
    public init?(hex: String) {
        guard let rgb = RGBColor(hex: hex) else { return nil }
        self.init(light: rgb, dark: rgb)
    }

    /// The value in light or dark mode.
    public func value(in mode: ColorMode) -> RGBColor { mode == .dark ? dark : light }

    /// pingfront reply blue (#3550E6 / #7D91FF).
    public static let reply = PingFrontColor(
        light: RGBColor(red: 0x35 / 255, green: 0x50 / 255, blue: 0xE6 / 255), dark: RGBColor(red: 0x7D / 255, green: 0x91 / 255, blue: 1))
    /// System blue.
    public static let blue = PingFrontColor(light: "#007AFF", dark: "#0A84FF")
    /// System indigo.
    public static let indigo = PingFrontColor(light: "#5856D6", dark: "#5E5CE6")
    /// System purple.
    public static let purple = PingFrontColor(light: "#AF52DE", dark: "#BF5AF2")
    /// System pink.
    public static let pink = PingFrontColor(light: "#FF2D55", dark: "#FF375F")
    /// System red.
    public static let red = PingFrontColor(light: "#FF3B30", dark: "#FF453A")
    /// System orange.
    public static let orange = PingFrontColor(light: "#FF9500", dark: "#FF9F0A")
    /// System green.
    public static let green = PingFrontColor(light: "#34C759", dark: "#30D158")
    /// System teal.
    public static let teal = PingFrontColor(light: "#30B0C7", dark: "#40C8E0")
    /// System mint.
    public static let mint = PingFrontColor(light: "#00C7BE", dark: "#63E6E2")
    /// System brown.
    public static let brown = PingFrontColor(light: "#A2845E", dark: "#AC8E68")
}

/// Text the customer wrote, keyed by BCP-47 tag plus a required `"default"`.
///
/// Lookup: exact tag, then base language, then `"default"`.
public struct LocalizedText: Sendable, Equatable, Hashable, Codable {
    /// Values by language tag.
    public var values: [String: String]

    /// Creates localized text from a dictionary.
    ///
    /// Include a `"default"` entry.
    public init(_ values: [String: String]) { self.values = values }

    /// The same text for every language.
    public init(default text: String) { self.values = ["default": text] }

    /// Resolves for a language tag such as `pt-BR`: exact tag, then base language, then `"default"`.
    public func resolve(for languageTag: String) -> String? {
        let tag = languageTag.replacingOccurrences(of: "_", with: "-")
        if let exact = values[tag] ?? values.first(where: { $0.key.caseInsensitiveCompare(tag) == .orderedSame })?.value { return exact }
        let base = String(tag.split(separator: "-").first ?? Substring(tag)).lowercased()
        if let baseValue = values[base] { return baseValue }
        return values["default"]
    }

    /// Decodes the wire format; values this SDK version does not know are kept as unknown.
    public init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: String].self)
    }

    /// Encodes the wire format.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// The symbol shown on a topic chip.
///
/// Mapped to SF Symbols by the UI.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum TopicSymbol: String, Sendable, Codable, CaseIterable, TolerantStringEnum {
    case billing, bug, idea, question, account, feedback, gift, restore, privacy, other
    /// The case used for values this SDK version does not know.
    package static var fallback: TopicSymbol { .other }

    /// Decodes the raw value; values this SDK version does not know become `.other`.
    public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
}

/// A member of the app's team, shown in the header and welcome.
public struct TeamMember: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Member id.
    public var id: String
    /// Display name.
    public var name: String
    /// For example "Maker of Clockwise".
    public var role: String?
    /// Avatar URL.
    public var avatarURL: URL?
    /// IANA time zone, used for "It's 21:40 for Deniz".
    public var timeZone: String?

    /// Creates a team member.
    @_spi(Fixtures) public init(id: String, name: String, role: String? = nil, avatarURL: URL? = nil, timeZone: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.avatarURL = avatarURL
        self.timeZone = timeZone
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, role, timeZone
        case avatarURL = "avatarUrl"
    }
}

/// The chat look as configured in the dashboard (the protocol's `ChatLook`).
///
/// Fields keep "unset" as `nil` so code configuration can fill them; `ResolvedLook` applies defaults.
public struct ChatLook: Sendable, Equatable, Codable {
    /// Color scheme preference.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Scheme: String, Sendable, Codable, TolerantStringEnum {
        case auto, light, dark
        /// The case used for values this SDK version does not know.
        package static var fallback: Scheme { .auto }

        /// Decodes the raw value; values this SDK version does not know become `.auto`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Font design.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum FontStyle: String, Sendable, Codable, TolerantStringEnum {
        case system, rounded, serif
        /// The case used for values this SDK version does not know.
        package static var fallback: FontStyle { .system }

        /// Decodes the raw value; values this SDK version does not know become `.system`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Bubble corners: round 18, soft 12, square 6 pt.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Corners: String, Sendable, Codable, TolerantStringEnum {
        case round, soft, square
        /// The case used for values this SDK version does not know.
        package static var fallback: Corners { .round }

        /// Decodes the raw value; values this SDK version does not know become `.round`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Spacing density.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Density: String, Sendable, Codable, TolerantStringEnum {
        case comfortable, compact
        /// The case used for values this SDK version does not know.
        package static var fallback: Density { .comfortable }

        /// Decodes the raw value; values this SDK version does not know become `.comfortable`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Header style: one face, stacked team faces, or the app icon.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum HeaderStyle: String, Sendable, Codable, TolerantStringEnum {
        case person, team, app
        /// The case used for values this SDK version does not know.
        package static var fallback: HeaderStyle { .person }

        /// Decodes the raw value; values this SDK version does not know become `.person`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Timestamps under each group or under every message.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Timestamps: String, Sendable, Codable, TolerantStringEnum {
        case grouped, always
        /// The case used for values this SDK version does not know.
        package static var fallback: Timestamps { .grouped }

        /// Decodes the raw value; values this SDK version does not know become `.grouped`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }

    /// Colors and type.
    public struct Theme: Sendable, Equatable, Codable {
        /// Person's bubbles and buttons.
        public var accent: PingFrontColor?
        /// Chat background.
        public var background: PingFrontColor?
        /// Team bubble fill.
        public var teamBubble: PingFrontColor?
        /// Light, dark or automatic.
        public var scheme: Scheme?
        /// Font design.
        public var font: FontStyle?
        /// Bubble corners.
        public var corners: Corners?
        /// Spacing density.
        public var density: Density?

        private enum CodingKeys: String, CodingKey { case accent, background, teamBubble, scheme, font, corners, density }

        /// Nothing set.
        public init() {}

        /// Decodes each field on its own; a bad value drops only that field.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accent = c.tolerant(PingFrontColor.self, forKey: .accent)
            background = c.tolerant(PingFrontColor.self, forKey: .background)
            teamBubble = c.tolerant(PingFrontColor.self, forKey: .teamBubble)
            scheme = c.tolerant(Scheme.self, forKey: .scheme)
            font = c.tolerant(FontStyle.self, forKey: .font)
            corners = c.tolerant(Corners.self, forKey: .corners)
            density = c.tolerant(Density.self, forKey: .density)
        }
    }
    /// Header options.
    public struct Header: Sendable, Equatable, Codable {
        /// One face, the team, or the app icon.
        public var style: HeaderStyle?
        /// The teammate the person header shows.
        public var memberId: String?
        /// Title for the team and app styles.
        public var title: LocalizedText?
        /// Show the teammate's local time.
        public var showLocalTime: Bool?
        /// Show the reply expectation.
        public var showReplyExpectation: Bool?

        private enum CodingKeys: String, CodingKey { case style, memberId, title, showLocalTime, showReplyExpectation }

        /// Nothing set.
        public init() {}

        /// Decodes each field on its own; a bad value drops only that field.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            style = c.tolerant(HeaderStyle.self, forKey: .style)
            memberId = c.tolerant(String.self, forKey: .memberId)
            title = c.tolerant(LocalizedText.self, forKey: .title)
            showLocalTime = c.tolerant(Bool.self, forKey: .showLocalTime)
            showReplyExpectation = c.tolerant(Bool.self, forKey: .showReplyExpectation)
        }
    }
    /// Welcome (empty state) options.
    public struct Welcome: Sendable, Equatable, Codable {
        /// Welcome title.
        public var title: LocalizedText?
        /// Welcome body.
        public var body: LocalizedText?
        /// Show team faces.
        public var showFaces: Bool?

        private enum CodingKeys: String, CodingKey { case title, body, showFaces }

        /// Nothing set.
        public init() {}

        /// Decodes each field on its own; a bad value drops only that field.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = c.tolerant(LocalizedText.self, forKey: .title)
            body = c.tolerant(LocalizedText.self, forKey: .body)
            showFaces = c.tolerant(Bool.self, forKey: .showFaces)
        }
    }
    /// A topic chip.
    public struct Topic: Sendable, Equatable, Codable {
        /// Topic id.
        public var id: String
        /// Chip label.
        public var label: LocalizedText
        /// Chip symbol.
        public var symbol: TopicSymbol
        /// Composer prefill; without one the chip starts the thread.
        public var prefill: LocalizedText?
    }
    /// Composer options.
    public struct Composer: Sendable, Equatable, Codable {
        /// Placeholder text.
        public var placeholder: LocalizedText?
        /// Allow photos.
        public var photos: Bool?
        /// Allow bug reports.
        public var reports: Bool?

        private enum CodingKeys: String, CodingKey { case placeholder, photos, reports }

        /// Nothing set.
        public init() {}

        /// Decodes each field on its own; a bad value drops only that field.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            placeholder = c.tolerant(LocalizedText.self, forKey: .placeholder)
            photos = c.tolerant(Bool.self, forKey: .photos)
            reports = c.tolerant(Bool.self, forKey: .reports)
        }
    }
    /// Message list options.
    public struct Messages: Sendable, Equatable, Codable {
        /// Show author names.
        public var showNames: Bool?
        /// Show team avatars beside messages.
        public var showAvatars: Bool?
        /// Timestamps per group or per message.
        public var timestamps: Timestamps?

        private enum CodingKeys: String, CodingKey { case showNames, showAvatars, timestamps }

        /// Nothing set.
        public init() {}

        /// Decodes each field on its own; a bad value drops only that field.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            showNames = c.tolerant(Bool.self, forKey: .showNames)
            showAvatars = c.tolerant(Bool.self, forKey: .showAvatars)
            timestamps = c.tolerant(Timestamps.self, forKey: .timestamps)
        }
    }

    /// Colors and type.
    public var theme = Theme()
    /// Header options.
    public var header = Header()
    /// Welcome options.
    public var welcome = Welcome()
    /// Up to six topics.
    ///
    /// An empty list counts as unset.
    public var topics: [Topic] = []
    /// Composer options.
    public var composer = Composer()
    /// Message list options.
    public var messages = Messages()
    /// For example "Usually replies within a few hours".
    public var replyExpectation: LocalizedText?
    /// The assistant's display name.
    ///
    /// AI replies are always labelled.
    public var aiName: String?

    /// A look with nothing set.
    public init() {}

    private enum Keys: String, CodingKey { case theme, header, welcome, topics, composer, messages, replyExpectation, aiName }

    /// Decodes the wire format; values this SDK version does not know are kept as unknown.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? Theme()
        header = (try? c.decodeIfPresent(Header.self, forKey: .header)) ?? Header()
        welcome = (try? c.decodeIfPresent(Welcome.self, forKey: .welcome)) ?? Welcome()
        topics = Array(try c.decodeLossyArray(Topic.self, forKey: .topics).prefix(6))
        composer = (try? c.decodeIfPresent(Composer.self, forKey: .composer)) ?? Composer()
        messages = (try? c.decodeIfPresent(Messages.self, forKey: .messages)) ?? Messages()
        replyExpectation = try? c.decodeIfPresent(LocalizedText.self, forKey: .replyExpectation)
        aiName = try? c.decodeIfPresent(String.self, forKey: .aiName)
    }
}

/// What the SDK reports about the host app so the dashboard editor starts from it.
package struct HostLook: Sendable, Equatable, Codable {
    /// Display name.
    package var appName: String
    /// The AccentColor asset, resolved for light and dark.
    package var accent: PingFrontColor?
    /// The app's background, if known.
    package var background: PingFrontColor?
    /// The app's font style, if known.
    package var font: String?
    /// The app icon as a base64 128 px PNG.
    package var iconPng: String?

    /// Creates a host look.
    package init(
        appName: String, accent: PingFrontColor? = nil, background: PingFrontColor? = nil, font: String? = nil, iconPng: String? = nil
    ) {
        self.appName = appName
        self.accent = accent
        self.background = background
        self.font = font
        self.iconPng = iconPng
    }
}

/// `GET /config`: the public app configuration with the chat look.
package struct AppConfig: Sendable, Equatable, Codable {
    package struct Features: Sendable, Equatable, Codable {
        package var photos: Bool
        package var reports: Bool
        package var translation: Bool
        package var ai: Bool
        /// When on, pushes set the app icon badge to the unread count (off by default: the host owns its badge).
        package var appBadge: Bool = false
        /// True while the app's org is on pingfront's Free plan.
        ///
        /// The welcome screen then shows one small line saying the chat runs on pingfront. Absent means false
        /// (older servers, Pro).
        package var branding: Bool = false
        package static let all = Features(photos: true, reports: true, translation: false, ai: false)

        package init(photos: Bool, reports: Bool, translation: Bool, ai: Bool, appBadge: Bool = false, branding: Bool = false) {
            self.photos = photos
            self.reports = reports
            self.translation = translation
            self.ai = ai
            self.appBadge = appBadge
            self.branding = branding
        }

        private enum Keys: String, CodingKey { case photos, reports, translation, ai, appBadge, branding }

        package init(from decoder: any Decoder) throws {
            // Optional flags may be missing (older servers); one missing flag never resets the others.
            let c = try decoder.container(keyedBy: Keys.self)
            photos = try c.decodeIfPresent(Bool.self, forKey: .photos) ?? Features.all.photos
            reports = try c.decodeIfPresent(Bool.self, forKey: .reports) ?? Features.all.reports
            translation = try c.decodeIfPresent(Bool.self, forKey: .translation) ?? false
            ai = try c.decodeIfPresent(Bool.self, forKey: .ai) ?? false
            appBadge = try c.decodeIfPresent(Bool.self, forKey: .appBadge) ?? false
            branding = try c.decodeIfPresent(Bool.self, forKey: .branding) ?? false
        }
    }
    package var schema: Int
    package var revision: Int
    package var draft: Bool
    package var appName: String
    package var appIconUrl: URL?
    package var look: ChatLook
    package var team: [TeamMember]
    package var features: Features
    package var liveUrl: URL?
    /// The app's App Store id, when the team set it: review cards without a store URL open its review page.
    package var appStoreId: String?

    package init(
        revision: Int, draft: Bool, appName: String, appIconUrl: URL? = nil, look: ChatLook, team: [TeamMember], features: Features = .all,
        liveUrl: URL? = nil, appStoreId: String? = nil
    ) {
        schema = 1
        self.revision = revision
        self.draft = draft
        self.appName = appName
        self.appIconUrl = appIconUrl
        self.look = look
        self.team = team
        self.features = features
        self.liveUrl = liveUrl
        self.appStoreId = appStoreId
    }

    private enum Keys: String, CodingKey { case schema, revision, draft, appName, appIconUrl, look, team, features, liveUrl, appStoreId }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        appName = try c.decode(String.self, forKey: .appName)
        appIconUrl = try? c.decodeIfPresent(URL.self, forKey: .appIconUrl)
        look = (try? c.decodeIfPresent(ChatLook.self, forKey: .look)) ?? ChatLook()
        team = try c.decodeLossyArray(TeamMember.self, forKey: .team)
        features = (try? c.decodeIfPresent(Features.self, forKey: .features)) ?? .all
        liveUrl = try? c.decodeIfPresent(URL.self, forKey: .liveUrl)
        // Digits only (the contract's pattern); anything else is ignored, never put into a URL.
        let storeId = try? c.decodeIfPresent(String.self, forKey: .appStoreId)
        appStoreId = storeId.flatMap { $0.isEmpty || $0.count > 20 || !$0.allSatisfy(\.isASCII) || !$0.allSatisfy(\.isNumber) ? nil : $0 }
    }
}
