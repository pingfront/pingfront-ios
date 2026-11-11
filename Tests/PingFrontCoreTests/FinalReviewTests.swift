import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// The 3 Nov 2026 final iOS review: each test failed on the code before its fix.
@Suite("Final review, 3 Nov 2026")
@MainActor
struct FinalReviewTests {
    let clock = TestClock()

    func makeEngine(_ transport: any Transport, persistence: any Persistence = MemoryPersistence()) throws -> (PingFront, Engine) {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse(LifecycleRaceTests.key).get(), configuration: configuration,
            dependencies: Dependencies(
                transport: transport, secure: MemorySecureStore(), persistence: persistence, time: TimeSource(clock)))
        facade.engine = engine
        Retain.keep(facade)
        return (facade, engine)
    }

    /// True if `condition` never holds within `timeout` (real time: work off the main actor must have a chance).
    func never(timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
        !(await eventually(timeout: timeout, condition))
    }

    static func renewal(at date: Date) -> StoreEventReport {
        StoreEventReport(name: "subscription_renewed", productId: "pro.yearly", transactionId: "2000000001", occurredAt: date)
    }

    static let listened = #"{"names":[],"storeEvents":["subscription_renewed"]}"#

    // MARK: IO-4: store detections StoreKit replays at launch

    @Test("A new install reports nothing StoreKit replays from before this launch (no request at all)")
    func newInstallSkipsReplayedStoreEvents() async throws {
        let server = StubServer()
        await server.on("GET moments/listened", .ok(Self.listened))
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST moments", .ok(#"{"outcome":"delivered","open":false}"#))
        let (_, engine) = try makeEngine(StubTransport(server: server))
        engine.start()
        defer { engine.stop() }
        let result = await engine.storeEvent(Self.renewal(at: .now.addingTimeInterval(-3600)))
        #expect(result == .notListened)
        #expect(await server.requests("GET moments/listened").isEmpty, "a new install asked the server at launch")
        #expect(await server.requests("POST sessions").isEmpty, "a new install started a session at launch")
    }

    @Test("A store event while the app runs, or from an install with a session, is still reported")
    func liveAndKnownInstallStoreEventsStillReport() async throws {
        let server = StubServer()
        await server.on("GET moments/listened", .ok(Self.listened))
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST moments", .ok(#"{"outcome":"delivered","open":false}"#))
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        engine.start()
        defer { engine.stop() }
        #expect(await engine.storeEvent(Self.renewal(at: .now.addingTimeInterval(5))) == .delivered)
        try await facade.prepare()
        let older = StoreEventReport(
            name: "subscription_renewed", productId: "pro.yearly", transactionId: "2000000002", occurredAt: .distantPast)
        #expect(await engine.storeEvent(older) == .delivered)
        #expect(await server.requests("POST moments").count == 2)
    }

    // MARK: IO-5: a photo still preparing at logout

    static func largePNG() throws -> Data {
        let side = 3000
        let context = try #require(
            CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for row in stride(from: 0, to: side, by: 30) {
            context.setFillColor(CGColor(red: CGFloat(row % 255) / 255, green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: side, height: 15))
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("A photo that is still being prepared at logout or erase is never sent and starts no session")
    func photoPreparedAfterLogoutIsDropped() async throws {
        let png = try Self.largePNG()
        for erase in [false, true] {
            let gate = Gate()
            let (facade, engine) = try makeEngine(GatedTransport(gate: gate, auto: ["POST me/logout": (204, "")]))
            engine.start()
            engine.send(text: nil, photos: [png], replyTo: nil)
            if erase { try await facade.eraseMyData() } else { await engine.performLogout() }
            #expect(
                await never {
                    let sessions = await gate.count("POST sessions")
                    let sends = await gate.count("POST thread/messages")
                    return sessions + sends > 0
                },
                "the photo went out for the next person (erase: \(erase))")
            #expect(await engine.outbox.all().isEmpty)
            engine.stop()
        }
    }

    // MARK: IO-6: a revoked install's remaining queue

    @Test("After session_revoked, the rest of the queue is not sent under a new guest session")
    func revokedQueueIsNotResentAsANewGuest() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()), .ok(Wire.session(token: "tok_guest", secret: "sec_2")))
        await server.on("POST sessions/refresh", .json(401, Wire.error("session_revoked")))
        await server.on("POST thread/messages", .ok(Wire.message()))
        await server.on("GET unread", .ok(#"{"unread":0,"lastSeq":0,"live":false}"#))
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        engine.start()
        defer { engine.stop() }
        try await facade.prepare()
        // Two messages queued while offline, with an access token that has expired (expired first, so no
        // delivery that an enqueue wakes can use a valid one).
        await engine.session.adoptForTesting(token: "tok_old", validFor: .zero)
        await engine.outbox.enqueue(PendingMessage(clientId: "c1", text: "first"))
        await engine.outbox.enqueue(PendingMessage(clientId: "c2", text: "second"))
        engine.outboxWake.notify()
        #expect(await eventually { await server.requests("POST sessions/refresh").count >= 1 })
        #expect(
            await never { await !server.requests("POST thread/messages").isEmpty }, "a revoked install's message was sent as a new guest")
    }

    // MARK: IO-7: queued team action answers survive logout

    @Test("Clearing team action answers that were never loaded deletes them on disk")
    func clearedAcksStayCleared() async {
        let disk = MemoryPersistence()
        await TeamActionAcks(persistence: disk).enqueue(id: "ta_1", TeamActionAck(ok: true))
        await TeamActionAcks(persistence: disk).clear()
        #expect(await TeamActionAcks(persistence: disk).all().isEmpty, "the previous person's answer is still queued")
    }

    // MARK: IO-9: clearing the outbox while it loads

    /// Persistence whose first read waits until released.
    actor SlowReadPersistence: Persistence {
        private let inner = MemoryPersistence()
        private var held: [CheckedContinuation<Void, Never>] = []
        private var holding = true
        private(set) var waiting = false
        func read(_ name: String) async throws -> Data? {
            if holding {
                waiting = true
                await withCheckedContinuation { held.append($0) }
            }
            return await inner.read(name)
        }
        func write(_ name: String, _ data: Data) async throws { await inner.write(name, data) }
        func remove(_ name: String) async throws { await inner.remove(name) }
        func release() {
            holding = false
            for continuation in held { continuation.resume() }
            held = []
        }
    }

    @Test("Clearing the outbox while it is still loading never brings the old queue back")
    func outboxClearDuringLoad() async throws {
        let disk = SlowReadPersistence()
        // Store one item through a loaded outbox.
        await disk.release()
        await Outbox(persistence: disk).enqueue(PendingMessage(clientId: "c1", text: "old"))
        let disk2 = SlowReadPersistence()
        try await disk2.write(Files.outbox, try #require(await disk.read(Files.outbox)))
        let outbox = Outbox(persistence: disk2)
        let load = Task { await outbox.load() }
        #expect(await eventually { await disk2.waiting })
        let clear = Task { await outbox.clear() }
        await settle()
        await disk2.release()
        _ = await load.value
        await clear.value
        #expect(await outbox.all().isEmpty, "the cleared queue came back")
        #expect(await Outbox(persistence: disk2).all().isEmpty, "the cleared queue is still on disk")
    }

    // MARK: IO-8: logout and push

    @Test("After logout the device's push token goes with the next install's first PATCH (A-13)")
    func logoutKeepsTheDevicePushToken() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()), .ok(Wire.session(token: "tok_2", secret: "sec_2")))
        await server.on("PATCH me", .ok(#"{"person":{"id":"per_1","level":"guest"},"rejected":[]}"#))
        await server.on("POST me/logout", .json(204, ""))
        await server.on("GET unread", .ok(#"{"unread":0,"lastSeq":0,"live":false}"#))
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        engine.start()
        defer { engine.stop() }
        facade.setPushToken(Data([1, 2, 3, 4]))
        try await facade.prepare()
        #expect(await advanceUntil { await server.requests("PATCH me").contains { $0.json?["push"] != nil } })
        await engine.performLogout()
        try await facade.prepare()
        #expect(
            await advanceUntil { await server.requests("PATCH me").filter { $0.json?["push"] != nil }.count == 2 },
            "the next install never got the device's push token")
        #expect(engine.unread.pushRegistered)
    }

    /// Moves the injected clock in 250 ms steps until `condition` holds.
    func advanceUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            clock.advance(by: Timing.patchWindow)
            await settle()
        }
        return await condition()
    }

    @Test("After logout without a push token, the unread count is polled")
    func logoutWithoutPushPolls() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST me/logout", .json(204, ""))
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        engine.start()
        defer { engine.stop() }
        try await facade.prepare()
        await engine.performLogout()
        #expect(!engine.unread.pushRegistered)
    }

    // MARK: IO-10: the thread revision after logout

    @Test("Logout and erase forget the previous thread's revision")
    func logoutForgetsThreadRevision() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET thread", .ok(LifecycleRaceTests.threadJSON))
        await server.on("POST me/logout", .json(204, ""))
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        engine.start()
        defer { engine.stop() }
        try await facade.prepare()
        await engine.loadThread()
        #expect(await engine.api.threadRevision.value == 1)
        await engine.performLogout()
        #expect(await engine.api.threadRevision.value == nil, "the next person's first /thread call carries the old revision")
    }

    // MARK: IO-12: a store action sheet open at logout

    @MainActor final class GatedStoreActions: StoreActionHandling {
        var waiting: CheckedContinuation<StoreActionOutcome, Never>?
        func perform(_ request: StoreActionRequest) async -> StoreActionOutcome {
            await withCheckedContinuation { waiting = $0 }
        }
    }

    @Test("A store action sheet that closes after logout adds no receipt and reports nothing for the next person")
    func storeActionAfterLogout() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()), .ok(Wire.session(token: "tok_2", secret: "sec_2")))
        await server.on("POST store-actions", .ok(#"{"message":null}"#))
        await server.on("POST me/logout", .json(204, ""))
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        engine.start()
        defer { engine.stop() }
        try await facade.prepare()
        let handler = GatedStoreActions()
        facade.registry.storeActionHandler = handler
        engine.cards.perform(StoreActionCard(id: "sa1", action: .manageSubscriptions), messageId: "m1")
        #expect(await eventually { @MainActor in handler.waiting != nil })
        await engine.performLogout()
        handler.waiting?.resume(returning: .completed(.autoRenewOff))
        await settle()
        #expect(facade.conversation.messages.isEmpty, "the previous person's receipt is in the next person's chat")
        #expect(await never(timeout: .seconds(1)) { await !server.requests("POST store-actions").isEmpty })
    }

    // MARK: IO-13: records moved aside survive erase

    @Test("Erase deletes what was moved aside as unreadable (the thread cache and the outbox)")
    func eraseRemovesAsideRecords() async throws {
        let disk = MemoryPersistence()
        let newer = Data(#"{"v":99,"value":{"messages":[{"text":"from a newer SDK"}]}}"#.utf8)
        await disk.write(Files.thread, newer)
        await disk.write(Files.outbox, newer)
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("DELETE me", .json(204, ""))
        let (facade, engine) = try makeEngine(StubTransport(server: server), persistence: disk)
        engine.start()
        defer { engine.stop() }
        try await facade.prepare()
        #expect(await engine.threadCache.load() == nil)
        _ = await engine.outbox.load()
        #expect(await disk.read("\(Files.thread).aside-1") != nil, "the unreadable cache was kept aside")
        #expect(await disk.read("\(Files.outbox).aside-1") != nil, "the unreadable queue was kept aside")
        try await facade.eraseMyData()
        #expect(await disk.read("\(Files.thread).aside-1") == nil, "the erased person's thread is still on the device")
        #expect(await disk.read("\(Files.outbox).aside-1") == nil, "the erased person's queue is still on the device")
    }

    // MARK: IO-14: a photo that can't be prepared, with text

    @Test("A message whose photo can't be prepared is shown as failed, never sent without the photo")
    func photoFailureWithTextFailsTheMessage() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST thread/messages", .ok(Wire.message()))
        let (facade, engine) = try makeEngine(StubTransport(server: server))
        engine.start()
        defer { engine.stop() }
        engine.send(text: "Here is the screenshot", photos: [Data("not an image".utf8)], replyTo: nil)
        #expect(await eventually { @MainActor in facade.conversation.pending.first?.state == .failed })
        #expect(await never(timeout: .seconds(1)) { await !server.requests("POST thread/messages").isEmpty }, "sent without its photo")
        // Try again sends what can be sent: the text.
        let failed = try #require(facade.conversation.pending.first)
        facade.conversation.retry(failed)
        #expect(await eventually { await server.requests("POST thread/messages").count == 1 })
        #expect(await server.requests("POST thread/messages").first?.json?["text"] as? String == "Here is the screenshot")
    }

    // MARK: IO-11: unknown typing author kinds

    @Test("A typing event from an author kind this version doesn't know decodes, and clears the dots")
    func unknownTypingAuthorKind() throws {
        let event = try ServerEvent.decode(Data(#"{"type":"typing","author":{"kind":"system"},"on":false}"#.utf8))
        guard case .typing(let kind, _, let on) = event else {
            Issue.record("not a typing event: \(event)")
            return
        }
        #expect(![ServerEvent.TypingAuthorKind.team, .ai].contains(kind))
        #expect(on == false)
    }
}
