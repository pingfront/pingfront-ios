import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import os

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

// MARK: Harness

/// Requests block until the test releases them; release ignores cancellation (models a response
/// that already arrived, or a transport that does not honor cancellation).
actor Gate {
    private(set) var log: [RecordedRequest] = []
    private var waiting: [Int: CheckedContinuation<(Int, String), Never>] = [:]
    private var early: [Int: (Int, String)] = [:]

    func arrive(_ request: RecordedRequest) -> Int {
        log.append(request)
        return log.count - 1
    }

    func wait(_ index: Int) async -> (Int, String) {
        if let reply = early.removeValue(forKey: index) { return reply }
        return await withCheckedContinuation { waiting[index] = $0 }
    }

    func release(_ index: Int, _ status: Int, _ body: String) {
        if let continuation = waiting.removeValue(forKey: index) {
            continuation.resume(returning: (status, body))
        } else {
            early[index] = (status, body)
        }
    }

    func count(_ route: String) -> Int { log.filter { "\($0.method) \($0.path)" == route }.count }
    var total: Int { log.count }
}

final class FakeSocket: WebSocketConnection, Sendable {
    private struct State {
        var inbox: [String] = []
        var waiter: CheckedContinuation<String, any Error>?
        var closed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let autoReply: String?
    init(autoReply: String? = nil) { self.autoReply = autoReply }
    func send(_ text: String) async throws {}
    var handshakeStatus: Int? { nil }
    func push(_ text: String) {
        let waiter = state.withLock { s -> CheckedContinuation<String, any Error>? in
            if let w = s.waiter {
                s.waiter = nil
                return w
            }
            s.inbox.append(text)
            return nil
        }
        waiter?.resume(returning: text)
    }
    /// Like URLSessionWebSocketTask.receive(): does not react to task cancellation.
    func receive() async throws -> String {
        if let autoReply {
            await Task.yield()
            return autoReply
        }
        return try await withCheckedThrowingContinuation { c in
            let now = state.withLock { s -> Result<String, any Error>? in
                if s.closed { return .failure(URLError(.cancelled)) }
                if !s.inbox.isEmpty { return .success(s.inbox.removeFirst()) }
                s.waiter = c
                return nil
            }
            if let now { c.resume(with: now) }
        }
    }
    func close() {
        let waiter = state.withLock { s -> CheckedContinuation<String, any Error>? in
            s.closed = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(throwing: URLError(.cancelled))
    }
}

final class SocketLog: Sendable {
    let sockets = OSAllocatedUnfairLock<[FakeSocket]>(initialState: [])
    var count: Int { sockets.withLock { $0.count } }
}

struct GatedTransport: Transport {
    static let background: [String: (Int, String)] = ["GET team-actions": (200, #"{"actions":[]}"#)]
    let gate: Gate
    var auto: [String: (Int, String)] = [:]
    var socketLog = SocketLog()
    var socketAutoReply: String?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        var path = url.path()
        let base = StubTransport.base.path()
        if path.hasPrefix(base) { path.removeFirst(base.count) }
        if path.hasPrefix("/") { path.removeFirst() }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET", path: path, query: [:], headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody
        )
        // Background reads the races don't involve (the team action catch-up after a session starts) are answered
        // before the gate, so they never take an index the test releases by position.
        if let background = Self.background["\(recorded.method) \(path)"] {
            let headers = ["Content-Type": "application/json"]
            return (
                Data(background.1.utf8),
                HTTPURLResponse(url: url, statusCode: background.0, httpVersion: "HTTP/1.1", headerFields: headers)!
            )
        }
        let index = await gate.arrive(recorded)
        let reply: (Int, String)
        if let fixed = auto["\(recorded.method) \(path)"] { reply = fixed } else { reply = await gate.wait(index) }
        return (
            Data(reply.1.utf8),
            HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        )
    }

    func webSocket(url: URL, protocols: [String]) async throws -> any WebSocketConnection {
        let socket = FakeSocket(autoReply: socketAutoReply)
        socketLog.sockets.withLock { $0.append(socket) }
        return socket
    }
}

func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool { await eventually(timeout: .seconds(2), condition) }

// MARK: Proofs

/// Proofs from the adversarial concurrency review (findings F1–F10).
///
/// Each failed on the code before
/// the fixes; they guard the fixed behaviour.
@Suite("Concurrency regressions")
struct ConcurrencyRegressionTests {
    let key = "pk_test_abcdefghijklmnopqrstuvvd"

