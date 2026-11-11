import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// The outbox delivers strictly in order.
///
/// A message held by a closed policy (the app paused, verification required) keeps the messages behind it waiting, and
/// only the drain decides what goes next. A blocked person's message is not held: it fails plainly, with nothing
/// promised.
@Suite("Outbox order and held messages")
@MainActor
struct OutboxOrderTests {
    let server = StubServer()

    func makeEngine(persistence: MemoryPersistence, secure: MemorySecureStore) throws -> (PingFront, Engine) {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse("pk_test_abcdefghijklmnopqrstuvvd").get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(server: server), secure: secure, persistence: persistence,
                time: TimeSource(TestClock())))
        facade.engine = engine
        Retain.keep(facade)
        return (facade, engine)
    }

    func sentOrder() async -> [String] {
        await server.requests("POST thread/messages").compactMap { $0.json?["clientId"] as? String }
    }

    @Test("A held message goes before a newer one sent after a relaunch (audit 2, blocker)")
    func heldGoesFirst() async throws {
        let persistence = MemoryPersistence()
        let secure = MemorySecureStore()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST sessions/refresh", .ok(Wire.refresh()))
        await server.on(
            "POST thread/messages", .json(403, Wire.error("app_paused")), .ok(Wire.message(id: "msg_c", clientId: "c")),
            .ok(Wire.message(id: "msg_d", seq: 2, clientId: "d")))
        do {
            let (_, engine) = try makeEngine(persistence: persistence, secure: secure)
            await engine.outbox.enqueue(PendingMessage(clientId: "c", text: "C"))
            _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
            #expect(await engine.outbox.all().first?.isHeld == true)
        }
        // Relaunched: the service is out of reach, so nothing has reopened sending yet when the person sends D.
        let (_, engine) = try makeEngine(persistence: persistence, secure: secure)
        await engine.outbox.load()
        await engine.outbox.enqueue(PendingMessage(clientId: "d", text: "D"))
        _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        #expect(await sentOrder() == ["c"], "D waits behind the held C")
        #expect(await engine.outbox.all().map(\.clientId) == ["c", "d"])

        // The service answers and sending is open: the drain may run before or after the re-queue; C still goes first.
        await server.on("GET thread", .ok(PolicyRefusalTests.thread(canSend: true)))
        await engine.loadThread()
        _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        let outbox = engine.outbox
        #expect(await eventually { await outbox.all().first.map { $0.state == .queued } ?? true })
        _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        #expect(await engine.outbox.all().isEmpty)
        #expect(await sentOrder() == ["c", "c", "d"], "refused once, then C, then D")
    }

    @Test("A blocked person's message fails plainly, and the ones behind it too")
    func blockedIsNotHeld() async throws {
        let (facade, engine) = try makeEngine(persistence: MemoryPersistence(), secure: MemorySecureStore())
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST thread/messages", .json(403, Wire.error("blocked")))
        await engine.outbox.enqueue(PendingMessage(clientId: "a", text: "A"))
        await engine.outbox.enqueue(PendingMessage(clientId: "b", text: "B"))
        _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        #expect(facade.conversation.policy == .closed(.blocked))
        let items = await engine.outbox.all()
        #expect(items.map(\.state) == [.failed, .failed])
        #expect(items.allSatisfy { $0.isHeld != true }, "nothing is promised to a blocked person")
        #expect(await sentOrder() == ["a"], "B would be refused too, so it is not sent")
    }

    @Test("Held messages stop being held when the policy turns to blocked")
    func blockedDropsHeld() async throws {
        let (facade, engine) = try makeEngine(persistence: MemoryPersistence(), secure: MemorySecureStore())
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST thread/messages", .json(403, Wire.error("app_paused")))
        await engine.outbox.enqueue(PendingMessage(clientId: "a", text: "A"))
        _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        #expect(await engine.outbox.all().first?.isHeld == true)
        await server.on(
            "GET thread",
            .ok(
                #"{"thread":{"id":"thr_1","status":"open","lastSeq":0,"readSeq":0,"unread":0},"messages":[],"hasOlder":false,"team":[],"policy":{"canSend":false,"reason":"blocked"}}"#
            ))
        await engine.loadThread()
        #expect(facade.conversation.policy == .closed(.blocked))
        #expect(await eventually { await engine.outbox.all().first?.isHeld == false })
        #expect(await engine.outbox.all().first?.state == .failed)
    }

    @Test(
        "Only a pause or a verification holds a message",
        arguments: [
            ("app_paused", true), ("verification_required", true), ("blocked", false),
        ])
    func whatHolds(code: String, holds: Bool) {
        let reason = SendPolicy.Reason(refusal: ErrorCode(rawValue: code))
        #expect(reason?.holdsMessages == holds)
    }
}
