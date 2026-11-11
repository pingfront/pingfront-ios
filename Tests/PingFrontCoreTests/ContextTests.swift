import Foundation
import Testing
import os

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// A scripted context source: fixed groups, a network path the test changes, and a count of every read.
final class StubContext: Sendable {
    private struct State {
        var path: ConnectionContext? = ConnectionContext(network: .wifi, constrained: false, expensive: false)
        var paths: [AsyncStream<ConnectionContext>.Continuation] = []
        var reads = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Every reader call (build, display, paths, health, notifications).
    var reads: Int { state.withLock { $0.reads } }
    /// Open path monitors.
    var monitors: Int { state.withLock { $0.paths.count } }

    /// The network changes: every open monitor sees it.
    func setPath(_ path: ConnectionContext) {
        let open = state.withLock { state in
            state.path = path
            return state.paths
        }
        open.forEach { $0.yield(path) }
    }

    private func count() { state.withLock { $0.reads += 1 } }

    var source: ContextSource {
        ContextSource(
            build: {
                self.count()
                return BuildContext(installSource: .testflight, debuggable: false)
            },
            display: {
                self.count()
                return DisplayContext(
                    screenClass: .compact, scale: 3, darkMode: true, textSize: .large, screenReader: false, reduceMotion: false,
                    boldText: false, languages: ["en-GB", "de"])
            },
            paths: {
                self.count()
                let (stream, continuation) = AsyncStream.makeStream(of: ConnectionContext.self)
                let current = self.state.withLock { state in
                    state.paths.append(continuation)
                    return state.path
                }
                let state = self.state
                continuation.onTermination = { _ in state.withLock { $0.paths.removeAll() } }
                if let current { continuation.yield(current) }
                return stream
            },
            lowPower: { false },
            health: {
                self.count()
                return HealthContext(freeStorage: .over20GB, battery: 40, charging: false, thermal: .fair)
            },
            notifications: {
                self.count()
                return NotificationContext(authorization: .provisional)
            }
        )
    }
}

@Suite("Device context")
struct ContextTests {
    let server = StubServer()
    let secure = MemorySecureStore()
    let persistence = MemoryPersistence()
    let clock = TestClock()
    let stub = StubContext()
    let key = "pk_test_abcdefghijklmnopqrstuvvd"

    static let updated = #"{"person":{"id":"per_1","level":"guest"},"rejected":[]}"#

    static func session(collect: String? = nil) -> String {
        guard let collect else { return Wire.session() }
        return String(Wire.session().dropLast()) + #","collect":\#(collect)}"#
    }

    static let healthOff = #"{"build":true,"display":true,"connection":true,"health":false,"notifications":true}"#

    /// `known`: the install already had a session answer that left every group on (most tests); false is a new
    /// install, whose switches the SDK doesn't know yet.
    func make(known: Bool = true) async -> (SessionStore, PatchCoalescer, ContextReporter) {
        if known, let data = try? WireJSON.encode(ContextCollection.all) { await persistence.write(Files.contextCollection, data) }
        let time = TimeSource(clock)
        let api = APIClient(
            baseURL: StubTransport.base, appKey: key, transport: StubTransport(server: server), cooldowns: CooldownBook(time: time))
        let reporter = ContextReporter(source: stub.source, persistence: persistence, time: time)
        let coalescer = PatchCoalescer(time: time, context: reporter)
        let store = SessionStore(api: api, secure: secure, time: time, profile: coalescer, context: reporter)
        let client = AuthorizedClient(api: api, authenticator: store)
        await coalescer.setSender { patch async throws(PingFrontError) in
            try await client.send(Endpoints.updateMe(patch), reason: .prepare)
        }
        return (store, coalescer, reporter)
    }

    func context(_ request: RecordedRequest?) -> [String: Any]? {
        (request?.json?["device"] as? [String: Any])?["context"] as? [String: Any]
    }

    /// Lets the 250 ms window elapse until `count` PATCHes went out.
    func flush(until count: Int) async -> Bool {
        for _ in 0..<40 {
            if await server.requests("PATCH me").count >= count { return true }
            clock.advance(by: Timing.patchWindow)
            await settle()
        }
        return await server.requests("PATCH me").count >= count
    }