    func store(_ transport: GatedTransport, secure: MemorySecureStore = MemorySecureStore(), clock: TestClock = TestClock()) -> SessionStore
    {
        let time = TimeSource(clock)
        let api = APIClient(baseURL: StubTransport.base, appKey: key, transport: transport, cooldowns: CooldownBook(time: time))
        return SessionStore(api: api, secure: secure, time: time, profile: PatchCoalescer(time: time))
    }

    @Test("F1a: a token() caller that resumes after wipe() clears the NEXT single-flight task -> duplicate POST /sessions")
    func inflightClobber() async throws {
        let gate = Gate()
        let session = store(GatedTransport(gate: gate))
        let a = Task { try await session.token(reason: .chatOpened) }  // request 0
        #expect(await waitUntil { await gate.total == 1 })
        await session.wipe()  // logout
        let b = Task { try await session.token(reason: .chatOpened) }  // request 1 (new single flight)
        #expect(await waitUntil { await gate.total == 2 })
        await gate.release(0, 503, Wire.error("unavailable"))  // cancelled request fails; A resumes, sets inflight = nil
        _ = try? await a.value
        let c = Task { try await session.token(reason: .chatOpened) }  // should join B's flight
        await settle()
        let creates = await gate.count("POST sessions")
        await gate.release(1, 200, Wire.session(token: "b", secret: "b"))
        await gate.release(2, 200, Wire.session(token: "c", secret: "c"))
        _ = try? await b.value
        _ = try? await c.value
        #expect(creates == 2, "expected B and C to share one create; got \(creates) creates")
    }

    @Test("F1b: a session create that lands after wipe() resurrects credentials and the token")
    func createAfterWipe() async throws {
        let gate = Gate()
        let secure = MemorySecureStore()
        let session = store(GatedTransport(gate: gate), secure: secure)
        let a = Task { try await session.token(reason: .chatOpened) }
        #expect(await waitUntil { await gate.total == 1 })
        await session.wipe()
        await gate.release(0, 200, Wire.session(token: "ghost", secret: "ghost_secret"))
        _ = try? await a.value
        await settle()
        let stored = try await secure.read(SecureKeys.credentials)
        #expect(stored == nil, "credentials written after logout: \(stored.map { String(decoding: $0, as: UTF8.self) } ?? "")")
        #expect(await session.isActive == false)
    }

    @Test("F2: an acked own message advances the tracker, so a team message missed during a reconnect is never repaired")
    @MainActor func ownAckMasksGap() async throws {
        let server = StubServer()
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse(key).get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
                time: TimeSource(TestClock())))
        facade.engine = engine
        Retain.keep(facade)
        await server.on("POST sessions", .ok(Wire.session()))
        // The repair page returns what the socket missed (the reviewer's original stub returned nothing,
        // which no implementation could recover from).
        await server.on("GET thread/messages", .ok(#"{"messages":[\#(EngineTests.messageJSON(2))],"hasMore":false}"#))
        facade.conversation.merge([makeMessage("m1", seq: 1)])
        // Socket drops; team writes seq 2 (missed); the person's queued message is acked as seq 3 (outbox -> delivered -> merge).
        facade.conversation.merge([makeMessage("m3", seq: 3, kind: .person, clientId: "c1")])
        // Reconnect: hello says lastSeq 3.
        await engine.apply(.hello(lastSeq: 3, readSeq: 0))
        #expect(await server.requests("GET thread/messages").count == 1, "no gap repair was attempted")
        #expect(facade.conversation.messages.map(\.seq).contains(2), "team message seq 2 is lost")
    }

    @Test("F3: messages fetched by gap repair never count as unread or emit messageReceived; a failed repair skips the gap")
    @MainActor func repairUnreadAndFailure() async throws {
        let server = StubServer()
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse(key).get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
                time: TimeSource(TestClock())))
        facade.engine = engine
        Retain.keep(facade)
        await server.on("POST sessions", .ok(Wire.session()))
        // Real server: after=1 returns 2,3,4 — including the live event's own message.
        await server.on(
            "GET thread/messages",
            .ok(
                #"{"messages":[\#(EngineTests.messageJSON(2)),\#(EngineTests.messageJSON(3)),\#(EngineTests.messageJSON(4))],"hasMore":false}"#
            ), .json(500, Wire.error("unavailable")))
        facade.conversation.merge([makeMessage("m1", seq: 1)])
        let m4 = try WireJSON.decode(Message.self, from: Data(EngineTests.messageJSON(4).utf8))
        await engine.apply(.message(seq: 4, message: m4))
        let unreadAfterRepair = facade.unreadCount
        // Now a failing repair: seq 7 arrives, 5 and 6 missing, repair 500s.
        let m7 = try WireJSON.decode(Message.self, from: Data(EngineTests.messageJSON(7).utf8))
        await engine.apply(.message(seq: 7, message: m7))
        let tracker = facade.conversation.tracker.lastSeq
        #expect(unreadAfterRepair == 3, "3 new team messages, unread = \(unreadAfterRepair)")
        #expect(tracker < 7, "tracker advanced to \(tracker) past an unrepaired gap; 5 and 6 are never refetched")
    }

