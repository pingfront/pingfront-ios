import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// Behaviour fixes from the 31 Oct 2026 UI/UX audit of the chat.
@Suite("UI/UX audit fixes")
@MainActor
struct AuditFixTests {
    @Test("X-01: a topic never sends; Report a bug opens the report, presets fill the composer")
    func topics() {
        let translate: (String) -> String = { "«\($0)»" }
        #expect(TopicAction.resolve(id: "bug", prefill: nil, label: "Report a bug", translate: translate) == .openReport)
        #expect(
            TopicAction.resolve(id: "billing", prefill: nil, label: "Ask about billing", translate: translate)
                == .compose("«I have a question about billing: »"))
        #expect(
            TopicAction.resolve(id: "billing", prefill: "Refund my yearly plan", label: "x", translate: translate)
                == .compose("Refund my yearly plan"))
        #expect(TopicAction.resolve(id: "widgets", prefill: nil, label: "Widgets", translate: translate) == .compose("Widgets: "))
        #expect(TopicAction.resolve(id: "bug", prefill: "The alarm", label: "x", translate: translate) == .compose("The alarm"))
    }

    @Test("X-08: built-in topic labels share one grammar (what the person wants to do)")
    func topicGrammar() {
        let labels = TopicPreset.allCases.map(\.label)
        #expect(labels.allSatisfy { $0.split(separator: " ").count >= 2 }, "\(labels)")
    }

    @Test("X-02: the header status is two full sentences; a time never stands alone")
    func headerStatus() {
        let itsFor: (String, String) -> String = { "It's \($0) for \($1)" }
        #expect(
            HeaderStatus.text(expectation: "Usually replies in a few hours.", time: "11:20 PM", name: "Deniz", itsFor: itsFor)
                == "Usually replies in a few hours\nIt's 11:20 PM for Deniz")
        #expect(HeaderStatus.text(expectation: nil, time: "02:41", name: "Deniz", itsFor: itsFor) == "It's 02:41 for Deniz")
        #expect(HeaderStatus.text(expectation: nil, time: "02:41", name: nil, itsFor: itsFor) == nil)
        #expect(
            HeaderStatus.text(expectation: "Usually replies today", time: nil, name: "Deniz", itsFor: itsFor) == "Usually replies today")
    }

    @Test("I-04: App Store review links open the App Store app's review page")
    func reviewLink() throws {
        let web = try #require(URL(string: "https://apps.apple.com/app/clockwise/id6450000000"))
        #expect(ReviewLink.writeReview(web).absoluteString == "itms-apps://apps.apple.com/app/clockwise/id6450000000?action=write-review")
        let other = try #require(URL(string: "https://clockwise.app/review"))
        #expect(ReviewLink.writeReview(other) == other)
    }

    final class Requester: ReviewRequesting {
        var asked = 0
        func requestReview() async -> Bool {
            asked += 1
            return true
        }
    }

    final class Presenter: ChatPresenting {
        var opened: [URL] = []
        func presentChat(topic: ChatTopic?) {}
        func dismissChat() {}
        func open(_ url: URL) { opened.append(url) }
        func presentSimpleReport() {}
    }

    @Test("I-04: the first tap asks Apple's prompt; a second tap opens the write-a-review page")
    func reviewSecondTap() async throws {
        let facade = PingFront()
        let requester = Requester()
        let presenter = Presenter()
        facade.registry.reviewRequester = requester
        facade.registry.chatPresenter = presenter
        let cards = CardActions(
            facade: facade,
            client: AuthorizedClient(
                api: APIClient(
                    baseURL: StubTransport.base, appKey: "k", transport: StubTransport(), cooldowns: CooldownBook(time: .continuous)),
                authenticator: FixedToken(
                    APIClient(
                        baseURL: StubTransport.base, appKey: "k", transport: StubTransport(), cooldowns: CooldownBook(time: .continuous)))),
            time: .continuous, reports: CardActionReports(persistence: MemoryPersistence()), wake: WakeSignal())
        let card = Card.review(
            ReviewCard(id: "r1", mode: .nativePrompt, storeURL: URL(string: "https://apps.apple.com/app/id1"), button: "Rate"))
        cards.act(card: card, messageId: "m", answer: nil, offers: [])
        #expect(await eventually { @MainActor in requester.asked == 1 })
        #expect(presenter.opened.isEmpty)
        cards.act(card: card, messageId: "m", answer: nil, offers: [])
        #expect(await eventually { @MainActor in presenter.opened.first?.scheme == "itms-apps" })
        #expect(requester.asked == 1)
    }

    @Test("I-05: without onOffer or a store module, offers report they cannot be shown")
    func offerHandler() {
        let facade = PingFront()
        #expect(!facade.canHandleOffers)
        facade.onOffer = { _ in }
        #expect(facade.canHandleOffers)
    }

    @Test("I-06: a Keychain that refuses the install raises a setup problem and fails the self-check")
    func keychainProblem() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse("pk_test_abcdefghijklmnopqrstuvvd").get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(server: server), secure: RefusingSecureStore(), persistence: MemoryPersistence(),
                time: TimeSource(TestClock())))
        facade.engine = engine
        Retain.keep(facade)
        engine.start()
        defer { engine.stop() }
        try await facade.prepare()
        #expect(await eventually { @MainActor in facade.configurationProblem?.kind == .keychain })
    }

    @Test("I-10: an offline preview never shows the cached thread")
    func previewIgnoresCache() async throws {
        let disk = MemoryPersistence()
        let cache = ThreadCache(persistence: disk)
        await cache.save(CachedThread(messages: [makeMessage("real", seq: 1)], team: [], hasOlder: false))
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse("pk_test_abcdefghijklmnopqrstuvvd").get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(), secure: MemorySecureStore(), persistence: disk, time: TimeSource(TestClock())))
        facade.engine = engine
        Retain.keep(facade)
        engine.preview = true
        engine.start()
        defer { engine.stop() }
        await settle()
        #expect(!facade.conversation.messages.contains { $0.id == "real" })
    }

    @Test(
        "An offline preview keeps a store change on the device: the card sees it, no PATCH goes out",
        arguments: [true, false])
    func previewSendsNoEntitlement(preview: Bool) async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("PATCH me", .ok(#"{"person":{"id":"p_1","level":"guest"}}"#))
        let facade = PingFront()
        let clock = TestClock()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(clock))
        facade.start(appKey: "pk_test_abcdefghijklmnopqrstuvvd", configuration: configuration)
        Retain.keep(facade)
        defer { facade.teardown() }
        try await facade.prepare()
        facade.engine?.preview = preview
        facade.setEntitlement(Entitlement(state: .active, productId: "pro_yearly", source: .storekit))
        var sent = false
        for _ in 0..<50 where !sent {
            clock.advance(by: Timing.patchWindow)
            await settle()
            sent = await server.requests("PATCH me").contains { $0.bodyString.contains("pro_yearly") }
        }
        #expect(facade.owns(anyOf: ["pro_yearly"]))
        // The control run (no preview) proves the PATCH would have gone out.
        #expect(sent == !preview)
    }
}

/// A Keychain that answers reads but refuses writes (an unsigned build).
actor RefusingSecureStore: SecureStore {
    func read(_ key: String) throws(StorageError) -> Data? { nil }
    func write(_ key: String, _ data: Data?) throws(StorageError) { if data != nil { throw .failed("keychain add -34018") } }
}
