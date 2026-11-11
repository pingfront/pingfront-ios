import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// Silent pushes (`content-available: 1`, no alert): a `config` push fetches the chat look in the background and
/// reports the result; it never shows anything and never starts a session.
@Suite("Background pushes")
struct BackgroundPushTests {
    let key = "pk_test_abcdefghijklmnopqrstuvvd"
    /// The `config` payload of the protocol fixture `push/ApnsPayload.json`.
    static var silent: [AnyHashable: Any] { ["aps": ["content-available": 1], "pingfront": ["v": 1, "kind": "config", "appId": "app_1"]] }

    @MainActor
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

    @Test("Another app's push is not ours")
    @MainActor func notOurs() async {
        let facade = configured(StubServer())
        defer { facade.teardown() }
        #expect(await facade.handleBackgroundPush(userInfo: ["aps": ["content-available": 1]]) == nil)
    }

    @Test("Without a session, a config push does nothing: no session, no fetch")
    @MainActor func noSession() async {
        let server = StubServer()
        let facade = configured(server)
        defer { facade.teardown() }
        #expect(await facade.handleBackgroundPush(userInfo: Self.silent) == .noData)
        #expect(await server.requests("GET config").isEmpty)
        #expect(await server.requests("POST sessions").isEmpty)
    }

    @Test("With a session: a new look is newData, 304 is noData, an error is failed, and no new session")
    @MainActor func refreshes() async throws {
        let server = StubServer()
        let config = try String(decoding: fixture("config-full.json"), as: UTF8.self)
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on(
            "GET config", .json(200, config, headers: ["ETag": "\"r1\""]), .json(304, ""),
            .json(503, Wire.error("unavailable")))
        let facade = configured(server)
        defer { facade.teardown() }
        let engine = try #require(facade.engine)
        _ = try await engine.session.token(reason: .prepare)
        #expect(await facade.handleBackgroundPush(userInfo: Self.silent) == .newData)
        #expect(await facade.handleBackgroundPush(userInfo: Self.silent) == .noData)
        #expect(await facade.handleBackgroundPush(userInfo: Self.silent) == .failed)
        #expect(await server.requests("GET config").count == 3)
        #expect(await server.requests("POST sessions").count == 1)
        #expect(facade.look.revision > 0)
    }
}
