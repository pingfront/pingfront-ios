import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// A paused app refuses `GET /unread`, so nothing is polled while it is paused; the next foreground asks once, and an
/// answer clears the pause, so the badge catches up without the chat being opened (as on Android).
@Suite("Unread while the app is paused")
@MainActor
struct PausedUnreadTests {
    let server = StubServer()

    func makeEngine() throws -> (PingFront, Engine) {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse("pk_test_abcdefghijklmnopqrstuvvd").get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
                time: TimeSource(TestClock())))
        facade.engine = engine
        Retain.keep(facade)
        return (facade, engine)
    }

    @Test("Each foreground while paused asks once; an answer clears the pause and updates the badge")
    func foregroundProbe() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST sessions/refresh", .ok(Wire.refresh()))
        await server.on(
            "GET unread", .json(403, Wire.error("app_paused")), .json(403, Wire.error("app_paused")),
            .ok(#"{"unread":3,"lastSeq":3,"live":false}"#))
        // A session exists, then a read says the app is paused.
        _ = try await engine.session.token(reason: .chatOpened)
        await engine.unread.refresh()
        #expect(facade.conversation.policy == .closed(.appPaused))
        #expect(await server.requests("GET unread").count == 1)

        // Still paused at the next foreground: one read, refused again.
        engine.lifecycle(.foreground)
        #expect(await eventually { await server.requests("GET unread").count == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(facade.conversation.policy == .closed(.appPaused))
        #expect(facade.unreadCount == 0)

        // Resumed by the next foreground: the badge catches up and sending reopens, with the chat never opened.
        engine.lifecycle(.foreground)
        #expect(await eventually { @MainActor in facade.unreadCount == 3 })
        #expect(facade.conversation.policy == .open)
        #expect(!facade.isChatVisible)
        #expect(await server.requests("GET unread").count == 3)
        #expect(await server.requests("GET thread").isEmpty, "no thread load was needed")
    }

    @Test("Not paused and without push, a foreground does not read (the poll schedule does)")
    func noProbeWhenOpen() async throws {
        let (_, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET unread", .ok(#"{"unread":1,"lastSeq":1,"live":false}"#))
        _ = try await engine.session.token(reason: .chatOpened)
        engine.lifecycle(.foreground)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.requests("GET unread").isEmpty)
    }
}
