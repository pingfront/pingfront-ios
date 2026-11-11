import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UserNotifications
import os

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontPush
@testable import PingFrontTestSupport

/// A socket that stays open but never answers pings (a half-open connection).
///
/// Everything ends on close().
final class HalfOpenSocket: WebSocketConnection, Sendable {
    private struct State {
        var waiters: [CheckedContinuation<String, any Error>] = []
        var pingWaiters: [CheckedContinuation<Void, any Error>] = []
        var inbox: [String] = []
        var closed = false
        var pings = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var handshakeStatus: Int? { nil }
    var isClosed: Bool { state.withLock { $0.closed } }
    var pingCount: Int { state.withLock { $0.pings } }
    func send(_ text: String) async throws {}
    func push(_ text: String) {
        let waiter = state.withLock { s -> CheckedContinuation<String, any Error>? in
            if !s.waiters.isEmpty { return s.waiters.removeFirst() }
            s.inbox.append(text)
            return nil
        }
        waiter?.resume(returning: text)
    }
    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            let now = state.withLock { s -> Result<String, any Error>? in
                if s.closed { return .failure(URLError(.cancelled)) }
                if !s.inbox.isEmpty { return .success(s.inbox.removeFirst()) }
                s.waiters.append(c)
                return nil
            }
            if let now { c.resume(with: now) }
        }
    }
    func ping() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            let closed = state.withLock { s -> Bool in
                s.pings += 1
                if s.closed { return true }
                s.pingWaiters.append(c)
                return false
            }
            if closed { c.resume(throwing: URLError(.cancelled)) }
        }
    }
    func close() {
        let (waiters, pings) = state.withLock { s -> ([CheckedContinuation<String, any Error>], [CheckedContinuation<Void, any Error>]) in
            s.closed = true
            defer {
                s.waiters = []
                s.pingWaiters = []
            }
            return (s.waiters, s.pingWaiters)
        }
        waiters.forEach { $0.resume(throwing: URLError(.cancelled)) }
        pings.forEach { $0.resume(throwing: URLError(.cancelled)) }
    }
}

struct HalfOpenTransport: Transport {
    let sockets = OSAllocatedUnfairLock<[HalfOpenSocket]>(initialState: [])
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(Wire.session().utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func webSocket(url: URL, protocols: [String]) async throws -> any WebSocketConnection {
        let socket = HalfOpenSocket()
        sockets.withLock { $0.append(socket) }
        return socket
    }
}

struct DummyOffers: OfferSource {
    func offers() async -> [OfferSlot] { [] }
}

@Suite("Hardening")
struct HardeningTests {
    let key = "pk_test_abcdefghijklmnopqrstuvvd"

    @MainActor
    func makeEngine(_ transport: any Transport, secure: MemorySecureStore = MemorySecureStore(), clock: TestClock = TestClock()) throws -> (
        PingFront, Engine
    ) {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse(key).get(), configuration: configuration,
            dependencies: Dependencies(transport: transport, secure: secure, persistence: MemoryPersistence(), time: TimeSource(clock)))
        facade.engine = engine
        Retain.keep(facade)
        return (facade, engine)
    }

    @Test("A half-open socket (no pong) is closed after the heartbeat deadline and the channel reconnects")
    func halfOpenSocket() async throws {
        let clock = TestClock()
        let time = TimeSource(clock)
        let transport = HalfOpenTransport()
        let api = APIClient(baseURL: StubTransport.base, appKey: key, transport: transport, cooldowns: CooldownBook(time: time))
        let live = LiveConnection(
            // The profile coalescer gets its own clock: its 250 ms flush must not count as the heartbeat sleeper.
            api: api,
            session: SessionStore(
                api: api, secure: MemorySecureStore(), time: time, profile: PatchCoalescer(time: TimeSource(TestClock()))),
            time: time)
        await live.start(LiveEndpoint(url: URL(string: "wss://api.test/v1/live")!))
        #expect(await eventually { transport.sockets.withLock { $0.count } == 1 })
        let first = try #require(transport.sockets.withLock { $0.first })
        first.push(#"{"type":"hello","lastSeq":0,"readSeq":0}"#)
        await clock.waitForSleepers()
        clock.advance(by: LiveProtocol.heartbeat)  // heartbeat: ping sent, no pong
        await clock.waitForSleepers()
        clock.advance(by: LiveProtocol.pongDeadline)  // deadline passes
        let closed = await eventually(timeout: .seconds(10)) { first.isClosed }
        #expect(closed, "the dead socket was not closed (sleepers \(clock.sleeperCount), now \(clock.now), pings \(first.pingCount))")
        await clock.waitForSleepers()
        clock.advance(by: .seconds(2))  // reconnect backoff
        #expect(
            await eventually(timeout: .seconds(10)) { transport.sockets.withLock { $0.count } == 2 }, "no reconnect after a missing pong")
        await live.stop()
    }

