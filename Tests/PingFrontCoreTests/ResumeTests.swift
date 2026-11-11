import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// Learning that the app was resumed: an open chat reads its thread once per foreground while paused (or after a failed
/// load); an unread answer sends what a pause held, even from before a relaunch; deleting a held message lets the
/// queue behind it move.
@Suite("Resume after a pause")
@MainActor
struct ResumeTests {
    let server = StubServer()

    func makeEngine(persistence: MemoryPersistence = MemoryPersistence(), secure: MemorySecureStore = MemorySecureStore())
        throws -> (PingFront, Engine)
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

    static let unread = #"{"unread":0,"lastSeq":0,"live":false}"#

    static func held(_ clientId: String, _ reason: SendPolicy.Reason) -> PendingMessage {
        var message = PendingMessage(clientId: clientId, text: clientId)
        message.state = .failed
        message.failure = reason.rawValue
        message.heldFor = reason
        return message
    }

    @Test("An open chat that is paused reads the thread once per foreground and learns the app was resumed")
    func openChatLearnsResume() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET thread", .ok(PolicyRefusalTests.thread(canSend: true)))
        _ = try await engine.session.token(reason: .chatOpened)
        engine.closePolicy(.appPaused)
        facade.isChatVisible = true
        engine.lifecycle(.foreground)
        #expect(await eventually { @MainActor in facade.conversation.policy == .open })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.requests("GET thread").count == 1, "one read, no loop")
    }

    @Test("An open chat whose thread load failed reads it again once on the next foreground")
    func failedLoadRetriesOnForeground() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET thread", .json(500, Wire.error("internal")), .ok(PolicyRefusalTests.thread(canSend: true)))
        _ = try await engine.session.token(reason: .chatOpened)
        facade.isChatVisible = true
        await engine.loadThread()
        #expect(engine.threadLoadFailed)
        engine.lifecycle(.foreground)
        #expect(await eventually { @MainActor in !engine.threadLoadFailed })
        engine.lifecycle(.foreground)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.requests("GET thread").count == 2, "a loaded thread is not read again on foreground")
    }

    @Test("A message a pause held before a relaunch goes after an unread answer, without the chat; a sign-in hold waits")
    func heldBeforeRelaunchGoesOnUnread() async throws {
        let persistence = MemoryPersistence()
        let secure = MemorySecureStore()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST sessions/refresh", .ok(Wire.refresh()))
        do {
            let (_, engine) = try makeEngine(persistence: persistence, secure: secure)
            _ = try await engine.session.token(reason: .chatOpened)
            await engine.outbox.enqueue(Self.held("paused", .appPaused))
            await engine.outbox.enqueue(Self.held("signin", .verificationRequired))
        }
        // Relaunched: the policy is open in this process, which never saw the pause.
        let (facade, engine) = try makeEngine(persistence: persistence, secure: secure)
        #expect(await engine.outbox.load().map(\.heldFor) == [.appPaused, .verificationRequired], "the reason survives")
        await server.on("GET unread", .ok(Self.unread))
        await engine.unread.refresh()
        let outbox = engine.outbox
        #expect(await eventually { await outbox.all().first?.state == .queued })
        #expect(await outbox.all().last?.heldFor == .verificationRequired, "a sign-in hold waits for a load that allows sending")
        #expect(!facade.isChatVisible)
    }

    @Test("Deleting a held message wakes the queue: the one behind it goes")
    func discardWakesTheQueue() async throws {
        let (_, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST thread/messages", .ok(Wire.message(clientId: "next")))
        _ = try await engine.session.token(reason: .chatOpened)
        await engine.outbox.enqueue(Self.held("held", .appPaused))
        await engine.outbox.enqueue(PendingMessage(clientId: "next", text: "next"))
        engine.startOutboxLoop()
        engine.outboxWake.notify()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.requests("POST thread/messages").isEmpty, "the held head keeps the queue waiting")
        engine.discard("held")
        #expect(await eventually { await server.requests("POST thread/messages").count == 1 })
        #expect(await eventually { await engine.outbox.all().isEmpty })
    }

    @Test("After a sign-in is accepted, a message held for it goes with the chat closed; refused again, it is held again")
    func signInReleasesTheHold() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on(
            "POST thread/messages", .json(403, Wire.error("verification_required")), .ok(Wire.message(clientId: "signin")))
        _ = try await engine.session.token(reason: .chatOpened)
        await engine.outbox.enqueue(Self.held("signin", .verificationRequired))
        await engine.outbox.enqueue(Self.held("paused", .appPaused))
        engine.startOutboxLoop()
        // A PATCH that leaves the person a guest releases nothing.
        engine.patched(UpdateMeResponse(person: PersonSummary(id: "per_1", level: .named, name: "Ada")))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.requests("POST thread/messages").isEmpty)
        // Verified: the sign-in hold goes (refused once more, then held again); the pause hold waits for its own answer.
        engine.patched(UpdateMeResponse(person: PersonSummary(id: "per_1", level: .verified, name: "Ada")))
        let outbox = engine.outbox
        #expect(await eventually { await server.requests("POST thread/messages").count == 1 })
        #expect(await eventually { await outbox.all().first?.heldFor == .verificationRequired }, "refused again, held again")
        #expect(await outbox.all().last?.heldFor == .appPaused)
        #expect(!facade.isChatVisible)
        // Accepted the next time: it is delivered.
        engine.patched(UpdateMeResponse(person: PersonSummary(id: "per_1", level: .verified, name: "Ada")))
        #expect(await eventually { await outbox.all().map(\.clientId) == ["paused"] })
    }
}
