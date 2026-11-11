import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// N10: a send the server refuses because the person can't send (blocked, app paused, verification required) closes the
/// policy at once, as on Android and the web; the next thread load that says the person can send reopens it.
@Suite("Send refusals close the policy")
@MainActor
struct PolicyRefusalTests {
    let server = StubServer()

    func makeEngine(persistence: MemoryPersistence = MemoryPersistence(), secure: MemorySecureStore = MemorySecureStore()) throws
        -> (PingFront, Engine)
    {
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

    static func thread(canSend: Bool) -> String {
        #"{"thread":{"id":"thr_1","status":"open","lastSeq":0,"readSeq":0,"unread":0},"messages":[],"hasOlder":false,"team":[],"policy":{"canSend":\#(canSend)}}"#
    }

    @Test(
        "A refusal closes the policy with its reason",
        arguments: [
            ("blocked", 403, SendPolicy.Reason.blocked),
            ("app_paused", 403, SendPolicy.Reason.appPaused),
            ("verification_required", 403, SendPolicy.Reason.verificationRequired),
        ])
    func refusalClosesThePolicy(code: String, status: Int, reason: SendPolicy.Reason) async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        let message = PendingMessage(text: "hello")
        await server.on("POST thread/messages", .json(status, Wire.error(code)))
        await engine.outbox.enqueue(message)
        #expect(facade.conversation.policy.canSend)
        _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        #expect(facade.conversation.policy == .closed(reason))
        #expect(await engine.outbox.all().first?.state == .failed)
    }

    @Test("Another failure leaves the policy open")
    func otherFailuresDoNot() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST thread/messages", .json(422, Wire.error("invalid_request")))
        await engine.outbox.enqueue(PendingMessage(text: "hello"))
        _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        #expect(facade.conversation.policy == .open)
    }

    @Test("The next thread load that allows sending reopens it")
    func threadLoadReopens() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST thread/messages", .json(403, Wire.error("blocked")))
        await server.on("GET thread", .ok(Self.thread(canSend: true)))
        await engine.outbox.enqueue(PendingMessage(text: "hello"))
        _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        #expect(facade.conversation.policy == .closed(.blocked))
        await engine.loadThread()
        #expect(facade.conversation.policy == .open)
    }

    @Test("While sending is closed, nothing promises a reply (header and welcome)")
    func noReplyPromiseWhileClosed() {
        #expect(HeaderStatus.expectation("Usually replies in a few hours", shown: true, policy: .open) == "Usually replies in a few hours")
        for reason in [SendPolicy.Reason.blocked, .appPaused, .verificationRequired] {
            #expect(HeaderStatus.expectation("Usually replies in a few hours", shown: true, policy: .closed(reason)) == nil)
        }
        #expect(HeaderStatus.expectation("Usually replies in a few hours", shown: false, policy: .open) == nil)
    }

    @Test("A refused session (the app paused) closes the policy too")
    func refusedSessionCloses() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .json(403, Wire.error("app_paused")))
        await engine.openThread()
        #expect(facade.conversation.policy == .closed(.appPaused))
    }

    @Test("A message the closed policy refused goes again by itself when sending reopens; the paused banner clears")
    func heldMessageGoesWhenReopened() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        let message = PendingMessage(text: "hello")
        await server.on("POST thread/messages", .json(403, Wire.error("app_paused")))
        await server.on("GET thread", .ok(Self.thread(canSend: true)))
        await engine.outbox.enqueue(message)
        _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        #expect(await engine.outbox.all().first?.state == .failed)
        facade.report(ConfigurationProblem(kind: .appPaused, message: "paused", disablesSDK: false))
        await engine.loadThread()
        #expect(facade.conversation.policy == .open)
        #expect(facade.configurationProblem == nil, "the paused banner is out of date")
        #expect(await eventually { await engine.outbox.all().first?.state == .queued })
    }

    @Test("A message held before a relaunch goes once the next load allows sending (B2)")
    func heldAcrossRelaunch() async throws {
        let persistence = MemoryPersistence()
        let secure = MemorySecureStore()
        do {
            let (_, engine) = try makeEngine(persistence: persistence, secure: secure)
            await server.on("POST sessions", .ok(Wire.session()))
            await server.on(
                "POST thread/messages", .json(403, Wire.error("app_paused")), .ok(Wire.message(clientId: "c-held")))
            await engine.outbox.enqueue(PendingMessage(clientId: "c-held", text: "held"))
            _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
            #expect(await engine.outbox.all().first?.state == .failed)
        }
        // The relaunched app: a new engine on the same storage, the policy open from the start.
        let (facade, engine) = try makeEngine(persistence: persistence, secure: secure)
        #expect(await engine.outbox.load().first?.clientId == "c-held")
        await server.on("GET thread", .ok(Self.thread(canSend: true)))
        await server.on("POST sessions/refresh", .ok(Wire.refresh()))
        #expect(facade.conversation.policy.canSend)
        await engine.loadThread()
        #expect(await eventually { await engine.outbox.all().first?.state == .queued })
        _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        #expect(await engine.outbox.all().isEmpty)
        #expect(await server.requests("POST thread/messages").count == 2, "refused once, delivered once")
    }
}
