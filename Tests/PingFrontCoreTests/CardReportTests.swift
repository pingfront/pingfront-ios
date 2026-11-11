import Foundation
import Testing
import os

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// Records the reports a drain tried, and answers with a script.
actor ReportLog {
    private(set) var sent: [CardActionReports.Item] = []
    private var answers: [PingFrontError?]
    init(_ answers: [PingFrontError?]) { self.answers = answers }
    func next(_ item: CardActionReports.Item) -> PingFrontError? {
        sent.append(item)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

/// Card action reports are queued, retried safely with one `clientId` each, kept across launches and cleared on logout
/// (the protocol's rules for retrying writes; card K2).
@Suite("Card action reports", .serialized)
@MainActor
struct CardReportTests {
    static func server(_ status: Int, _ code: String) -> PingFrontError {
        .server(ServerError(status: status, code: ErrorCode(rawValue: code), message: code))
    }

    static func send(_ log: ReportLog) -> CardActionReports.Send {
        { item async throws(PingFrontError) in
            if let error = await log.next(item) { throw error }
        }
    }

    let tap = CardActionRequest(messageId: "msg_1", action: .opened)

    @Test("No answer, 408, 429, 500, 502, 503 and 504 are retried with the same clientId and body; success empties it")
    func retriesWithOneClientId() async {
        let reports = CardActionReports(persistence: MemoryPersistence())
        await reports.enqueue(cardId: "card_1", tap)
        let log = ReportLog([
            .network(.timedOut), .network(.networkConnectionLost), Self.server(408, "timeout"),
            .coolingDown(scope: .messages, remaining: .seconds(5)), Self.server(500, "internal"), Self.server(502, "bad_gateway"),
            Self.server(503, "unavailable"), Self.server(504, "gateway_timeout"), nil,
        ])
        var rounds = 0
        while await reports.drain(Self.send(log), stillThere: { _ in false }) != .idle { rounds += 1 }
        #expect(rounds == 8)
        let sent = await log.sent
        #expect(sent.count == 9)
        #expect(Set(sent.map(\.clientId)).count == 1, "one clientId across every retry")
        #expect(sent.allSatisfy { $0.request.messageId == "msg_1" && $0.request.action == .opened })
        #expect(await reports.all().isEmpty)
    }

    @Test("Each new report gets its own clientId")
    func newTapNewId() async {
        let reports = CardActionReports(persistence: MemoryPersistence())
        await reports.enqueue(cardId: "card_1", tap)
        await reports.enqueue(cardId: "card_1", tap)
        let ids = await reports.all().map(\.clientId)
        #expect(ids.count == 2 && Set(ids).count == 2 && ids.allSatisfy { UUID(uuidString: $0) != nil })
    }

    @Test("Any other 4xx, and a 401 the client couldn't fix, drop the report")
    func dropsOtherErrors() async {
        for error in [
            Self.server(400, "invalid_request"), Self.server(401, "unauthorized"), Self.server(404, "not_found"),
            Self.server(422, "invalid_request"),
        ] {
            let reports = CardActionReports(persistence: MemoryPersistence())
            await reports.enqueue(cardId: "card_1", tap)
            let log = ReportLog([error])
            #expect(await reports.drain(Self.send(log), stillThere: { _ in true }) == .idle)
            #expect(await reports.all().isEmpty, "\(error)")
            #expect(await log.sent.count == 1)
        }
    }

    @Test("409 thread_reset: retried once when the message is still there, dropped when it is gone")
    func threadReset() async {
        let kept = CardActionReports(persistence: MemoryPersistence())
        await kept.enqueue(cardId: "card_1", tap)
        let keptLog = ReportLog([Self.server(409, "thread_reset"), Self.server(409, "thread_reset")])
        _ = await kept.drain(Self.send(keptLog), stillThere: { _ in true })
        #expect(await keptLog.sent.count == 2, "one retry, then dropped")
        #expect(await kept.all().isEmpty)

        let gone = CardActionReports(persistence: MemoryPersistence())
        await gone.enqueue(cardId: "card_1", tap)
        let goneLog = ReportLog([Self.server(409, "thread_reset")])
        _ = await gone.drain(Self.send(goneLog), stillThere: { _ in false })
        #expect(await goneLog.sent.count == 1)
        #expect(await gone.all().isEmpty)
    }

    @Test("A report is dropped after 24 hours or 10 attempts")
    func limits() async {
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
        let reports = CardActionReports(persistence: MemoryPersistence(), now: { clock.withLock { $0 } })
        await reports.enqueue(cardId: "card_1", tap)
        clock.withLock { $0 = $0.addingTimeInterval(25 * 60 * 60) }
        let log = ReportLog([])
        _ = await reports.drain(Self.send(log), stillThere: { _ in false })
        #expect(await log.sent.isEmpty, "too old: never sent")
        #expect(await reports.all().isEmpty)

        let busy = CardActionReports(persistence: MemoryPersistence())
        await busy.enqueue(cardId: "card_1", tap)
        let failing = ReportLog(Array(repeating: .network(.timedOut), count: 20))
        while await busy.drain(Self.send(failing), stillThere: { _ in false }) != .idle {}
        #expect(await failing.sent.count == 10)
        #expect(await busy.all().isEmpty)
    }

    @Test("Queued reports survive a relaunch, with their clientId and attempts")
    func persists() async {
        let persistence = MemoryPersistence()
        do {
            let reports = CardActionReports(persistence: persistence)
            await reports.enqueue(cardId: "card_1", tap)
            _ = await reports.drain(Self.send(ReportLog([.network(.notConnectedToInternet)])), stillThere: { _ in false })
        }
        let before = await CardActionReports(persistence: persistence).all()
        #expect(before.count == 1 && before.first?.attempts == 1)
        let relaunched = CardActionReports(persistence: persistence)
        let log = ReportLog([nil])
        _ = await relaunched.drain(Self.send(log), stillThere: { _ in false })
        #expect(await log.sent.map(\.clientId) == before.map(\.clientId))
        #expect(await relaunched.all().isEmpty)
    }

    // MARK: Through the engine

    let server = StubServer()

    func makeEngine(persistence: MemoryPersistence = MemoryPersistence()) throws -> (PingFront, Engine) {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse("pk_test_abcdefghijklmnopqrstuvvd").get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: persistence,
                time: TimeSource(TestClock())))
        facade.engine = engine
        Retain.keep(facade)
        return (facade, engine)
    }

    @Test("A tap is queued and sent with a clientId; a 503 is retried at once on foreground, with the same id")
    func engineRetriesOnForeground() async throws {
        let (_, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST thread/cards/card_c/act", .json(503, Wire.error("unavailable")), .noContent)
        _ = try await engine.session.token(reason: .chatOpened)
        engine.startOutboxLoop()
        defer { engine.stopWrites() }
        engine.cards.act(
            card: .choices(ChoicesCard(id: "card_c", options: [.init(id: "a", label: "A")])), messageId: "msg_1",
            answer: .choice(id: "a"), offers: [])
        #expect(await eventually { await server.requests("POST thread/cards/card_c/act").count == 1 })
        engine.lifecycle(.foreground)
        #expect(await eventually { await server.requests("POST thread/cards/card_c/act").count == 2 })
        let bodies = await server.requests("POST thread/cards/card_c/act").map(\.json)
        let ids = bodies.compactMap { $0?["clientId"] as? String }
        #expect(ids.count == 2 && ids[0] == ids[1])
        #expect(bodies.last??["choiceId"] as? String == "a")
        #expect(await eventually { await engine.cardReports.all().isEmpty })
    }

    @Test("logout() clears the queue")
    func logoutClears() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST me/logout", .noContent)
        await engine.cardReports.enqueue(cardId: "card_1", tap)
        engine.start()
        defer { engine.stop() }
        facade.logout()
        #expect(await eventually { await engine.cardReports.all().isEmpty })
    }

    @Test("A link card with a javascript:, data:, vbscript:, file: or blob: URL never opens and reports cannot_open")
    func refusesSchemes() async throws {
        let facade = PingFront()
        let presenter = LinkPresenter()
        facade.registry.chatPresenter = presenter
        var opened: [URL] = []
        facade.onLink = { url in
            opened.append(url)
            return true
        }
        for url in [
            "javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,hi", "vbscript:msgbox", "file:///etc/hosts",
            "blob:https://x.dev/1",
        ] {
            let failure = await CardActions.open(
                LinkCard(id: "c", title: "t", url: url, button: "b"), facade: facade, time: TimeSource(TestClock()))
            #expect(failure == .cannotOpen, "\(url)")
        }
        #expect(opened.isEmpty && presenter.opened.isEmpty)
    }
}