    @Test("F4: LiveConnection opens a socket after stop() and emits .live after .stopped (zombie)")
    func zombieSocket() async throws {
        let gate = Gate()
        let transport = GatedTransport(gate: gate)
        let clock = TestClock()
        let time = TimeSource(clock)
        let api = APIClient(baseURL: StubTransport.base, appKey: key, transport: transport, cooldowns: CooldownBook(time: time))
        let session = SessionStore(api: api, secure: MemorySecureStore(), time: time, profile: PatchCoalescer(time: time))
        let live = LiveConnection(api: api, session: session, time: time)
        let seen = OSAllocatedUnfairLock<[LiveConnection.Signal]>(initialState: [])
        let consumer = Task { for await s in live.signals { seen.withLock { $0.append(s) } } }
        await live.start(LiveEndpoint(url: URL(string: "wss://api.test/v1/live")!))
        #expect(await waitUntil { await gate.total == 1 })  // token: POST sessions in flight
        await live.stop()  // chat closed / app backgrounded
        await gate.release(0, 200, Wire.session())
        let opened = await waitUntil { transport.socketLog.count == 1 }
        let socket = transport.socketLog.sockets.withLock { $0.first }
        socket?.push(#"{"type":"hello","lastSeq":0,"readSeq":0}"#)
        await settle()
        let signals = seen.withLock { $0 }
        consumer.cancel()
        socket?.close()
        #expect(!opened, "a socket was opened after stop()")
        let stoppedAt = signals.firstIndex(of: .state(.stopped)) ?? Int.max
        #expect(!signals.dropFirst(stoppedAt).contains(.state(.live)), "signals after stop: \(signals)")
    }

    @Test("F5: an immediate reauth reconnects with no backoff (storm)")
    func reauthStorm() async throws {
        let gate = Gate()
        var transport = GatedTransport(
            gate: gate, auto: ["POST sessions": (200, Wire.session()), "POST sessions/refresh": (200, Wire.refresh())])
        transport.socketAutoReply = #"{"type":"reauth"}"#
        let time = TimeSource(TestClock())  // clock never advances: any backoff would block forever
        let api = APIClient(baseURL: StubTransport.base, appKey: key, transport: transport, cooldowns: CooldownBook(time: time))
        let session = SessionStore(api: api, secure: MemorySecureStore(), time: time, profile: PatchCoalescer(time: time))
        let live = LiveConnection(api: api, session: session, time: time)
        await live.start(LiveEndpoint(url: URL(string: "wss://api.test/v1/live")!))
        await settle()
        await live.stop()
        let sockets = transport.socketLog.count
        let refreshes = await gate.count("POST sessions/refresh")
        #expect(sockets <= 2, "\(sockets) sockets and \(refreshes) token refreshes in 200 ms with zero clock time elapsed")
    }

    @Test("F6: PatchCoalescer runs two PATCH /me concurrently when one takes longer than the window")
    func concurrentPatches() async throws {
        let clock = TestClock()
        let coalescer = PatchCoalescer(time: TimeSource(clock))
        let inFlight = OSAllocatedUnfairLock(initialState: (now: 0, max: 0))
        let gate = Gate()
        await coalescer.setSender { patch async throws(PingFrontError) in
            inFlight.withLock {
                $0.now += 1
                $0.max = max($0.max, $0.now)
            }
            let index = await gate.arrive(RecordedRequest(method: "PATCH", path: "me", query: [:], headers: [:], body: nil))
            _ = await gate.wait(index)
            inFlight.withLock { $0.now -= 1 }
            return try! WireJSON.decode(UpdateMeResponse.self, from: Data(#"{"person":{"id":"p","level":"named"}}"#.utf8))
        }
        await coalescer.activate()
        await coalescer.stage(.identity(Identity(userId: "alice", name: nil, email: nil, token: nil)))
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(250))
        #expect(await waitUntil { await gate.total == 1 })
        await coalescer.stage(.identity(Identity(userId: "bob", name: nil, email: nil, token: nil)))
        await clock.waitForSleepers(timeout: .milliseconds(300))  // none expected while a PATCH is in flight
        clock.advance(by: .milliseconds(250))
        _ = await waitUntil { await gate.total == 2 }
        let maxInFlight = inFlight.withLock { $0.max }
        await gate.release(0, 0, "")
        await gate.release(1, 0, "")
        #expect(maxInFlight == 1, "\(maxInFlight) PATCH /me in flight at once; server order alice/bob is not guaranteed")
    }

    @Test("F7: images smaller than 320 px cannot be sent")
    func smallImage() async throws {
        let ctx = CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        var thrown: PingFrontError?
        do { _ = try await ImagePreparation.prepare(out as Data) } catch { thrown = error }
        #expect(thrown == nil, "200x200 PNG rejected: \(String(describing: thrown))")
    }

    @Test("F8: concurrent pending-logout drains lose a logout that never reached the server")
    @MainActor func pendingLogoutLostUpdate() async throws {
        let gate = Gate()
        let secure = MemorySecureStore()
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse(key).get(), configuration: configuration,
            dependencies: Dependencies(
                transport: GatedTransport(gate: gate), secure: secure, persistence: MemoryPersistence(), time: TimeSource(TestClock())))
        facade.engine = engine
        Retain.keep(facade)
        let a = InstallCredentials(installId: "A", installSecret: "a")
        let b = InstallCredentials(installId: "B", installSecret: "b")
        try await secure.write(SecureKeys.pendingLogouts, try JSONEncoder().encode([a]))
        try await secure.write(SecureKeys.credentials, try JSONEncoder().encode(b))
        let d1 = Task { await engine.drainPendingLogouts() }  // e.g. from a .started session event: POST A (#0)
        #expect(await waitUntil { await gate.total == 1 })
        let logout = Task { await engine.performLogout() }  // logout of B: remembers [A, B], drains: POST A (#1), B (#2)
        #expect(await waitUntil { await gate.total == 2 })
        await gate.release(1, 204, "")
        #expect(await waitUntil { await gate.total == 3 })
        await gate.release(2, 503, Wire.error("unavailable"))  // B fails transiently -> should stay pending
        await logout.value
        await gate.release(0, 204, "")  // D1 finishes last and overwrites with []
        await d1.value
        let left =
            (try await VersionedFile<[InstallCredentials]>(SecureKeys.pendingLogouts, version: 1, records: SecureRecords(secure)).load())
            ?? []
        #expect(left.contains(b), "B's logout was never accepted but is no longer pending: \(left)")
    }

    @Test("F9: APIClient.send decodes the response on the caller's actor (main) under NonisolatedNonsendingByDefault")
    @MainActor func decodeOnMain() async throws {
        let server = StubServer()
        await server.on("GET thread", .ok(#"{"x":1}"#))
        let api = APIClient(
            baseURL: StubTransport.base, appKey: key, transport: StubTransport(server: server), cooldowns: CooldownBook(time: .continuous))
        let probe = try await api.send(Endpoint<MainProbe>(.get, "thread", auth: .appKeyOnly, idempotent: true))
        #expect(!probe.decodedOnMain, "JSON decoding ran on the main thread")
    }

    @Test("F10: a live `reset` wipes the person's unsent draft")
    @MainActor func resetWipesDraft() async throws {
        let server = StubServer()
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse(key).get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
                time: TimeSource(TestClock())))
        facade.engine = engine
        Retain.keep(facade)
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET thread", .json(500, Wire.error("unavailable")))
        facade.conversation.draft = "half-written complaint"
        await engine.apply(.reset)
        #expect(facade.conversation.draft == "half-written complaint")
    }
}

struct MainProbe: Decodable, Sendable {
    let decodedOnMain: Bool
    init(from decoder: any Decoder) throws { decodedOnMain = Thread.isMainThread }
}
