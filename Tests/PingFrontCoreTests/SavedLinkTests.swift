import Foundation
import Testing
import os

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// A presenter whose links open or not, as a test says.
@MainActor final class LinkPresenter: ChatPresenting {
    var opens = true
    var opened: [URL] = []
    func presentChat(topic: ChatTopic?) {}
    func dismissChat() {}
    func open(_ url: URL) { opened.append(url) }
    func openLink(_ url: URL) async -> Bool {
        opened.append(url)
        return opens
    }
    func presentSimpleReport() {}
}

/// Records what `registerScreens` refuses (a debug build would stop).
final class InvalidScreens: Sendable {
    let messages = OSAllocatedUnfairLock<[String]>(initialState: [])
    init() {
        ScreenRegistry.invalid.withLock { [messages] in $0 = { message in messages.withLock { $0.append(message) } } }
    }
    var count: Int { messages.withLock { $0.count } }
}

/// Saved links into app screens (G2, https://pingfront.sh/docs/offers#saved-links): the registry, when it is sent, and what a tap reports.
@Suite("Saved links", .serialized)
@MainActor
struct SavedLinkTests {
    let server = StubServer()

    static func fixture(_ file: String, _ kind: String, _ name: String) throws -> Data {
        let data = try Data(contentsOf: ConformanceTests.root.appending(path: file))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?[kind] as? [[String: Any]] ?? []
        let item = try #require(items.first { ($0["name"] as? String)?.hasPrefix(name) == true }, "\(file) \(kind) \(name)")
        return try JSONSerialization.data(withJSONObject: try #require(item["value"]))
    }

    // MARK: Wire

    @Test("Link cards decode screen, params and savedLinkId (LinkCard fixtures)")
    func decodesLinkCards() throws {
        let screen = try WireJSON.decode(Card.self, from: try Self.fixture("sdk/LinkCard.json", "valid", "a screen with params"))
        guard case .link(let card) = screen else {
            Issue.record("not a link card")
            return
        }
        #expect(card.screen == LinkScreen(id: "settings.sound", params: ["tab": "tones"]))
        #expect(card.url == "https://example.com/help/sounds")
        let bare = try WireJSON.decode(Card.self, from: try Self.fixture("sdk/LinkCard.json", "valid", "a screen without a fallback"))
        guard case .link(let noFallback) = bare else {
            Issue.record("not a link card")
            return
        }
        #expect(noFallback.screen?.id == "plans/yearly" && noFallback.url.isEmpty && noFallback.savedLinkId == "lnk_2")
        // A screen this SDK can't read never breaks the card: it keeps its url.
        let odd = try WireJSON.decode(
            Card.self,
            from: Data(
                #"{"kind":"link","id":"c","title":"t","url":"https://x.dev","button":"b","screen":{"params":{"n":1}},"extra":1}"#.utf8))
        guard case .link(let kept) = odd else {
            Issue.record("not a link card")
            return
        }
        #expect(kept.screen == nil && kept.url == "https://x.dev")
    }

    @Test("Failed reports encode as the CardActionRequest fixtures; an unknown failure decodes as unknown")
    func encodesFailures() throws {
        for (name, failure) in [
            ("reports that a screen link wasn't handled", LinkFailure.notHandled),
            ("reports a screen this build doesn't register", .unknownScreen),
        ] {
            let expected =
                try JSONSerialization.jsonObject(with: try Self.fixture("sdk/CardActionRequest.json", "valid", name)) as? NSDictionary
            let encoded =
                try JSONSerialization.jsonObject(
                    with: WireJSON.encode(CardActionRequest(messageId: "msg_1", action: .failed, failure: failure))) as? NSDictionary
            #expect(encoded == expected, "\(name)")
        }
        #expect(try WireJSON.decode(LinkFailure.self, from: Data(#""crashed""#.utf8)) == .unknown)
    }

    @Test("registerScreens keeps valid ids once, at most 200, and refuses the AppInfo fixture's bad ids")
    func validates() throws {
        let refused = InvalidScreens()
        let registry = ScreenRegistry()
        let good =
            try JSONSerialization.jsonObject(with: try Self.fixture("sdk/AppInfo.json", "valid", "a build with its screens"))
            as? [String: Any]
        let goodScreens = try WireJSON.decode([AppScreen].self, from: JSONSerialization.data(withJSONObject: good?["screens"] ?? []))
        registry.register(goodScreens)
        #expect(registry.screens == goodScreens)
        #expect(refused.count == 0)
        for name in [
            "rejects a screen id with a space", "rejects a screen id that starts with punctuation", "rejects a screen id over 100",
        ] {
            let bad = try JSONSerialization.jsonObject(with: try Self.fixture("sdk/AppInfo.json", "invalid", name)) as? [String: Any]
            let screens = try WireJSON.decode([AppScreen].self, from: JSONSerialization.data(withJSONObject: bad?["screens"] ?? []))
            registry.register(screens)
            #expect(registry.screens == [], "\(name)")
        }
        #expect(refused.count == 3)
        registry.register((0..<205).map { AppScreen(id: "s\($0)") } + [AppScreen(id: "s1", title: "again")])
        #expect(registry.screens?.count == 200)
        registry.register([AppScreen(id: "a", title: String(repeating: "x", count: 80)), AppScreen(id: "a")])
        #expect(registry.screens == [AppScreen(id: "a", title: String(repeating: "x", count: 60))], "first wins, title capped")
    }

    // MARK: When the list goes out

    func makeEngine(_ facade: PingFront, persistence: MemoryPersistence, secure: MemorySecureStore, clock: TestClock = TestClock()) throws
        -> Engine
    {
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse("pk_test_abcdefghijklmnopqrstuvvd").get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(server: server), secure: secure, persistence: persistence, time: TimeSource(clock)))
        facade.engine = engine
        Retain.keep(facade)
        return engine
    }

    static func screens(_ request: RecordedRequest?) -> [String]? {
        let app = (request?.json?["device"] as? [String: Any])?["app"] as? [String: Any]
        return (app?["screens"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
    }

    @Test("Every session carries the screens; a refresh only when the list changed; nothing without a list")
    func sessionsCarryScreens() async throws {
        let persistence = MemoryPersistence()
        let secure = MemorySecureStore()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST sessions/refresh", .ok(Wire.refresh()))
        let facade = PingFront()
        facade.registerScreens([AppScreen(id: "settings.sound", title: "Sound settings"), AppScreen(id: "plans/yearly")])
        let first = try makeEngine(facade, persistence: persistence, secure: secure)
        _ = try await first.session.token(reason: .chatOpened)
        #expect(Self.screens(await server.requests("POST sessions").first) == ["settings.sound", "plans/yearly"])

        // The next launch refreshes: the same list on the same version is not sent again.
        let again = PingFront()
        again.registerScreens([AppScreen(id: "settings.sound", title: "Sound settings"), AppScreen(id: "plans/yearly")])
        _ = try await makeEngine(again, persistence: persistence, secure: secure).session.token(reason: .chatOpened)
        #expect(Self.screens(await server.requests("POST sessions/refresh").last) == nil)

        // A new list goes out with the next refresh.
        let changed = PingFront()
        changed.registerScreens([AppScreen(id: "settings.sound")])
        _ = try await makeEngine(changed, persistence: persistence, secure: secure).session.token(reason: .chatOpened)
        #expect(Self.screens(await server.requests("POST sessions/refresh").last) == ["settings.sound"])

        // A build that never registered screens sends no field.
        let none = PingFront()
        _ = try await makeEngine(none, persistence: MemoryPersistence(), secure: MemorySecureStore()).session.token(reason: .chatOpened)
        let app = ((await server.requests("POST sessions").last)?.json?["device"] as? [String: Any])?["app"] as? [String: Any]
        #expect(app?["screens"] == nil)
    }

    @Test("A changed list rides on a PATCH that goes anyway, and never makes one of its own")
    func patchCarriesScreens() async throws {
        let clock = TestClock()
        let log = PatchLog()
        let registry = ScreenRegistry()
        let reporter = ScreensReporter(registry: registry, persistence: MemoryPersistence())
        let coalescer = PatchCoalescer(time: TimeSource(clock), screens: reporter)
        await coalescer.setSender { patch async throws(PingFrontError) in
            await log.add(patch)
            return UpdateMeResponse(person: PersonSummary(id: "p", level: .guest, name: nil), identityProblem: nil)
        }
        await coalescer.markDeviceSent(DeviceInfo.current(installId: "inst_1"))
        await coalescer.activate()
        registry.register([AppScreen(id: "settings.sound")])
        // The list alone sends nothing.
        await coalescer.stage(.device(DeviceInfo.current(installId: "inst_1")))
        clock.advance(by: .seconds(1))
        await settle()
        #expect(await log.patches.isEmpty)
        // Something else goes out: the list rides on it, once.
        await coalescer.stage(.traits(["plan": "pro"]))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(250))
        #expect(await eventually { await log.patches.count == 1 })
        #expect(await log.patches.first?.device?.app.screens == [AppScreen(id: "settings.sound")])
        await coalescer.stage(.traits(["plan": "max"]))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(250))
        #expect(await eventually { await log.patches.count == 2 })
        #expect(await log.patches.last?.device?.app.screens == nil, "unchanged: not sent again")
    }

    // MARK: A tap

    func tap(_ card: LinkCard, facade: PingFront, engine: Engine) async throws -> [String: Any]? {
        await server.on("POST thread/cards/\(card.id)/act", .noContent)
        let before = await server.requests("POST thread/cards/\(card.id)/act").count
        engine.cards.act(card: .link(card), messageId: "msg_1", answer: nil, offers: [])
        #expect(await eventually { await server.requests("POST thread/cards/\(card.id)/act").count == before + 1 })
        try await Task.sleep(for: .milliseconds(50))
        let reports = await server.requests("POST thread/cards/\(card.id)/act")
        #expect(reports.count == before + 1, "one report per tap")
        return reports.last?.json
    }

    @Test("A tap reports opened, or failed with not_handled, unknown_screen or cannot_open")
    func tapOutcomes() async throws {
        let facade = PingFront()
        let engine = try makeEngine(facade, persistence: MemoryPersistence(), secure: MemorySecureStore())
        await server.on("POST sessions", .ok(Wire.session()))
        _ = try await engine.session.token(reason: .chatOpened)
        // Reports go out through the engine's queue.
        engine.startOutboxLoop()
        defer { engine.stopWrites() }
        let presenter = LinkPresenter()
        facade.registry.chatPresenter = presenter
        facade.registerScreens([AppScreen(id: "settings.sound")])
        let screenCard = LinkCard(
            id: "card_s", title: "Sounds", url: "https://example.com/help", button: "Open",
            screen: LinkScreen(id: "settings.sound", params: ["tab": "tones"]))

        // No handler: not handled.
        var report = try await tap(screenCard, facade: facade, engine: engine)
        #expect(report?["action"] as? String == "failed" && report?["failure"] as? String == "not_handled")
        // The handler opens it, with the params.
        var received: [LinkScreen] = []
        facade.onScreen = { screen in
            received.append(screen)
            return true
        }
        report = try await tap(screenCard, facade: facade, engine: engine)
        #expect(report?["action"] as? String == "opened" && report?["failure"] == nil)
        #expect(received == [LinkScreen(id: "settings.sound", params: ["tab": "tones"])])
        #expect(presenter.opened.isEmpty, "a handled screen never opens the URL")
        // The handler can't.
        facade.onScreen = { _ in false }
        report = try await tap(screenCard, facade: facade, engine: engine)
        #expect(report?["failure"] as? String == "not_handled")
        // An async handler (a bridge waiting for JavaScript or Dart): the report waits for its answer.
        facade.onScreen = { _ in
            await Task.yield()
            return true
        }
        report = try await tap(screenCard, facade: facade, engine: engine)
        #expect(report?["action"] as? String == "opened")

        // A screen this build didn't register: the URL instead, or unknown_screen without one.
        let other = LinkCard(
            id: "card_o", title: "Yearly", url: "https://example.com/yearly", button: "Open", screen: LinkScreen(id: "plans/yearly"))
        report = try await tap(other, facade: facade, engine: engine)
        #expect(report?["action"] as? String == "opened")
        #expect(presenter.opened.last == URL(string: "https://example.com/yearly"))
        let noFallback = LinkCard(id: "card_n", title: "Yearly", url: "", button: "Open", screen: LinkScreen(id: "plans/yearly"))
        report = try await tap(noFallback, facade: facade, engine: engine)
        #expect(report?["failure"] as? String == "unknown_screen")

        // A URL nothing opens.
        presenter.opens = false
        let web = LinkCard(id: "card_w", title: "Help", url: "myapp-missing://x", button: "Open")
        report = try await tap(web, facade: facade, engine: engine)
        #expect(report?["failure"] as? String == "cannot_open")
        // onLink takes it: opened.
        facade.onLink = { _ in true }
        report = try await tap(web, facade: facade, engine: engine)
        #expect(report?["action"] as? String == "opened")
    }

    @Test("An answer that doesn't come within 10 s counts as false; one that comes in time wins")
    func boundedWait() async throws {
        let clock = TestClock()
        let time = TimeSource(clock)
        let screen = LinkScreen(id: "settings.sound")
        // Never answers (a bridge whose JavaScript side is gone).
        let silent: @MainActor (LinkScreen) async -> Bool = { _ in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return true
        }
        let late = Task { await CardActions.answer(silent, screen, within: .seconds(10), time: time) }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(9))
        await settle()
        clock.advance(by: .seconds(1))
        #expect(await late.value == false)
        // Answers before the deadline: its answer, and the deadline is let go.
        let quick: @MainActor (LinkScreen) async -> Bool = { _ in true }
        #expect(await CardActions.answer(quick, screen, within: .seconds(10), time: time))
        #expect(await eventually { clock.sleeperCount == 0 })
    }