    @Test("A send whose session is wiped mid-flight never reaches the server")
    @MainActor func sendAbortedByLogout() async throws {
        let gate = Gate()
        let (facade, engine) = try makeEngine(GatedTransport(gate: gate))
        defer { withExtendedLifetime(facade) {} }
        let deliver = engine.deliverer()
        let item = PendingMessage(clientId: "c-1", text: "for the old person")
        let send = Task { () -> Bool in
            do {
                _ = try await deliver(item)
                return true
            } catch { return false }
        }
        #expect(await eventually { await gate.total == 1 })  // POST sessions in flight
        await engine.session.wipe()  // logout
        await gate.release(0, 200, Wire.session())
        #expect(await send.value == false)
        #expect(await gate.count("POST thread/messages") == 0)
    }

    @Test("A live reset keeps the draft and the unsent messages")
    @MainActor func resetKeepsPending() async throws {
        let server = StubServer()
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET thread", .json(500, Wire.error("unavailable")))
        await engine.outbox.enqueue(PendingMessage(clientId: "queued-1", text: "still mine"))
        facade.conversation.draft = "typing"
        await engine.apply(.reset)
        #expect(facade.conversation.pending.map(\.clientId) == ["queued-1"])
        #expect(facade.conversation.draft == "typing")
    }

    @Test("A photo-only send whose photo cannot be prepared shows as failed and is never enqueued")
    @MainActor func failedPhotoNotSentEmpty() async throws {
        let server = StubServer()
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        engine.start()
        defer { engine.stop() }
        engine.send(text: nil, photos: [Data("not an image".utf8)], replyTo: nil)
        #expect(await eventually { @MainActor in facade.conversation.pending.first?.state == .failed })
        #expect(await engine.outbox.all().isEmpty)
        #expect(await server.requests("POST thread/messages").isEmpty)
    }

    @Test("Sends reach the outbox in tap order, even when an earlier one has a slow photo")
    @MainActor func sendOrder() async throws {
        let server = StubServer()
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        defer { withExtendedLifetime(facade) {} }
        engine.start()
        defer { engine.stop() }
        engine.send(text: "first, with a big photo", photos: [Self.png(side: 2400)], replyTo: nil)
        engine.send(text: "second", photos: [], replyTo: nil)
        #expect(await eventually { await engine.outbox.all().count == 2 })
        #expect(await engine.outbox.all().map(\.text) == ["first, with a big photo", "second"])
    }

