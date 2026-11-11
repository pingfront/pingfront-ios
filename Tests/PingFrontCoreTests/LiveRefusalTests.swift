import Foundation
import Testing
import os

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// A socket the server refused at the handshake (403: the app paused, the person blocked).
final class RefusedSocket: WebSocketConnection, Sendable {
    func send(_ text: String) async throws {}
    var handshakeStatus: Int? { 403 }
    func receive() async throws -> String { throw URLError(.badServerResponse) }
    func close() {}
}

struct RefusingTransport: Transport {
    let inner: GatedTransport
    let sockets = OSAllocatedUnfairLock(initialState: 0)
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await inner.data(for: request) }
    func webSocket(url: URL, protocols: [String]) async throws -> any WebSocketConnection {
        sockets.withLock { $0 += 1 }
        return RefusedSocket()
    }
}

/// While sending is closed, the live socket stops instead of reconnecting on a backoff forever; the policy closes.
@Suite("Live socket refusals")
struct LiveRefusalTests {
    let key = "pk_test_abcdefghijklmnopqrstuvvd"

    func live(_ transport: any Transport, clock: TestClock) -> LiveConnection {
        let time = TimeSource(clock)
        let api = APIClient(
            baseURL: StubTransport.base, appKey: key, transport: transport,
            cooldowns: CooldownBook(time: time))
        let session = SessionStore(api: api, secure: MemorySecureStore(), time: time, profile: PatchCoalescer(time: time))
        return LiveConnection(api: api, session: session, time: time)
    }

    @Test("A 403 at the handshake stops the socket: no reconnect")
    func handshakeRefused() async throws {
        let clock = TestClock()
        let transport = RefusingTransport(inner: GatedTransport(gate: Gate(), auto: ["POST sessions": (200, Wire.session())]))
        let live = live(transport, clock: clock)
        let seen = OSAllocatedUnfairLock<[LiveConnection.Signal]>(initialState: [])
        let consumer = Task { for await s in live.signals { seen.withLock { $0.append(s) } } }
        await live.start(LiveEndpoint(url: URL(string: "wss://api.test/v1/live")!))
        #expect(await waitUntil { seen.withLock { $0.contains(.refused(nil)) } }, "signals: \(seen.withLock { $0 })")
        clock.advance(by: .seconds(600))
        await settle()
        consumer.cancel()
        #expect(transport.sockets.withLock { $0 } == 1, "reconnected after a refusal")
    }

    @Test("A refused session (app paused) stops the socket and carries the reason")
    func tokenRefused() async throws {
        let clock = TestClock()
        let transport = GatedTransport(gate: Gate(), auto: ["POST sessions": (403, Wire.error("app_paused"))])
        let live = live(transport, clock: clock)
        let seen = OSAllocatedUnfairLock<[LiveConnection.Signal]>(initialState: [])
        let consumer = Task { for await s in live.signals { seen.withLock { $0.append(s) } } }
        await live.start(LiveEndpoint(url: URL(string: "wss://api.test/v1/live")!))
        #expect(
            await waitUntil {
                seen.withLock { $0.contains { if case .refused(let e) = $0 { return e?.code == .appPaused } else { return false } } }
            })
        consumer.cancel()
        #expect(transport.socketLog.count == 0)
    }

    struct RefusingStub: Transport {
        let stub: StubTransport
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await stub.data(for: request) }
        func webSocket(url: URL, protocols: [String]) async throws -> any WebSocketConnection { RefusedSocket() }
    }

    static func thread(_ policy: String) -> String {
        #"{"thread":{"id":"thr_1","status":"open","lastSeq":0,"readSeq":0,"unread":0},"messages":[],"hasOlder":false,"team":[],"policy":\#(policy)}"#
    }

    @Test("A refused handshake reads the thread again, whose policy says why (paused)")
    @MainActor func refusedHandshakeReloads() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET config", .json(503, Wire.error("unavailable")))
        await server.on(
            "GET thread", .ok(Self.thread(#"{"canSend":true}"#)), .ok(Self.thread(#"{"canSend":false,"reason":"app_paused"}"#)))
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: RefusingStub(stub: StubTransport(server: server)), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(TestClock()))
        facade.start(appKey: key, configuration: configuration)
        Retain.keep(facade)
        defer { facade.teardown() }
        facade.chatVisibilityChanged(true)
        #expect(await eventually { await MainActor.run { facade.conversation.policy } == .closed(.appPaused) })
        #expect(await server.requests("GET thread").count == 2)
    }
}