    @Test("Session start carries every group in buckets, health without free storage")
    func createCarriesContext() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        let (store, _, _) = await make()
        _ = try await store.token(reason: .chatOpened)

        let context = try #require(context(await server.requests("POST sessions").first))
        #expect(context["build"] as? [String: AnyHashable] == ["installSource": "testflight", "debuggable": false])
        let display = try #require(context["display"] as? [String: Any])
        #expect(display["screenClass"] as? String == "compact" && display["textSize"] as? String == "large")
        #expect(display["languages"] as? [String] == ["en-GB", "de"])
        #expect(
            context["connection"] as? [String: AnyHashable] == [
                "network": "wifi", "constrained": false, "expensive": false, "lowPower": false,
            ])
        let health = try #require(context["health"] as? [String: AnyHashable])
        #expect(health == ["battery": 40, "charging": false, "thermal": "fair", "memoryPressure": "normal"])
        #expect(health["freeStorage"] == nil, "free disk space never leaves an iOS device")
        #expect(context["notifications"] as? [String: AnyHashable] == ["authorization": "provisional"])
    }

    @Test("A new install's first session carries no device context; after the answer, only the groups left on")
    func noContextBeforeTheSwitchesAreKnown() async throws {
        await server.on("POST sessions", .ok(Self.session(collect: Self.healthOff)))
        await server.on("PATCH me", .ok(#"{"person":{"id":"per_1","level":"guest"},"rejected":[]}"#))
        let (store, coalescer, reporter) = await make(known: false)
        _ = try await store.token(reason: .chatOpened)
        #expect(context(await server.requests("POST sessions").first) == nil, "context before the app's switches were known")
        #expect(await reporter.currentCollection()?.health == false)
        // The next request that goes out anyway carries the allowed groups, never health.
        await coalescer.stage(.traits(["plan": "pro"]))
        clock.advance(by: Timing.patchWindow)
        #expect(await eventually { await !server.requests("PATCH me").isEmpty })
        let patch = try #require(context(await server.requests("PATCH me").first))
        #expect(patch["build"] != nil && patch["display"] != nil)
        #expect(patch["health"] == nil)
    }

    @Test("The first request after a new install's answer is its session start: health goes with it when allowed")
    func firstRequestAfterTheAnswerStartsTheSession() async throws {
        let allOn = #"{"build":true,"display":true,"connection":true,"health":true,"notifications":true}"#
        await server.on("POST sessions", .ok(Self.session(collect: allOn)))
        await server.on("PATCH me", .ok(#"{"person":{"id":"per_1","level":"guest"},"rejected":[]}"#))
        let (store, coalescer, _) = await make(known: false)
        _ = try await store.token(reason: .chatOpened)
        #expect(context(await server.requests("POST sessions").first) == nil)
        await coalescer.stage(.traits(["plan": "pro"]))
        #expect(await flush(until: 1))
        let patch = try #require(context(await server.requests("PATCH me").first))
        #expect(patch["health"] != nil, "the first request after the answer counts as the session start")
        #expect(patch["build"] != nil && patch["connection"] != nil)
    }

    @Test("collect: health false is kept with the install and stops health on the next session")
    func collectStopsHealth() async throws {
        await server.on("POST sessions", .ok(Self.session(collect: Self.healthOff)))
        let (store, _, reporter) = await make(known: false)
        _ = try await store.token(reason: .chatOpened)
        #expect(context(await server.requests("POST sessions").first) == nil, "no group before the first answer")
        #expect(await reporter.currentCollection()?.health == false)
        #expect(await persistence.read(Files.contextCollection) != nil)

        // Logout, then a new session in this process.
        await store.wipe()
        _ = try await store.token(reason: .chatOpened)
        let second = try #require(context(await server.requests("POST sessions").last))
        #expect(second["health"] == nil)
        #expect(second["build"] != nil && second["connection"] != nil)

        // The next process reads the kept collection before any answer.
        let relaunched = ContextReporter(source: stub.source, persistence: persistence, time: TimeSource(clock))
        let draft = try #require(await relaunched.draft(for: .create))
        #expect(draft.context.health == nil && draft.context.build != nil)
    }

    @Test("A connection change rides on the next PATCH /me at most every 5 minutes and never sends on its own")
    func connectionCoalesced() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("PATCH me", .ok(Self.updated))
        let (store, coalescer, reporter) = await make()
        _ = try await store.token(reason: .chatOpened)
        #expect(await flush(until: 1) == false, "nothing was staged: no PATCH")

        // The network changes: nothing is sent for it, however long it waits.
        stub.setPath(ConnectionContext(network: .cellular, constrained: true, expensive: true))
        #expect(await eventually { await reporter.latestPath?.network == .cellular })
        clock.advance(by: .seconds(600))
        await settle()
        #expect(await server.requests.count == 1)

        // A trait change goes out anyway: the connection rides on it; health and unchanged groups do not.
        await coalescer.stage(.traits(["plan": "pro"]))
        #expect(await flush(until: 1))
        let first = try #require(context(await server.requests("PATCH me").last))
        #expect(
            first["connection"] as? [String: AnyHashable] == [
                "network": "cellular", "constrained": true, "expensive": true, "lowPower": false,
            ])
        #expect(first["health"] == nil && first["build"] == nil && first["display"] == nil && first["notifications"] == nil)
        #expect((await server.requests("PATCH me").last?.json?["traits"] as? [String: String]) == ["plan": "pro"])

        // Another change within 5 minutes waits, even though a PATCH goes out.
        stub.setPath(ConnectionContext(network: .wifi, constrained: false, expensive: false))
        #expect(await eventually { await reporter.latestPath?.network == .wifi })
        await coalescer.stage(.traits(["plan": "max"]))
        #expect(await flush(until: 2))
        let patch = try #require(await server.requests("PATCH me").last?.json)
        #expect(context(await server.requests("PATCH me").last) == nil)
        #expect(patch["device"] == nil, "a PATCH without context carries no device facts")

        // After 5 minutes the next PATCH carries it.
        clock.advance(by: .seconds(300))
        await coalescer.stage(.traits(["plan": "pro"]))
        #expect(await flush(until: 3))
        #expect((context(await server.requests("PATCH me").last)?["connection"] as? [String: Any])?["network"] as? String == "wifi")
        let sessions = await server.requests("POST sessions").count
        let all = await server.requests.count
        #expect(sessions == 1 && all == 4)
    }

    @Test("Health goes out with the first refresh in a process, not with later refreshes")
    func refreshHealthOnce() async throws {
        let stored = InstallCredentials(installId: "11111111-2222-4333-8444-555555555555", installSecret: "sec_old")
        try await secure.write(SecureKeys.credentials, try JSONEncoder().encode(stored))
        await server.on(
            "POST sessions/refresh", .ok(Wire.refresh(token: "tok_a", expiresIn: 120)),
            .ok(Wire.refresh(token: "tok_b", expiresIn: 3600)))
        let (store, _, _) = await make()
        _ = try await store.token(reason: .chatOpened)
        let first = try #require(context(await server.requests("POST sessions/refresh").first))
        #expect(first["health"] != nil && first["build"] != nil && first["connection"] != nil)

        clock.advance(by: .seconds(120))
        _ = try await store.token(reason: .chatOpened)
        let refreshes = await server.requests("POST sessions/refresh")
        #expect(refreshes.count == 2)
        #expect(context(refreshes.last) == nil, "nothing changed and health is session start only")
    }

    @Test("A failed request does not count as sent: the next one carries the context again")
    func failedNotSent() async throws {
        await server.on("POST sessions", .json(500, Wire.error("internal")), .ok(Wire.session()))
        let (store, _, _) = await make()
        await #expect(throws: PingFrontError.self) { _ = try await store.token(reason: .chatOpened) }
        _ = try? await store.token(reason: .chatOpened)
        let requests = await server.requests("POST sessions")
        #expect(requests.count == 2)
        #expect(context(requests.last)?["health"] != nil)
    }

    @Test("Logout stops the path monitor")
    func logoutStopsMonitor() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        let (store, _, _) = await make()
        #expect(stub.monitors == 0, "no monitor before a session")
        _ = try await store.token(reason: .chatOpened)
        #expect(stub.monitors == 1)
        await store.wipe()
        #expect(await eventually { stub.monitors == 0 })
    }

    @Test("Unknown enum values decode to unknown and are never encoded")
    func unknownValues() throws {
        let json = #"""
            {"build":{"installSource":"alt_store"},"display":{"screenClass":"huge","textSize":"tiny"},
             "connection":{"network":"satellite"},"health":{"freeStorage":"lots","thermal":"molten","memoryPressure":"extreme"},
             "notifications":{"authorization":"maybe"},"future":{"x":1}}
            """#
        let context = try WireJSON.decode(DeviceContext.self, from: Data(json.utf8))
        #expect(context.build?.installSource == .unknown)
        #expect(context.display?.screenClass == .unknown && context.display?.textSize == .unknown)
        #expect(context.connection?.network == .unknown)
        #expect(
            context.health?.freeStorage == .unknown && context.health?.thermal == .unknown
                && context.health?.memoryPressure == .unknown)
        #expect(context.notifications?.authorization == .unknown)
        let encoded = try #require(try JSONSerialization.jsonObject(with: WireJSON.encode(context)) as? [String: [String: Any]])
        let allEmpty = encoded.values.allSatisfy { $0.isEmpty }
        #expect(allEmpty, "unknown values are never sent")

        let session = try WireJSON.decode(CreateSessionResponse.self, from: Data(Self.session(collect: Self.healthOff).utf8))
        #expect(session.collect?.health == false && session.collect?.build == true)
        #expect(try WireJSON.decode(CreateSessionResponse.self, from: Data(Wire.session().utf8)).collect == nil)
        let refresh = String(Wire.refresh().dropLast()) + #","collect":\#(Self.healthOff)}"#
        #expect(try WireJSON.decode(RefreshSessionResponse.self, from: Data(refresh.utf8)).collect?.health == false)
    }

    @Test("Buckets: battery rounds down to 10, languages keep the first three valid tags")
    func buckets() {
        #expect(HealthContext.batteryBucket(0.47) == 40)
        #expect(HealthContext.batteryBucket(1) == 100)
        #expect(HealthContext.batteryBucket(0.09) == 0)
        #expect(HealthContext.batteryBucket(-1) == nil)
        #expect(DisplayContext.languages(from: ["en-GB", "x", "zh-Hans-CN", "de", "fr"]) == ["en-GB", "zh-Hans-CN", "de"])
        #expect(DisplayContext.languages(from: ["en_US", "de-DE-x-averyveryverylong"]) == [])
    }
}

@Suite("System context readers")
struct SystemContextTests {
    final class Flag: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)
        var isSet: Bool { state.withLock { $0 } }
        func set() { state.withLock { $0 = true } }
    }

    @Test("NWPathMonitor delivers the current path at once, and cancelling the consumer stops its iteration")
    func pathMonitorCancels() async {
        let ended = Flag()
        let received = Flag()
        let stream = SystemContext.paths(ended: { ended.set() })
        let consumer = Task {
            for await path in stream where path.network != nil { received.set() }
        }
        #expect(await eventually { received.isSet })
        #expect(!ended.isSet)
        consumer.cancel()
        #expect(await eventually { ended.isSet }, "the monitor kept running after its consumer was cancelled")
    }
}

@Suite("Device context at launch")
@MainActor
struct ContextLaunchTests {
    @Test("configure reads no context and sends nothing")
    func quietLaunch() async {
        let server = StubServer()
        let stub = StubContext()
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(TestClock()), context: stub.source)
        facade.start(appKey: "pk_test_abcdefghijklmnopqrstuvvd", configuration: configuration)
        Retain.keep(facade)
        await settle()
        #expect(await server.requests.isEmpty)
        #expect(stub.reads == 0)
        #expect(stub.monitors == 0)
    }
}
