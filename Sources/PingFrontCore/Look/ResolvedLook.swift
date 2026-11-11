public import Foundation

/// A topic chip on the welcome screen.
///
/// Use a preset (`.billing`, `.bug`, `.idea`, …) or `init(id:label:symbol:prefill:)`.
public struct ChatTopic: Sendable, Equatable, Hashable, Identifiable {
    /// Stable id (`[a-z0-9_-]{1,32}`).
    public var id: String
    /// The label. `nil` uses the SDK's built-in, translated label for the preset id.
    public var label: LocalizedText?
    /// The chip symbol.
    public var symbol: TopicSymbol
    /// With a prefill, tapping the chip fills the composer.
    ///
    /// Without one, tapping starts the thread on that topic.
    public var prefill: LocalizedText?

    /// Creates a custom topic.
    public init(id: String, label: LocalizedText?, symbol: TopicSymbol, prefill: LocalizedText? = nil) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.prefill = prefill
    }

    /// Creates a custom topic with a single-language label (localize it yourself with `String(localized:)`).
    public init(id: String, label: String, symbol: TopicSymbol = .other, prefill: String? = nil) {
        self.init(id: id, label: LocalizedText(default: label), symbol: symbol, prefill: prefill.map { LocalizedText(default: $0) })
    }

    /// "Ask about billing".
    public static let billing = ChatTopic(preset: .billing)
    /// "Report a bug".
    public static let bug = ChatTopic(preset: .bug)
    /// "Share an idea".
    public static let idea = ChatTopic(preset: .idea)
    /// "Ask a question".
    public static let question = ChatTopic(preset: .question)
    /// "Get help with my account".
    public static let account = ChatTopic(preset: .account)
    /// "Send feedback".
    public static let feedback = ChatTopic(preset: .feedback)
    /// "Ask about gifts".
    public static let gift = ChatTopic(preset: .gift)
    /// "Restore purchases".
    public static let restore = ChatTopic(preset: .restore)
    /// "Ask about privacy".
    public static let privacy = ChatTopic(preset: .privacy)

    init(preset: TopicPreset) { self.init(id: preset.rawValue, label: nil, symbol: preset.symbol) }

    /// The default topics: Ask about billing, Report a bug, Share an idea.
    public static let defaults: [ChatTopic] = [.billing, .bug, .idea]
}

/// Look values set in code with `config.appearance`.
///
/// Every field is optional; unset fields fall
/// through to values inferred from the host app, then SDK defaults. The published remote look wins over these.
public struct ChatAppearance: Sendable, Equatable {
    /// Person's bubbles and buttons.
    ///
    /// Default: the app's AccentColor asset.
    public var accent: PingFrontColor?
    /// Chat background.
    public var background: PingFrontColor?
    /// Team bubble fill.
    public var teamBubble: PingFrontColor?
    /// Force light or dark, or follow the system.
    public var scheme: ChatLook.Scheme?
    /// System, rounded or serif.
    public var font: ChatLook.FontStyle?
    /// Bubble corners.
    public var corners: ChatLook.Corners?
    /// Spacing density.
    public var density: ChatLook.Density?
    /// Header style.
    public var headerStyle: ChatLook.HeaderStyle?
    /// Which teammate the person header shows.
    public var headerMemberId: String?
    /// Header title for team and app styles.
    public var headerTitle: String?
    /// Show the teammate's local time.
    public var showsLocalTime: Bool?
    /// Show the reply expectation line.
    public var showsReplyExpectation: Bool?
    /// Welcome title.
    public var welcomeTitle: String?
    /// Welcome body.
    public var welcomeBody: String?
    /// Show team faces on the welcome screen.
    public var showsWelcomeFaces: Bool?
    /// Composer placeholder.
    public var composerPlaceholder: String?
    /// Allow photos.
    public var allowsPhotos: Bool?
    /// Allow bug reports.
    public var allowsReports: Bool?
    /// Show author names.
    public var showsNames: Bool?
    /// Show team avatars beside messages.
    public var showsAvatars: Bool?
    /// Timestamps per group or per message.
    public var timestamps: ChatLook.Timestamps?
    /// For example "Usually replies within a few hours".
    public var replyExpectation: String?
    /// The assistant's display name.
    public var aiName: String?

