import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore

@Suite("Chat look")
struct LookTests {
    let host = HostAppInfo(
        appName: "Clockwise Host", accent: PingFrontColor(light: "#2F4FD0", dark: "#8EA2FF"), iconPNG: Data([1]), appVersion: "1.0 (1)")

    func remote(_ look: ChatLook, features: AppConfig.Features = .all) -> AppConfig {
        AppConfig(revision: 7, draft: false, appName: "Clockwise", look: look, team: [], features: features)
    }

    @Test("SDK defaults when nothing is set")
    func defaults() {
        let look = ResolvedLook.resolve(remote: nil, code: ChatAppearance(), codeTopics: nil, host: nil)
        // systemBlue by default, deepened just enough for white text to reach 4.5:1.
        #expect(look.accent.light == Contrast.accentAdjusted(ResolvedLook.Defaults.accent.light))
        #expect(look.onAccent.light == .white && RGBColor.contrast(.white, look.accent.light) >= 4.5)
        #expect(look.scheme == .auto && look.font == .system && look.corners == .round && look.density == .comfortable)
        #expect(look.headerStyle == .person && look.showsLocalTime && look.showsReplyExpectation)
        #expect(look.topics == ChatTopic.defaults)
        #expect(look.allowsPhotos && look.allowsReports && look.showsNames && look.showsAvatars && look.timestamps == .grouped)
        #expect(look.aiName == "Assistant" && look.bubbleRadius == 18 && look.cardRadius == 16)
        #expect(look.background == ResolvedLook.Defaults.background)
    }

    @Test("Field by field: remote > code > host > default")
    func precedence() {
        var code = ChatAppearance()
        code.accent = PingFrontColor(light: "#5856D6", dark: "#5E5CE6")
        code.corners = .soft
        code.font = .rounded
        code.headerTitle = "Code title"
        code.aiName = "Code AI"
        code.showsNames = false

        let hostOnly = ResolvedLook.resolve(remote: nil, code: ChatAppearance(), codeTopics: nil, host: host)
        #expect(hostOnly.accent.light == Contrast.accentAdjusted(host.accent!.light))
        #expect(hostOnly.appName == "Clockwise Host")
        #expect(hostOnly.appIconPNG == Data([1]))

        let withCode = ResolvedLook.resolve(remote: nil, code: code, codeTopics: [.restore], host: host)
        #expect(withCode.accent.light == Contrast.accentAdjusted(code.accent!.light))
        #expect(withCode.corners == .soft && withCode.bubbleRadius == 12)
        #expect(withCode.headerTitle == LocalizedText(default: "Code title"))
        #expect(withCode.topics == [.restore])
        #expect(!withCode.showsNames)

        var look = ChatLook()
        look.theme.accent = PingFrontColor(light: "#1F6F5C", dark: "#5CC8A8")
        look.theme.corners = .square
        look.aiName = "Clocky"
        let withRemote = ResolvedLook.resolve(remote: remote(look), code: code, codeTopics: [.restore], host: host)
        #expect(withRemote.accent.light == Contrast.accentAdjusted(look.theme.accent!.light))
        #expect(withRemote.corners == .square && withRemote.bubbleRadius == 6 && withRemote.cardRadius == 6)
        #expect(withRemote.aiName == "Clocky")
        // Unset remote fields fall through to code.
        #expect(withRemote.font == .rounded)
        #expect(withRemote.headerTitle == LocalizedText(default: "Code title"))
        #expect(!withRemote.showsNames)
        // An empty remote topic list counts as unset.
        #expect(withRemote.topics == [.restore])
        #expect(withRemote.appName == "Clockwise" && withRemote.revision == 7)
    }

    @Test("Remote topics replace code topics, capped at six")
    func remoteTopics() {
        var look = ChatLook()
        look.topics = (1...6).map { ChatLook.Topic(id: "t\($0)", label: LocalizedText(default: "T\($0)"), symbol: .question, prefill: nil) }
        let resolved = ResolvedLook.resolve(remote: remote(look), code: ChatAppearance(), codeTopics: [.billing], host: nil)
        #expect(resolved.topics.map(\.id) == ["t1", "t2", "t3", "t4", "t5", "t6"])
    }

