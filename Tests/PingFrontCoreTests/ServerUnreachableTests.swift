import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// When the device has a network but requests can't reach the service (it is down, a firewall, a captive portal), the
/// chat says it can't reach the chat, not "You're offline", as on Android (`isServerUnreachable`).
@Suite("Server unreachable vs offline")
@MainActor
struct ServerUnreachableTests {
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

    @Test("Which network failures mean the service is unreachable from a device that is online")
    func classification() {
        for code in [URLError.Code.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed] {
            #expect(PingFrontError.network(code).isServerUnreachable)
            #expect(PingFrontError.network(code).isOffline)
        }
        for code in [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff] {
            #expect(!PingFrontError.network(code).isServerUnreachable)
        }
    }

    @Test("Opening the chat with the service down: unreachable, not offline")
    func serviceDown() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .failure(.cannotConnectToHost))
        await engine.openThread()
        #expect(facade.conversation.isOffline)
        #expect(facade.conversation.isServerUnreachable)
    }

    @Test("A server error is neither offline nor unreachable (a 5xx answered: the service is reachable)")
    func serverErrorIsNotUnreachable() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .json(503, Wire.error("unavailable")))
        await engine.openThread()
        #expect(!facade.conversation.isServerUnreachable)
        #expect(!facade.conversation.isOffline)
        #expect(!PingFrontError.network(.timedOut).isServerUnreachable, "a timeout says nothing about which")
    }

    @Test("Opening the chat with no network: offline, not unreachable")
    func noNetwork() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .failure(.notConnectedToInternet))
        await engine.openThread()
        #expect(facade.conversation.isOffline)
        #expect(!facade.conversation.isServerUnreachable)
    }

    @Test("A request that gets through clears it")
    func clears() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .failure(.cannotConnectToHost), .ok(Wire.session()))
        await server.on(
            "GET thread",
            .ok(#"{"thread":null,"messages":[],"hasOlder":false,"team":[],"policy":{"canSend":true}}"#))
        await engine.openThread()
        #expect(facade.conversation.isServerUnreachable)
        await engine.openThread()
        #expect(!facade.conversation.isServerUnreachable)
    }

    @Test("A retry while the first load failed keeps the welcome or failure on screen (no spinner every 5 s)")
    func retryKeepsTheFailedState() async throws {
        let (facade, engine) = try makeEngine()
        await server.on(
            "POST sessions", .failure(.cannotConnectToHost),
            .delayed(.milliseconds(400), StubReplyBox(.failure(.cannotConnectToHost))))
        await engine.openThread()
        #expect(facade.conversation.phase == .failed(.network(.cannotConnectToHost)))
        let retry = Task { await engine.openThread() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(facade.conversation.phase != .loading, "the retry put the spinner back")
        await retry.value
    }

    @Test("An error answer from the service (a 5xx) clears it: the request got through")
    func serverErrorClears() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .failure(.cannotConnectToHost), .json(503, Wire.error("unavailable")))
        await engine.openThread()
        #expect(facade.conversation.isServerUnreachable)
        await engine.openThread()
        #expect(!facade.conversation.serverUnreachable)
    }
}
