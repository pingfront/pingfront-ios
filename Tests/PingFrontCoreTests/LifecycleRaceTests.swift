import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// The verified-user switch (both wire paths) and the Android review's findings 1–3, proven on iOS for
/// every path: the outbox survives a session change mid-delivery, nothing in flight at logout writes the
/// previous person back, and nothing re-registers the person while an erase is in flight.
@Suite("Identity switch and lifecycle races")
@MainActor
struct LifecycleRaceTests {
    static let key = "pk_test_abcdefghijklmnopqrstuvvd"
    let clock = TestClock()

    func makeEngine(_ transport: any Transport) throws -> (PingFront, Engine) {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse(Self.key).get(), configuration: configuration,
            dependencies: Dependencies(
                transport: transport, secure: MemorySecureStore(), persistence: MemoryPersistence(), time: TimeSource(clock)))
        facade.engine = engine
        Retain.keep(facade)
        return (facade, engine)
    }

    /// Moves the injected clock in 250 ms steps until `condition` holds (other loops sleep on it too).
    func advanceUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            clock.advance(by: Timing.patchWindow)
            await settle()
        }
        return await condition()
    }

    static let threadJSON =
        #"{"thread":{"id":"thr_1","status":"open","lastSeq":2,"readSeq":0,"teamReadSeq":0,"unread":2,"rev":1},"messages":[\#(EngineTests.messageJSON(1)),\#(EngineTests.messageJSON(2))],"hasOlder":false,"team":[],"policy":{"canSend":true}}"#

    // MARK: Verified user switch

    @Test("PATCH /me rejected identity_user_mismatch: identity dropped, never resent, reported, self-check fails")
    func patchRejectsIdentity() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on(
            "PATCH me",
            .ok(
                #"{"person":{"id":"per_1","level":"guest"},"rejected":[{"field":"identity","code":"identity_user_mismatch","message":"x"}]}"#
            ),
            .ok(#"{"person":{"id":"per_1","level":"guest"},"rejected":[]}"#))
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        engine.start()
        defer { engine.stop() }
        try await facade.prepare()
        facade.identify(userId: "user-b", name: "Bea")
        #expect(await advanceUntil { await server.requests("PATCH me").count == 1 })
        #expect(await eventually { @MainActor in facade.lastIdentityProblem == .userMismatch })
        #expect(await engine.coalescer.stagedProfile().identity == nil)
        facade.setTraits(["plan": "pro"])
        #expect(await advanceUntil { await server.requests("PATCH me").count == 2 })
        #expect(await server.requests("PATCH me").last?.json?["identity"] == nil, "the refused identity was sent again")
        #expect(SetupCheck.result(forIdentity: .userMismatch).line.hasPrefix("PingFront self-check: FAIL identity_user_mismatch:"))
    }

    @Test("POST /sessions 409 identity_user_mismatch: identity dropped, session continues without it, reported")
    func createRejectsIdentity() async throws {
        let server = StubServer()
        await server.on("POST sessions", .json(409, Wire.error("identity_user_mismatch")), .ok(Wire.session()))
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        engine.start()
        defer { engine.stop() }
        facade.identify(userId: "user-b", name: "Bea")
        await settle()
        try await facade.prepare()
        let creates = await server.requests("POST sessions")
        #expect(creates.count == 2)
        #expect(creates[0].json?["identity"] != nil)
        #expect(creates[1].json?["identity"] == nil)
        #expect(await eventually { @MainActor in facade.lastIdentityProblem == .userMismatch })
        #expect(await engine.coalescer.stagedProfile().identity == nil)
        #expect(
            SetupCheck.describe(
                .server(ServerError(status: 409, code: .identityUserMismatch, message: "m", docs: nil, retryAfter: nil, scope: nil))
            ).0 == "identity_user_mismatch")
        // The check's line is logged: a code the check doesn't name gets our advice, never the server's text.
        let other = SetupCheck.describe(
            .server(
                ServerError(
                    status: 409, code: ErrorCode(rawValue: "conflict"), message: "ada@example.com", docs: nil, retryAfter: nil, scope: nil))
        )
        #expect(other.0 == "conflict")
        #expect(!other.1.contains("ada@example.com"))
        let unexpected = SetupCheck.describe(.invalidResponse("body was {\"email\":\"ada@example.com\"}"))
        #expect(unexpected.0 == "unexpected")
        #expect(!unexpected.1.contains("ada@example.com"))
    }

    // MARK: Android finding 1: the outbox survives a session change during delivery

    @Test("A session change while a send waits for its token keeps the outbox loop alive; the message sends later")
    func outboxSurvivesSessionChange() async throws {
        let gate = Gate()
        let (_, engine) = try makeEngine(GatedTransport(gate: gate))
        engine.start()
        defer { engine.stop() }
        engine.send(text: "still mine", photos: [], replyTo: nil)
        #expect(await eventually { await gate.count("POST sessions") == 1 })
        await engine.session.wipe()  // the session changes while the delivery waits for its token
        await gate.release(0, 200, Wire.session())
        #expect(await eventually { await engine.outbox.all().first?.state == .queued })
        // The next session (any token request) wakes the outbox; the loop must still be there to send.
        let next = Task { try await engine.session.token(reason: .prepare) }
        #expect(await eventually { await gate.count("POST sessions") == 2 })
        await gate.release(1, 200, Wire.session(token: "tok_2"))
        _ = try await next.value
        #expect(await eventually { await gate.count("POST thread/messages") == 1 }, "the outbox loop died")
        let clientId = try #require(await engine.outbox.all().first?.clientId)
        await gate.release(2, 200, Wire.message(id: "srv_1", seq: 1, clientId: clientId, text: "still mine"))
        #expect(await eventually { await engine.outbox.all().isEmpty })
    }

    // MARK: Android finding 2: nothing in flight at logout writes the previous person back

    @Test("A thread load, unread check and read receipt that finish after logout are dropped (memory and disk)")
    func inFlightReadsAfterLogout() async throws {
        let gate = Gate()
        let (facade, engine) = try makeEngine(
            GatedTransport(gate: gate, auto: ["POST sessions": (200, Wire.session()), "POST me/logout": (204, "")]))
        engine.start()
        defer { engine.stop() }
        try await facade.prepare()
        let load = Task { await engine.loadThread() }
        let poll = Task { await engine.unread.refresh() }
        #expect(await eventually { await gate.count("GET thread") == 1 })
        #expect(await eventually { await gate.count("GET unread") == 1 })
        await engine.performLogout()
        // Release by route (the two requests may have arrived in either order).
        let log = await gate.log
        for (index, request) in log.enumerated() {
            if request.path == "thread" { await gate.release(index, 200, Self.threadJSON) }
            if request.path == "unread" { await gate.release(index, 200, #"{"unread":5,"lastSeq":2,"live":false}"#) }
        }
        await load.value
        await poll.value
        #expect(facade.conversation.messages.isEmpty, "the previous person's thread came back")
        #expect(facade.unreadCount == 0)
        #expect(await engine.threadCache.load() == nil, "the previous person's thread was cached to disk")
    }

    @Test("A PATCH /me that finishes after logout does not restore the person")
    func inFlightPatchAfterLogout() async throws {
        let gate = Gate()
        let (facade, engine) = try makeEngine(
            GatedTransport(
                gate: gate,
                auto: [
                    "POST sessions": (200, Wire.session()), "POST me/logout": (204, ""),
                    "GET unread": (200, #"{"unread":0,"lastSeq":0,"live":false}"#),
                ]))
        engine.start()
        defer { engine.stop() }
        try await facade.prepare()
        facade.setTraits(["plan": "pro"])
        #expect(await advanceUntil { await gate.count("PATCH me") == 1 })
        await engine.performLogout()
        let index = try #require(await gate.log.firstIndex { $0.path == "me" && $0.method == "PATCH" })
        await gate.release(index, 200, #"{"person":{"id":"per_1","level":"named","name":"Ada Lovelace"},"rejected":[]}"#)
        await settle()
        #expect(facade.person == nil, "PingFront.person came back after logout")
    }

    @Test("A send that finishes after logout is not shown in the next person's thread")
    func inFlightSendAfterLogout() async throws {
        let gate = Gate()
        let (facade, engine) = try makeEngine(
            GatedTransport(
                gate: gate,
                auto: [
                    "POST sessions": (200, Wire.session()), "POST me/logout": (204, ""),
                    "GET unread": (200, #"{"unread":0,"lastSeq":0,"live":false}"#),
                ]))
        engine.start()
        defer { engine.stop() }
        engine.send(text: "for the old person", photos: [], replyTo: nil)
        #expect(await eventually { await gate.count("POST thread/messages") == 1 })
        let clientId = try #require(await engine.outbox.all().first?.clientId)
        await engine.performLogout()
        let index = try #require(await gate.log.firstIndex { $0.path == "thread/messages" })
        await gate.release(index, 200, Wire.message(id: "srv_old", seq: 1, clientId: clientId, text: "for the old person"))
        await settle()
        #expect(facade.conversation.messages.isEmpty)
        #expect(facade.conversation.pending.isEmpty)
    }

    // MARK: Android finding 3: erase never re-registers the person

    @Test("While DELETE /me is in flight no token request refreshes or re-creates the session, and the profile is gone")
    func eraseBlocksTokenRequests() async throws {
        let gate = Gate()
        let (facade, engine) = try makeEngine(GatedTransport(gate: gate, auto: ["POST sessions": (200, Wire.session())]))
        engine.start()
        defer { engine.stop() }
        facade.identify(userId: "user-a", name: "Ada", email: "ada@example.com")
        await settle()
        try await facade.prepare()
        let creates = await gate.count("POST sessions")
        let erase = Task { try await facade.eraseMyData() }
        #expect(await eventually { await gate.count("DELETE me") == 1 })
        #expect(await engine.coalescer.stagedProfile().identity == nil, "the identity was still staged during the erase")
        // Every path that asks for a token while the erase runs: unread poll, PATCH, read receipt, outbox, prepare.
        await engine.unread.refresh()
        facade.setTraits(["plan": "pro"])
        engine.send(text: "during erase", photos: [], replyTo: nil)
        await #expect(throws: PingFrontError.cancelled) { try await facade.prepare() }
        await settle()
        #expect(await gate.count("POST sessions") == creates)
        #expect(await gate.count("POST sessions/refresh") == 0)
        let index = try #require(await gate.log.firstIndex { $0.method == "DELETE" })
        await gate.release(index, 204, "")
        try await erase.value
        #expect(await engine.session.erasing == false)
        #expect(await engine.coalescer.stagedProfile().identity == nil)
    }
}