    @Test("Feature flags and composer toggles are AND-ed")
    func features() {
        var look = ChatLook()
        look.composer.photos = true
        let off = AppConfig.Features(photos: false, reports: true, translation: false, ai: false)
        #expect(!ResolvedLook.resolve(remote: remote(look, features: off), code: ChatAppearance(), codeTopics: nil, host: nil).allowsPhotos)
        look.composer.reports = false
        #expect(!ResolvedLook.resolve(remote: remote(look), code: ChatAppearance(), codeTopics: nil, host: nil).allowsReports)
        var code = ChatAppearance()
        code.allowsPhotos = false
        #expect(!ResolvedLook.resolve(remote: nil, code: code, codeTopics: nil, host: nil).allowsPhotos)
        #expect(ResolvedLook.resolve(remote: remote(ChatLook()), code: ChatAppearance(), codeTopics: nil, host: nil).allowsPhotos)
    }

    @Test(
        "Localized lookup: exact tag, base language, then default",
        arguments: [
            ("pt-BR", "Oi" as String?), ("PT-br", "Oi"), ("pt-PT", "Olá"), ("pt", "Olá"), ("de_DE", "Hallo"), ("fr", "Hi"),
            ("zh-Hans-CN", "Hi"),
        ])
    func localized(tag: String, expected: String?) {
        let text = LocalizedText(["default": "Hi", "pt": "Olá", "pt-BR": "Oi", "de": "Hallo"])
        #expect(text.resolve(for: tag) == expected)
    }

    @Test("Localized text without a default resolves to nil for other languages")
    func localizedNoDefault() {
        #expect(LocalizedText(["de": "Hallo"]).resolve(for: "fr") == nil)
    }

    @Test("Text on the accent is picked by contrast")
    func contrastPicking() throws {
        let signal = try #require(RGBColor(hex: "#FFCE3A"))
        let reply = try #require(RGBColor(hex: "#3550E6"))
        #expect(Contrast.bestText(on: signal) == Contrast.darkText)
        #expect(Contrast.bestText(on: reply) == .white)
        #expect(RGBColor.contrast(.white, .black) > 20.9)
        #expect(RGBColor.contrast(Contrast.darkText, .white) > 20)
        #expect(RGBColor(hex: "#3550e6")?.hex == "#3550E6")
        #expect(RGBColor(hex: "3550E6") != nil && RGBColor(hex: "#355") == nil && RGBColor(hex: "#GGGGGG") == nil)
    }