    // MARK: An async onLink (FL1)

    /// An `onLink` that never answers on its own (a bridge whose JavaScript or Dart side is slow or gone): it waits
    /// until it is cancelled, and counts that.
    @MainActor final class SilentLink {
        var asked: [URL] = []
        var cancelled = 0
        var handler: @MainActor (URL) async -> Bool {
            { [self] url in
                asked.append(url)
                try? await Task.sleep(for: .seconds(3600))
                if Task.isCancelled { cancelled += 1 }
                return true
            }
        }
    }

    @Test("An async onLink: true reports opened; declined, the default way opens it, and cannot_open when that fails too")
    func asyncOnLinkOutcomes() async throws {
        let facade = PingFront()
        let engine = try makeEngine(facade, persistence: MemoryPersistence(), secure: MemorySecureStore())
        await server.on("POST sessions", .ok(Wire.session()))
        _ = try await engine.session.token(reason: .chatOpened)
        engine.startOutboxLoop()
        defer { engine.stopWrites() }
        let presenter = LinkPresenter()
        facade.registry.chatPresenter = presenter
        let card = LinkCard(id: "card_a", title: "Help", url: "https://example.com/help", button: "Open")

        facade.onLink = { _ in
            await Task.yield()
            return true
        }
        var report = try await tap(card, facade: facade, engine: engine)
        #expect(report?["action"] as? String == "opened")
        #expect(presenter.opened.isEmpty, "handled: nothing else opens it")

        facade.onLink = { _ in
            await Task.yield()
            return false
        }
        report = try await tap(card, facade: facade, engine: engine)
        #expect(report?["action"] as? String == "opened", "declined: Safari opened it")
        #expect(presenter.opened == [URL(string: "https://example.com/help")!])

        // Declined, and the default way opens nothing either: the real outcome, never opened.
        presenter.opens = false
        report = try await tap(card, facade: facade, engine: engine)
        #expect(report?["action"] as? String == "failed" && report?["failure"] as? String == "cannot_open")
    }

