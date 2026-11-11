import Foundation
import Testing
import os

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

@Suite("Event stream and log handler")
@MainActor
struct EventStreamTests {
    let key = "pk_test_abcdefghijklmnopqrstuvvd"

    func configured(_ server: StubServer) -> PingFront {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(TestClock()))
        facade.start(appKey: key, configuration: configuration)
        Retain.keep(facade)
        return facade
    }

    @Test("messageSent fires once the server accepts the person's message, without its text")
    func messageSent() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST thread/messages", .ok(Wire.message(id: "msg_9", clientId: "c1", text: "Hello there")))
        let facade = configured(server)
        defer { facade.teardown() }
        let events = facade.events
        facade.conversation.send(text: "Hello there")
        var sent: SentMessage?
        for await event in events {
            if case .messageSent(let message) = event {
                sent = message
                break
            }
        }
        #expect(sent == SentMessage(id: "msg_9", textLength: 11, photoCount: 0, repliesToPing: false))
    }

    @Test("cardOpened carries the card kind, for taps and for answers; unknown cards emit nothing")
    func cardOpened() async throws {
        let facade = PingFront()
        let api = APIClient(
            baseURL: StubTransport.base, appKey: "k", transport: StubTransport(), cooldowns: CooldownBook(time: .continuous))
        let cards = CardActions(
            facade: facade, client: AuthorizedClient(api: api, authenticator: FixedToken(api)), time: TimeSource(TestClock()),
            reports: CardActionReports(persistence: MemoryPersistence()), wake: WakeSignal())
        let events = facade.events
        cards.act(card: .unknown(kind: "poll", id: "u1"), messageId: "m0", answer: nil, offers: [])
        cards.act(
            card: .link(LinkCard(id: "l1", title: "Docs", url: "https://example.com", button: "Open")), messageId: "m1", answer: nil,
            offers: [])
        cards.report(card: .link(LinkCard(id: "l2", title: "Docs", url: "https://example.com", button: "Open")), messageId: "m2")
        var seen: [OpenedCard] = []
        for await event in events {
            if case .cardOpened(let card) = event { seen.append(card) }
            if seen.count == 2 { break }
        }
        #expect(seen == [OpenedCard(kind: .link, cardId: "l1", messageId: "m1"), OpenedCard(kind: .link, cardId: "l2", messageId: "m2")])
        #expect(Card.unknown(kind: "poll", id: nil).kind.rawValue == "poll")
        #expect(Card.report(ReportCard(id: "r", title: "Report", button: "Report")).kind == .report)
    }

    @Test("Log lines are redacted once: private values never reach the handler")
    func redaction() {
        let email = "ana@example.com"
        let status = 503
        let message: LogMessage =
            "Request failed \(status) for \(email) code \("rate_limited", privacy: .public) \(email, privacy: .private)"
        #expect(message.rendered == "Request failed 503 for <private> code rate_limited <private>")
    }

    @Test("The handler receives lines at or above the level, with their category")
    func handler() {
        let seen = OSAllocatedUnfairLock<[PingFrontLogEntry]>(initialState: [])
        let logger = Logger(subsystem: Log.subsystem, category: "test")
        let sdk = SDKLogger(category: .session, logger: logger, handler: { entry in seen.withLock { $0.append(entry) } })
        sdk.error("Session failed: \(401)")
        sdk.notice("Started \("person_1")")
        #expect(
            seen.withLock { $0 } == [
                PingFrontLogEntry(level: .error, category: "session", message: "Session failed: 401"),
                PingFrontLogEntry(level: .info, category: "session", message: "Started <private>"),
            ])
    }

    @Test("configure installs the handler and level; .off hands out no logger")
    func configureInstallsHandler() {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.logHandler = { _ in }
        configuration.logLevel = .error
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: StubServer()), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(TestClock()))
        facade.start(appKey: key, configuration: configuration)
        defer { facade.teardown() }
        #expect(Log.handler != nil)
        #expect(Log.network(.debug) == nil)
        #expect(Log.network(.error) != nil)
        #expect(Log.network(.off) == nil)
    }
}