    @Test("Reconfiguring does not duplicate module sources")
    @MainActor func reconfigureNoDuplicates() throws {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: StubServer()), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(TestClock()))
        configuration.use(PingFrontModule(id: "offers") { $0.addOfferSource(DummyOffers()) })
        facade.start(appKey: key, configuration: configuration)
        facade.start(appKey: key, configuration: configuration)
        #expect(facade.offerSources.count == 1)
        facade.teardown()
    }

    @Test("Keychain and files are namespaced per app key")
    func namespaces() throws {
        let test = try AppKey.parse("pk_test_abcdefghijklmnopqrstuvvd").get()
        let live = try AppKey.parse("pk_live_0123456789ABCDEFGHIJKLNy").get()
        let a = Dependencies.namespace(for: test)
        let b = Dependencies.namespace(for: live)
        #expect(a.hasPrefix("test-") && b.hasPrefix("live-") && a != b)
        #expect(Dependencies.namespace(for: test) == a)
    }

    @Test("thread.rev is sent as PF-Thread-Rev on /thread calls only; 409 thread_reset drops it and reloads")
    @MainActor func threadRevision() async throws {
        let server = StubServer()
        await server.on(
            "GET thread",
            .ok(
                #"{"thread":{"id":"thr_1","status":"open","lastSeq":0,"readSeq":0,"teamReadSeq":0,"unread":0,"rev":7},"messages":[],"hasOlder":false,"team":[],"policy":{"canSend":true}}"#
            ))
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET unread", .ok(#"{"unread":0,"lastSeq":0,"live":false}"#))
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        defer { withExtendedLifetime(facade) {} }
        await engine.loadThread()
        await engine.loadThread()
        #expect(await server.requests("GET thread").first?.headers["PF-Thread-Rev"] == nil)
        #expect(await server.requests("GET thread").last?.headers["PF-Thread-Rev"] == "7")
        _ = try await engine.client.send(Endpoints.unread())
        #expect(await server.requests("GET unread").first?.headers["PF-Thread-Rev"] == nil)
        facade.conversation.draft = "keep me"
        engine.noteFailure(.server(ServerError(status: 409, code: .threadReset, message: "reset", docs: nil, retryAfter: nil, scope: nil)))
        #expect(await eventually { await server.requests("GET thread").count >= 3 }, "thread_reset did not reload the thread")
        // The reload goes out without the stale revision, so it cannot 409 again.
        #expect(await server.requests("GET thread")[2].headers["PF-Thread-Rev"] == nil)
        #expect(facade.conversation.draft == "keep me")
    }

    @Test("PF-Thread-Rev on a response is kept: the first card action after the first message sends the new revision")
    func threadRevisionFromResponse() async throws {
        let server = StubServer()
        await server.on("POST thread/messages", .json(201, Wire.message(clientId: "c1"), headers: ["PF-Thread-Rev": "3"]))
        await server.on("POST thread/cards/crd_1/act", .noContent)
        let api = APIClient(
            baseURL: StubTransport.base, appKey: key, transport: StubTransport(server: server),
            cooldowns: CooldownBook(time: TimeSource(TestClock())))
        await api.threadRevision.set(1)
        _ = try await api.send(
            Endpoints.sendMessage(SendMessageRequest(clientId: "c1", text: "Hi", attachmentIds: nil, replyToCard: nil)), token: "tok_1")
        _ = try await api.send(
            Endpoints.cardAction(cardId: "crd_1", CardActionRequest(messageId: "msg_2", action: .opened)), token: "tok_1")
        #expect(await server.requests("POST thread/messages").first?.headers["PF-Thread-Rev"] == "1")
        #expect(await server.requests("POST thread/cards/crd_1/act").first?.headers["PF-Thread-Rev"] == "3")
    }

    @Test("The push delegate's decisions are safe to call from a background executor")
    func pushDelegateOffMain() async throws {
        let pingFront = await MainActor.run { PingFront() }
        let options = await Task.detached { await PushDelegate.presentationOptions(isPingFront: true, pingFront: pingFront) }.value
        #expect(options == [.banner, .list, .sound])
        let other = await Task.detached { await PushDelegate.presentationOptions(isPingFront: false, pingFront: pingFront) }.value
        #expect(other == [.banner, .list, .sound])
        let payload = try #require(PushPayload(userInfo: ["pingfront": ["v": 1, "kind": "config", "appId": "app_1"]]))
        await Task.detached { await PushDelegate.openFromTap(payload, pingFront: pingFront) }.value
    }

    static func png(side: Int) -> Data {
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<40 {
            ctx.setFillColor(CGColor(red: Double(i % 7) / 7, green: Double(i % 5) / 5, blue: Double(i % 3) / 3, alpha: 1))
            ctx.fill(CGRect(x: i * side / 40, y: 0, width: side / 40, height: side))
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
