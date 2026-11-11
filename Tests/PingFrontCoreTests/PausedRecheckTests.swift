import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// An open chat that is paused reads the thread every 60 s on the injected clock, and stops when the chat hides or the
/// pause ends.
@Suite("Paused re-check")
@MainActor
struct PausedRecheckTests {
    let server = StubServer()
    let clock = TestClock()

    func makeEngine() throws -> (PingFront, Engine) {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse("pk_test_abcdefghijklmnopqrstuvvd").get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
                time: TimeSource(clock)))
        facade.engine = engine
        engine.preview = false
        Retain.keep(facade)
        return (facade, engine)
    }

    static let paused = #"{"thread":null,"messages":[],"hasOlder":false,"team":[],"policy":{"canSend":false,"reason":"app_paused"}}"#

    func tick() async {
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(60))
        await settle()
    }

    @Test("Visible and paused: a thread read every 60 s until the app is resumed")
    func rechecksUntilResumed() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET thread", .ok(Self.paused), .ok(Self.paused), .ok(PolicyRefusalTests.thread(canSend: true)))
        _ = try await engine.session.token(reason: .chatOpened)
        facade.isChatVisible = true
        await engine.loadThread()
        #expect(facade.conversation.policy == .closed(.appPaused))
        #expect(engine.pausedRecheck != nil)
        clock.advance(by: .seconds(59))
        await settle()
        #expect(await server.requests("GET thread").count == 1, "nothing before 60 s")
        await tick()
        #expect(await server.requests("GET thread").count == 2)
        await tick()
        #expect(await eventually { @MainActor in facade.conversation.policy == .open })
        #expect(await eventually { @MainActor in engine.pausedRecheck == nil }, "resumed: the re-check ends")
        clock.advance(by: .seconds(120))
        await settle()
        #expect(await server.requests("GET thread").count == 3)
    }

    @Test("Hiding the chat stops the re-check")
    func stopsWhenHidden() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET thread", .ok(Self.paused))
        _ = try await engine.session.token(reason: .chatOpened)
        facade.isChatVisible = true
        await engine.loadThread()
        #expect(engine.pausedRecheck != nil)
        facade.isChatVisible = false
        engine.chatDidDisappear()
        #expect(engine.pausedRecheck == nil)
        clock.advance(by: .seconds(180))
        await settle()
        #expect(await server.requests("GET thread").count == 1)
    }
}