    /// Nothing set.
    public init() {}
}

/// Look values inferred from the host app by the UI module.
package struct HostAppInfo: Sendable, Equatable {
    package var appName: String
    package var accent: PingFrontColor?
    package var iconPNG: Data?
    package var appVersion: String

    package init(appName: String, accent: PingFrontColor?, iconPNG: Data?, appVersion: String) {
        self.appName = appName
        self.accent = accent
        self.iconPNG = iconPNG
        self.appVersion = appVersion
    }

    package var hostLook: HostLook {
        HostLook(appName: appName, accent: accent, iconPng: iconPNG.map { $0.base64EncodedString() })
    }
}

/// The single resolved look the chat renders.
///
/// Precedence for every field:
/// published remote look, then `config.appearance`, then values inferred from the host app, then SDK defaults.
/// Colors are adjusted toward WCAG AA when a configured value would make body text unreadable.
public struct ResolvedLook: Sendable, Equatable {
    /// The app name.
    public var appName: String
    /// The app icon URL from the dashboard.
    public var appIconURL: URL?
    /// The app icon read from the bundle.
    public var appIconPNG: Data?
    /// Person's bubbles and buttons (contrast-adjusted).
    public var accent: PingFrontColor
    /// Text on the accent, picked by contrast (never configured).
    public var onAccent: PingFrontColor
    /// Chat background.
    public var background: PingFrontColor
    /// Team bubble fill.
    public var teamBubble: PingFrontColor
    /// Body text on background and team bubbles.
    public var text: PingFrontColor
    /// Secondary text.
    public var muted: PingFrontColor
    /// Light, dark or automatic.
    public var scheme: ChatLook.Scheme
    /// Font design.
    public var font: ChatLook.FontStyle
    /// Bubble corners.
    public var corners: ChatLook.Corners
    /// Spacing density.
    public var density: ChatLook.Density
    /// Header style.
    public var headerStyle: ChatLook.HeaderStyle
    /// The teammate the person header shows.
    public var headerMemberId: String?
    /// Header title for team and app styles.
    public var headerTitle: LocalizedText?
    /// Show the teammate's local time.
    public var showsLocalTime: Bool
    /// Show the reply expectation.
    public var showsReplyExpectation: Bool
    /// Welcome title (nil: built-in).
    public var welcomeTitle: LocalizedText?
    /// Welcome body (nil: built-in).
    public var welcomeBody: LocalizedText?
    /// Show team faces on the welcome screen.
    public var showsWelcomeFaces: Bool
    /// Topic chips, at most six.
    public var topics: [ChatTopic]
    /// Composer placeholder (nil: built-in).
    public var composerPlaceholder: LocalizedText?
    /// Photos allowed.
    public var allowsPhotos: Bool
    /// Bug reports allowed.
    public var allowsReports: Bool
    /// Show author names.
    public var showsNames: Bool
    /// Show team avatars beside messages.
    public var showsAvatars: Bool
    /// Timestamps per group or per message.
    public var timestamps: ChatLook.Timestamps
    /// The reply expectation.
    public var replyExpectation: LocalizedText?
    /// The assistant's display name.
    public var aiName: String
    /// The team from the config.
    public var team: [TeamMember]
    /// The look is an unpublished draft (test devices only).
    public var isDraft: Bool
    /// Remote revision, 0 when none.
    public var revision: Int
    /// The welcome screen shows the "Chat by pingfront" line.
    ///
    /// Set from `features.branding` (the app's org is on the Free plan). Never inside a conversation.
    package var showsBranding = false

    /// Bubble radius: 18, 12 or 6 pt.
    public var bubbleRadius: Double {
        switch corners {
        case .round: 18
        case .soft: 12
        case .square: 6
        }
    }

    /// Card radius: 16, 12 or 6 pt with the corners token.
    public var cardRadius: Double {
        switch corners {
        case .round: 16
        case .soft: 12
        case .square: 6
        }
    }