    @Test("An onLink with no answer in 10 s on the injected clock counts as declined; it is cancelled and the link opens")
    func onLinkCap() async throws {
        let clock = TestClock()
        let time = TimeSource(clock)
        let facade = PingFront()
        // The engine's clock is the one a link in a message waits on.
        _ = try makeEngine(facade, persistence: MemoryPersistence(), secure: MemorySecureStore(), clock: clock)
        let presenter = LinkPresenter()
        facade.registry.chatPresenter = presenter
        let silent = SilentLink()
        facade.onLink = silent.handler
        let card = LinkCard(id: "card_s", title: "Help", url: "https://example.com/help", button: "Open")
        let tap = Task { await CardActions.open(card, facade: facade, time: time) }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(9))
        await settle()
        #expect(presenter.opened.isEmpty, "still waiting before the cap")
        clock.advance(by: .seconds(1))
        #expect(await tap.value == nil, "declined at the cap: Safari opened it")
        #expect(presenter.opened == [URL(string: "https://example.com/help")!])
        #expect(await eventually { await silent.cancelled == 1 }, "the handler still running at the deadline is cancelled")

        // The same cap for a link in a message, which then opens the default way.
        presenter.opened = []
        facade.openLink(URL(string: "https://example.com/text")!)
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(10))
        await facade.chatLinkTask?.value
        #expect(presenter.opened == [URL(string: "https://example.com/text")!])
        #expect(await eventually { await silent.cancelled == 2 })
    }

    @Test("A newer link in a message replaces one still waiting, which then opens nothing")
    func newerChatLinkWins() async throws {
        let facade = PingFront()
        let presenter = LinkPresenter()
        facade.registry.chatPresenter = presenter
        let silent = SilentLink()
        facade.onLink = silent.handler
        facade.openLink(URL(string: "https://example.com/a")!)
        let first = try #require(facade.chatLinkTask)
        #expect(await eventually { await silent.asked.count == 1 })
        facade.onLink = { _ in false }
        facade.openLink(URL(string: "https://example.com/b")!)
        await first.value
        await facade.chatLinkTask?.value
        #expect(presenter.opened == [URL(string: "https://example.com/b")!])
        #expect(await eventually { await silent.cancelled == 1 }, "the replaced handler is cancelled")
    }

    @Test("logout() cancels an onLink still deciding: no report, nothing opens")
    func logoutCancelsPendingLink() async throws {
        let facade = PingFront()
        let engine = try makeEngine(facade, persistence: MemoryPersistence(), secure: MemorySecureStore())
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST me/logout", .noContent)
        await server.on("POST thread/cards/card_l/act", .noContent)
        _ = try await engine.session.token(reason: .chatOpened)
        engine.start()
        defer { engine.stop() }
        let presenter = LinkPresenter()
        facade.registry.chatPresenter = presenter
        let silent = SilentLink()
        facade.onLink = silent.handler
        let card = LinkCard(id: "card_l", title: "Help", url: "https://example.com/help", button: "Open")
        engine.cards.act(card: .link(card), messageId: "msg_1", answer: nil, offers: [])
        facade.openLink(URL(string: "https://example.com/text")!)
        #expect(await eventually { await silent.asked.count == 2 })
        facade.logout()
        #expect(await eventually { await silent.cancelled == 2 }, "both waits are cancelled")
        #expect(facade.chatLinkTask == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(presenter.opened.isEmpty, "a cancelled wait never opens the link")
        #expect(await server.requests("POST thread/cards/card_l/act").isEmpty, "the tap belongs to the previous person")
    }

    @Test("A plain closure still works as onLink")
    func plainOnLink() {
        let facade = PingFront()
        facade.onLink = { url in url.scheme == "myapp" }
        #expect(facade.onLink != nil)
    }

    @Test("A plain closure still works as onScreen")
    func plainClosure() {
        let facade = PingFront()
        facade.onScreen = { screen in screen.id == "settings.sound" }
        #expect(facade.onScreen != nil)
    }
}