    @Test(
        "Any configured colors are adjusted until body text reaches 4.5:1",
        arguments: [
            "#FFE066", "#777777", "#8FA0FF", "#FFFFFF", "#000000", "#18233F", "#C9D2E0", "#FF2D55", "#34C759", "#3550E6",
        ])
    func contrastRepair(hex: String) {
        var look = ChatLook()
        look.theme.accent = PingFrontColor(hex: hex)
        look.theme.background = PingFrontColor(hex: hex)
        look.theme.teamBubble = PingFrontColor(hex: hex)
        let resolved = ResolvedLook.resolve(
            remote: AppConfig(revision: 1, draft: false, appName: "A", look: look, team: []), code: ChatAppearance(), codeTopics: nil,
            host: nil)
        for dark in [false, true] {
            let text = resolved.text.value(in: dark ? .dark : .light)
            #expect(
                RGBColor.contrast(resolved.onAccent.value(in: dark ? .dark : .light), resolved.accent.value(in: dark ? .dark : .light))
                    >= 4.5,
                "accent \(hex) dark=\(dark)")
            #expect(RGBColor.contrast(text, resolved.background.value(in: dark ? .dark : .light)) >= 4.5, "background \(hex) dark=\(dark)")
            #expect(RGBColor.contrast(text, resolved.teamBubble.value(in: dark ? .dark : .light)) >= 4.5, "team bubble \(hex) dark=\(dark)")
            #expect(
                RGBColor.contrast(resolved.muted.value(in: dark ? .dark : .light), resolved.background.value(in: dark ? .dark : .light))
                    >= 4.5,
                "muted on \(hex) dark=\(dark)")
        }
    }

    @Test("Colors that already pass are left alone")
    func contrastUntouched() {
        let resolved = ResolvedLook.resolve(remote: nil, code: ChatAppearance(), codeTopics: nil, host: nil)
        #expect(resolved.background == ResolvedLook.Defaults.background)
        #expect(resolved.teamBubble == ResolvedLook.Defaults.teamBubble)
        #expect(resolved.muted == ResolvedLook.Defaults.muted)
    }

    @Test("An almost empty look decodes and resolves to every default")
    func emptyLookDefaults() throws {
        let look = try WireJSON.decode(ChatLook.self, from: fixture("look-empty.json"))
        #expect(look == ChatLook())
        let resolved = ResolvedLook.resolve(
            remote: AppConfig(revision: 1, draft: false, appName: "A", look: look, team: []), code: ChatAppearance(), codeTopics: nil,
            host: nil)
        #expect(resolved.scheme == .auto && resolved.font == .system && resolved.corners == .round && resolved.density == .comfortable)
        #expect(resolved.headerStyle == .person && resolved.showsLocalTime && resolved.showsReplyExpectation && resolved.showsWelcomeFaces)
        #expect(resolved.aiName == "Assistant")
    }

    @Test("A full config decodes; unknown topic symbols fall back to `other`")
    func fullConfig() throws {
        let config = try WireJSON.decode(AppConfig.self, from: fixture("config-full.json"))
        #expect(config.revision == 3 && !config.draft && config.appName == "Clockwise")
        #expect(config.liveUrl == URL(string: "wss://api.pingfront.sh/v1/live"))
        let look = config.look
        #expect(look.theme.accent == PingFrontColor(light: "#3550E6", dark: "#7D91FF"))
        #expect(look.theme.corners == .soft && look.theme.font == .serif && look.theme.scheme == .dark && look.theme.density == .compact)
        #expect(look.header.style == .team && look.header.showLocalTime == false && look.header.title?.resolve(for: "de-AT") == "Das Team")
        #expect(look.topics.count == 2)
        #expect(look.topics[0].label.resolve(for: "tr") == "Ödeme")
        #expect(look.topics[1].symbol == .other)
        #expect(look.composer.photos == false)
        #expect(look.messages.timestamps == .always && look.messages.showAvatars == false)
        #expect(look.aiName == "Clocky")
        #expect(config.team.first?.timeZone == "Europe/Istanbul")

        let resolved = ResolvedLook.resolve(remote: config, code: ChatAppearance(), codeTopics: nil, host: nil)
        #expect(!resolved.allowsPhotos && resolved.allowsReports && !resolved.showsLocalTime && resolved.headerMemberId == "m1")
        #expect(resolved.composerPlaceholder?.resolve(for: "en") == "Write to us")
    }

    @Test("A broken look section never breaks the config")
    func brokenLook() throws {
        let data = Data(
            #"{"appName":"A","look":{"theme":{"accent":{"light":"red","dark":"blue"}},"topics":"nope"},"team":[{"id":"m","name":"N"},{"bad":true}]}"#
                .utf8)
        let config = try WireJSON.decode(AppConfig.self, from: data)
        #expect(config.look.theme.accent == nil)
        #expect(config.look.topics.isEmpty)
        #expect(config.team.map(\.id) == ["m"])
        #expect(config.features == .all)
    }
}

@Suite("State rows")
struct StateRowContrastTests {
    @Test(
        "Current plan text reaches 4.5:1 (7:1 with Increase Contrast) on every look, light and dark",
        arguments: ["#FFE066", "#777777", "#8FA0FF", "#FFFFFF", "#000000", "#18233F", "#C9D2E0", "#3550E6"])
    func stateContrast(hex: String) throws {
        var look = ChatLook()
        look.theme.background = PingFrontColor(hex: hex)
        look.theme.teamBubble = PingFrontColor(hex: hex)
        let resolved = ResolvedLook.resolve(
            remote: AppConfig(revision: 1, draft: false, appName: "A", look: look, team: []), code: ChatAppearance(), codeTopics: nil,
            host: nil)
        for mode in [ColorMode.light, .dark] {
            let fill = resolved.stateFill(mode)
            #expect(RGBColor.contrast(resolved.stateText(mode, increasedContrast: false), fill) >= 4.5, "\(hex) \(mode)")
            let strong = resolved.stateFill(mode, increasedContrast: true)
            #expect(RGBColor.contrast(resolved.stateText(mode, increasedContrast: true), strong) >= 7, "\(hex) \(mode) increased")
        }
    }
}