    /// SDK defaults (brand tokens).
    package enum Defaults {
        // iOS system colors: (elevated) systemBackground for sheets, systemGray6 bubbles, label, secondary label (AA).
        package static let background = PingFrontColor(light: "#FFFFFF", dark: "#1C1C1E")
        package static let teamBubble = PingFrontColor(light: "#E9E9EB", dark: "#323236")
        package static let text = PingFrontColor(light: "#000000", dark: "#FFFFFF")
        /// pingfront's `muted` design token; a customer's ChatLook still wins.
        package static let muted = PingFrontColor(light: "#6C6C78", dark: "#9C9CA8")
        /// systemBlue, used when the host app has no AccentColor.
        package static let accent = PingFrontColor(light: "#007AFF", dark: "#0A84FF")
    }

    /// Merges the layers. `remote` is the published (or, on test devices, draft) config.
    package static func resolve(remote: AppConfig?, code: ChatAppearance, codeTopics: [ChatTopic]?, host: HostAppInfo?) -> ResolvedLook {
        let look = remote?.look ?? ChatLook()
        let theme = look.theme
        let accent = theme.accent ?? code.accent ?? host?.accent ?? Defaults.accent
        let background = theme.background ?? code.background ?? Defaults.background
        let teamBubble = theme.teamBubble ?? code.teamBubble ?? Defaults.teamBubble
        let remoteTopics: [ChatTopic] = look.topics.map { ChatTopic(id: $0.id, label: $0.label, symbol: $0.symbol, prefill: $0.prefill) }
        let topics = !remoteTopics.isEmpty ? remoteTopics : (codeTopics ?? ChatTopic.defaults)
        let features = remote?.features ?? .all

        var resolved = ResolvedLook(
            appName: remote?.appName ?? host?.appName ?? "",
            appIconURL: remote?.appIconUrl,
            appIconPNG: host?.iconPNG,
            accent: accent,
            onAccent: accent,
            background: background,
            teamBubble: teamBubble,
            text: Defaults.text,
            muted: Defaults.muted,
            scheme: theme.scheme ?? code.scheme ?? .auto,
            font: theme.font ?? code.font ?? .system,
            corners: theme.corners ?? code.corners ?? .round,
            density: theme.density ?? code.density ?? .comfortable,
            headerStyle: look.header.style ?? code.headerStyle ?? .person,
            headerMemberId: look.header.memberId ?? code.headerMemberId,
            headerTitle: look.header.title ?? code.headerTitle.map(LocalizedText.init(default:)),
            showsLocalTime: look.header.showLocalTime ?? code.showsLocalTime ?? true,
            showsReplyExpectation: look.header.showReplyExpectation ?? code.showsReplyExpectation ?? true,
            welcomeTitle: look.welcome.title ?? code.welcomeTitle.map(LocalizedText.init(default:)),
            welcomeBody: look.welcome.body ?? code.welcomeBody.map(LocalizedText.init(default:)),
            showsWelcomeFaces: look.welcome.showFaces ?? code.showsWelcomeFaces ?? true,
            topics: Array(topics.prefix(6)),
            composerPlaceholder: look.composer.placeholder ?? code.composerPlaceholder.map(LocalizedText.init(default:)),
            allowsPhotos: features.photos && (look.composer.photos ?? code.allowsPhotos ?? true),
            allowsReports: features.reports && (look.composer.reports ?? code.allowsReports ?? true),
            showsNames: look.messages.showNames ?? code.showsNames ?? true,
            showsAvatars: look.messages.showAvatars ?? code.showsAvatars ?? true,
            timestamps: look.messages.timestamps ?? code.timestamps ?? .grouped,
            replyExpectation: look.replyExpectation ?? code.replyExpectation.map(LocalizedText.init(default:)),
            aiName: look.aiName ?? code.aiName ?? "Assistant",
            team: remote?.team ?? [],
            isDraft: remote?.draft ?? false,
            revision: remote?.revision ?? 0
        )
        resolved.showsBranding = features.branding
        resolved.applyContrast()
        return resolved
    }

    /// Picks on-accent text by contrast and nudges surfaces toward AA (4.5:1) for body text.
    package mutating func applyContrast() {
        func fix(_ pair: PingFrontColor, against text: PingFrontColor) -> PingFrontColor {
            PingFrontColor(
                light: Contrast.adjust(pair.light, toReadWith: text.light),
                dark: Contrast.adjust(pair.dark, toReadWith: text.dark)
            )
        }
        background = fix(background, against: text)
        teamBubble = fix(teamBubble, against: text)
        let original = accent
        accent = PingFrontColor(light: Contrast.accentAdjusted(original.light), dark: Contrast.accentAdjusted(original.dark))
        onAccent = PingFrontColor(light: Contrast.bestText(on: accent.light), dark: Contrast.bestText(on: accent.dark))
        muted = PingFrontColor(
            light: Contrast.adjustText(muted.light, on: background.light, minimum: 4.5),
            dark: Contrast.adjustText(muted.dark, on: background.dark, minimum: 4.5)
        )
    }
}

/// WCAG contrast helpers.
package enum Contrast {
    /// AA for body text.
    package static let minimum = 4.5
    /// Dark text used on light accents (label black).
    package static let darkText = RGBColor(red: 0, green: 0, blue: 0)
    /// White text is preferred on an accent when it reaches this ratio (the accent is then darkened to AA).
    package static let preferWhiteAbove = 3.0
    /// Light text used on dark accents.
    package static let lightText = RGBColor.white

    /// The text color for `background`: white when it reaches 3:1 (the iOS convention for tinted
    /// controls), otherwise whichever of black or white has more contrast.
    package static func bestText(on background: RGBColor) -> RGBColor {
        if RGBColor.contrast(lightText, background) >= preferWhiteAbove { return lightText }
        return RGBColor.contrast(darkText, background) >= RGBColor.contrast(lightText, background) ? darkText : lightText
    }

    /// Moves an accent away from its text color until the text reaches 4.5:1.
    ///
    /// With white text the accent darkens slightly (iOS blue becomes a deeper blue); with black text it lightens.
    package static func accentAdjusted(_ accent: RGBColor) -> RGBColor {
        let text = bestText(on: accent)
        let target = text == lightText ? RGBColor.black : RGBColor.white
        var color = accent
        var step = 0
        while RGBColor.contrast(text, color) < minimum, step < 40 {
            step += 1
            color = accent.mixed(with: target, amount: Double(step) * 0.025)
        }
        return color
    }

    /// Moves a surface away from `text` until text on it reaches 4.5:1.
    package static func adjust(_ surface: RGBColor, toReadWith text: RGBColor) -> RGBColor {
        guard RGBColor.contrast(surface, text) < minimum else { return surface }
        let target = text.luminance > 0.5 ? RGBColor.black : RGBColor.white
        var step = 0
        var color = surface
        while RGBColor.contrast(color, text) < minimum, step < 40 {
            step += 1
            color = surface.mixed(with: target, amount: Double(step) * 0.025)
        }
        return color
    }

    /// Moves text away from its background until it reaches `minimum`.
    package static func adjustText(_ text: RGBColor, on background: RGBColor, minimum: Double) -> RGBColor {
        guard RGBColor.contrast(text, background) < minimum else { return text }
        // Mix toward whichever extreme contrasts more with this background; the other may never reach `minimum`.
        let target = RGBColor.contrast(.black, background) >= RGBColor.contrast(.white, background) ? RGBColor.black : RGBColor.white
        var step = 0
        var color = text
        while RGBColor.contrast(color, background) < minimum, step < 40 {
            step += 1
            color = text.mixed(with: target, amount: Double(step) * 0.025)
        }
        return color
    }
}

/// The built-in topics: one table for ids, English labels (translated by the UI) and symbols.
package enum TopicPreset: String, CaseIterable, Sendable {
    case billing, bug, idea, question, account, feedback, gift, restore, privacy

    /// The English label, also the localization key.
    ///
    /// One grammar: each says what the person wants to do.
    package var label: String {
        switch self {
        case .billing: "Ask about billing"
        case .bug: "Report a bug"
        case .idea: "Share an idea"
        case .question: "Ask a question"
        case .account: "Get help with my account"
        case .feedback: "Send feedback"
        case .gift: "Ask about gifts"
        case .restore: "Restore purchases"
        case .privacy: "Ask about privacy"
        }
    }

    /// The sentence a topic puts into the composer (English key); `nil` for topics that open a flow.
    package var starter: String? {
        switch self {
        case .billing: "I have a question about billing: "
        case .bug: nil
        case .idea: "I have an idea: "
        case .question: "I have a question: "
        case .account: "I need help with my account: "
        case .feedback: "Some feedback: "
        case .gift: "I have a question about gifts: "
        case .restore: "Restoring my purchases didn't work: "
        case .privacy: "I have a privacy question: "
        }
    }

    package var symbol: TopicSymbol {
        switch self {
        case .billing: .billing
        case .bug: .bug
        case .idea: .idea
        case .question: .question
        case .account: .account
        case .feedback: .feedback
        case .gift: .gift
        case .restore: .restore
        case .privacy: .privacy
        }
    }
}

extension ResolvedLook {
    /// The fill of a state row on a card ("Current plan"): iOS `tertiarySystemFill` over the team bubble.
    ///
    /// With Increase Contrast it moves away from the text until the pair reaches 7:1.
    package func stateFill(_ mode: ColorMode, increasedContrast: Bool = false) -> RGBColor {
        let base = teamBubble.value(in: mode).mixed(with: RGBColor(rgb: 0x767680), amount: mode == .dark ? 0.24 : 0.12)
        guard increasedContrast else { return base }
        let ink = Self.ink(on: base)
        let away = ink == RGBColor.black ? RGBColor.white : RGBColor.black
        var fill = base
        var step = 0
        while RGBColor.contrast(ink, fill) < 7, step < 40 {
            step += 1
            fill = base.mixed(with: away, amount: Double(step) * 0.025)
        }
        return fill
    }

    /// Secondary-label text on `stateFill`, deepened until it reads 4.5:1; with Increase Contrast, black
    /// or white at 7:1.
    package func stateText(_ mode: ColorMode, increasedContrast: Bool) -> RGBColor {
        let fill = stateFill(mode, increasedContrast: increasedContrast)
        guard !increasedContrast else { return Self.ink(on: fill) }
        return Contrast.adjustText(muted.value(in: mode), on: fill, minimum: 4.5)
    }

    private static func ink(on background: RGBColor) -> RGBColor {
        RGBColor.contrast(.black, background) >= RGBColor.contrast(.white, background) ? .black : .white
    }
}

/// The header's status under the name: the reply expectation over "It's 11:20 PM for Deniz".
///
/// Two complete
/// sentences; a time never appears without its verb and the teammate's name.
package enum HeaderStatus {
    /// The reply expectation to show, if any: none while the person can't send (blocked, the app paused,
    /// verification required), when a promise of a reply would be false.
    package static func expectation(_ expectation: String?, shown: Bool, policy: SendPolicy) -> String? {
        shown && policy.canSend ? expectation : nil
    }

    package static func text(expectation: String?, time: String?, name: String?, itsFor: (String, String) -> String) -> String? {
        let first = expectation?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).nilIfEmpty
        var second: String?
        if let time, let name, !name.isEmpty { second = itsFor(time, name) }
        let lines = [first, second].compactMap(\.self)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What tapping a topic does.
///
/// Nothing is ever sent until the person taps Send.
package enum TopicAction: Equatable, Sendable {
    /// Open the bug report flow.
    case openReport
    /// Put this text into the composer and focus it.
    case compose(String)

    /// The topic's prefill wins; "Report a bug" opens the report; presets insert their starter sentence;
    /// custom topics insert their label.
    package static func resolve(id: String, prefill: String?, label: String, translate: (String) -> String) -> TopicAction {
        if let prefill, !prefill.isEmpty { return .compose(prefill) }
        let preset = TopicPreset(rawValue: id)
        if preset == .bug { return .openReport }
        if let starter = preset?.starter { return .compose(translate(starter)) }
        return .compose("\(label): ")
    }
}
