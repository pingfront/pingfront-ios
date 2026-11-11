import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// The client side of the protocol's pre-release hardening (part of 1.0.0), one test per item.
@Suite("Protocol 1.0.0 hardening")
struct ProtocolHardeningTests {
    let server = StubServer()
    let secure = MemorySecureStore()
    let clock = TestClock()
    /// Engines hold their facade unowned (the facade owns the engine); keep facades alive for the whole test.
    let keepAlive = KeepAlive()
    static let key = "pk_test_abcdefghijklmnopqrstuvvd"
    static let installId = "8b0a3c9e-4f61-4e7a-9d2c-1f5e6a7b8c9d"

    func makeStore() -> (SessionStore, PatchCoalescer, AuthorizedClient) {
        let time = TimeSource(clock)
        let api = APIClient(
            baseURL: StubTransport.base, appKey: Self.key, transport: StubTransport(server: server), cooldowns: CooldownBook(time: time))
        let coalescer = PatchCoalescer(time: time)
        let store = SessionStore(api: api, secure: secure, time: time, profile: coalescer)
        return (store, coalescer, AuthorizedClient(api: api, authenticator: store))
    }

    @MainActor
    func makeEngine() throws -> (PingFront, Engine) {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let dependencies = Dependencies(
            transport: StubTransport(server: server), secure: secure, persistence: MemoryPersistence(), time: TimeSource(clock))
        let engine = Engine(facade: facade, key: try AppKey.parse(Self.key).get(), configuration: configuration, dependencies: dependencies)
        facade.engine = engine
        Retain.keep(facade)
        keepAlive.objects.append(facade)
        return (facade, engine)
    }

    func storeCredentials(_ id: String = installId, secret: String = "sec_old") async throws {
        try await secure.write(SecureKeys.credentials, try JSONEncoder().encode(InstallCredentials(installId: id, installSecret: secret)))
    }

    // 1. Identify yourself

    @Test("1. Every request carries PF-SDK and PF-Protocol, with or without a bearer token")
    func identifyHeaders() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET unread", .ok(#"{"unread":2,"lastSeq":4,"live":false}"#))
        let (store, _, api) = makeStore()
        defer { withExtendedLifetime(store) {} }
        _ = try await api.send(Endpoints.unread())
        let requests = await server.requests
        #expect(requests.map { "\($0.method) \($0.path)" } == ["POST sessions", "GET unread"])
        for request in requests {
            #expect(request.headers["PF-SDK"] == "pingfront-ios/\(PingFrontVersion.current)")
            #expect(request.headers["PF-Protocol"] == PingFrontVersion.protocolVersion)
        }
        #expect(requests[0].headers["Authorization"] == nil)
        #expect(requests[1].headers["Authorization"] == "Bearer tok_1")
    }

    // 2. Session lifetime

    @Test("2. Refresh is scheduled from accessExpiresIn, not the device clock")
    func skewSafeExpiry() async throws {
        // The device clock is far off: accessExpiresAt is already in the past here, but the server says 1 hour.
        await server.on("POST sessions", .ok(Wire.session(token: "tok_1", expiresIn: 3600, expiresAt: "2001-01-01T00:00:00Z")))
        await server.on("POST sessions/refresh", .ok(Wire.refresh(token: "tok_2", expiresIn: 3600)))
        let (store, _, _) = makeStore()
        #expect(try await store.token(reason: .prepare) == "tok_1")
        clock.advance(by: .seconds(3600 - 61))
        #expect(try await store.token(reason: .prepare) == "tok_1", "refreshed early because of the device clock")
        clock.advance(by: .seconds(2))
        #expect(try await store.token(reason: .prepare) == "tok_2", "did not refresh within 60 s of expiry")
    }

    @Test("2. Any 401 unauthorized refreshes once and retries the request once")
    func generic401Retry() async throws {
        try await storeCredentials()
        await server.on("POST sessions/refresh", .ok(Wire.refresh(token: "tok_a")), .ok(Wire.refresh(token: "tok_b")))
        await server.on("GET thread/messages", .json(401, Wire.error("unauthorized")), .ok(#"{"messages":[],"hasMore":false}"#))
        let (store, _, api) = makeStore()
        defer { withExtendedLifetime(store) {} }
        let page = try await api.send(Endpoints.messages(after: 0, limit: 10))
        #expect(page.messages.isEmpty)
        let calls = await server.requests("GET thread/messages")
        #expect(calls.map { $0.headers["Authorization"] } == ["Bearer tok_a", "Bearer tok_b"])
        #expect(await server.requests("POST sessions/refresh").count == 2)
    }

    @Test("2. A second 401 is surfaced, not retried forever")
    func second401Surfaces() async throws {
        try await storeCredentials()
        await server.on("POST sessions/refresh", .ok(Wire.refresh(token: "tok_a")), .ok(Wire.refresh(token: "tok_b")))
        await server.on("GET unread", .json(401, Wire.error("unauthorized")))
        let (store, _, api) = makeStore()
        defer { withExtendedLifetime(store) {} }
        await #expect(throws: PingFrontError.self) { _ = try await api.send(Endpoints.unread()) }
        #expect(await server.requests("GET unread").count == 2)
    }

    @Test("2. Refresh carries device facts and returns testDevice and storeAccountToken")
    func refreshCarriesDevice() async throws {
        try await storeCredentials()
        await server.on(
            "POST sessions/refresh",
            .ok(
                #"{"accessToken":"tok_r","accessExpiresAt":"2099-01-01T00:00:00Z","accessExpiresIn":900,"person":{"id":"per_1","level":"guest"},"testDevice":true,"storeAccountToken":"5f0c7a52-9a5e-4c55-8f53-0c9d2a1b3e4f"}"#
            ))
        let (store, _, _) = makeStore()
        _ = try await store.token(reason: .chatOpened)
        let body = try #require(await server.requests("POST sessions/refresh").first?.json)
        let device = try #require(body["device"] as? [String: Any])
        #expect(device["installId"] as? String == Self.installId)
        #expect(device["timeZone"] as? String == TimeZone.current.identifier)
        #expect(await store.testDevice)
        #expect(await store.storeAccountToken == "5f0c7a52-9a5e-4c55-8f53-0c9d2a1b3e4f")
    }

    @Test("2. Device facts that changed go out in PATCH /me; unchanged facts do not")
    func deviceInPatch() async throws {
        try await storeCredentials()
        await server.on("POST sessions/refresh", .ok(Wire.refresh()))
        let (store, coalescer, _) = makeStore()
        _ = try await store.token(reason: .chatOpened)
        let same = try #require(await store.currentDevice())
        await coalescer.stage(.device(same))
        #expect(await coalescer.pendingPatch().isEmpty)
        var travelled = same
        travelled.timeZone = "Asia/Tokyo"
        await coalescer.stage(.device(travelled))
        #expect(await coalescer.pendingPatch().device?.timeZone == "Asia/Tokyo")
    }

    @Test("2. The session's installId is adopted; re-registering a known install sends its installSecret")
    func installIdAdoption() async throws {
        try await storeCredentials(secret: "sec_known")
        let minted = "1d6b2c3a-7e8f-4a9b-8c0d-2e3f4a5b6c7d"
        await server.on("POST sessions/refresh", .json(401, Wire.error("unauthorized")))
        await server.on("POST sessions", .ok(Wire.session(secret: "sec_new", installId: minted)))
        let (store, _, _) = makeStore()
        _ = try await store.token(reason: .chatOpened)
        let create = try #require(await server.requests("POST sessions").first?.json)
        #expect(create["installSecret"] as? String == "sec_known")
        #expect((create["device"] as? [String: Any])?["installId"] as? String == Self.installId)
        let stored = try #require(await SessionStore.credentialsFile(secure).load())
        #expect(stored == InstallCredentials(installId: minted, installSecret: "sec_new"))
    }

    // 3. Draft looks

    @Test("3. Test devices fetch ?draft=1 with their bearer token; others use the key only, with ETag")
    func draftConfigUsesBearer() async throws {
        let config = try String(decoding: fixture("config-full.json"), as: UTF8.self)
        await server.on("POST sessions", .ok(Wire.session(token: "tok_t")))
        await server.on("GET config", .json(200, config, headers: ["ETag": "\"r1\""]), .json(304, ""))
        let (store, _, api) = makeStore()
        defer { withExtendedLifetime(store) {} }
        let configStore = ConfigStore(client: api, persistence: MemoryPersistence(), time: TimeSource(clock))
        _ = await configStore.refresh(testDevice: false, force: true)
        _ = await configStore.refresh(testDevice: false, force: true)
        _ = await configStore.refresh(testDevice: true, force: true)
        let calls = await server.requests("GET config")
        #expect(calls.map { $0.query["draft"] } == [nil, nil, "1"])
        #expect(calls.map { $0.headers["Authorization"] } == [nil, nil, "Bearer tok_t"])
        #expect(calls[1].headers["If-None-Match"] == "\"r1\"")
        #expect(calls[2].headers["If-None-Match"] == nil)
    }

    // 4. ChatLook without defaults on the wire

    @Test("4. Each look field resolves on its own: dashboard, then code, then host app, then defaults")
    @MainActor func perFieldLook() throws {
        var remote = try WireJSON.decode(AppConfig.self, from: fixture("config-full.json"))
        remote.look = try WireJSON.decode(ChatLook.self, from: Data(##"{"theme":{"accent":{"light":"#0F766E","dark":"#2DD4BF"}}}"##.utf8))
        var code = ChatAppearance()
        code.corners = .soft
        code.accent = PingFrontColor(light: "#FF0000", dark: "#FF0000")
        let host = HostAppInfo(
            appName: "Clockwise", accent: PingFrontColor(light: "#00FF00", dark: "#00FF00"), iconPNG: nil, appVersion: "1")
        let look = ResolvedLook.resolve(remote: remote, code: code, codeTopics: nil, host: host)
        #expect(look.corners == .soft, "code config lost to a default")
        #expect(look.density == .comfortable)
        #expect(look.headerStyle == .person)
        let noRemote = ResolvedLook.resolve(remote: nil, code: ChatAppearance(), codeTopics: nil, host: host)
        let hostOnly = ResolvedLook.resolve(remote: nil, code: ChatAppearance(), codeTopics: nil, host: nil)
        #expect(noRemote.accent != hostOnly.accent, "host accent was not used before the default")
    }

    // 5. Thread consistency

    @Test("5. hello carries teamReadSeq and status; a new rev in hello reloads the thread")
    @MainActor func helloThreadState() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on(
            "GET thread",
            .ok(
                #"{"thread":{"id":"thr_1","status":"open","lastSeq":0,"readSeq":0,"teamReadSeq":0,"unread":0,"rev":3},"messages":[],"hasOlder":false,"team":[],"policy":{"canSend":true}}"#
            ))
        let (facade, engine) = try makeEngine()
        await engine.loadThread()
        await engine.apply(.hello(lastSeq: 0, readSeq: 0, teamReadSeq: 5, rev: 3, status: .resolved))
        #expect(facade.conversation.teamReadSeq == 5)
        #expect(facade.conversation.status == .resolved)
        #expect(await server.requests("GET thread").count == 1)
        facade.conversation.draft = "unsent words"
        await engine.apply(.hello(lastSeq: 0, readSeq: 0, teamReadSeq: nil, rev: 4, status: nil))
        #expect(await server.requests("GET thread").count == 2, "a changed rev did not reload")
        #expect(facade.conversation.draft == "unsent words")
    }

    @Test("A late no-thread hello never resets a thread learned from a first send, and 0 is never stored")
    @MainActor func helloWithoutThread() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST thread/messages", .json(201, Wire.message(clientId: "c1"), headers: ["PF-Thread-Rev": "1"]))
        let (_, engine) = try makeEngine()
        // A real first send: the thread and its revision exist only from this answer's header.
        _ = try await engine.client.send(
            Endpoints.sendMessage(SendMessageRequest(clientId: "c1", text: "Hi", attachmentIds: nil, replyToCard: nil)),
            reason: .chatOpened)
        #expect(await engine.api.threadRevision.value == 1)
        // The socket's hello was written before that send: no thread yet. It is late, not news.
        await engine.apply(.hello(lastSeq: 0, readSeq: 0, rev: 0))
        #expect(await server.requests("GET thread").isEmpty, "a late hello cost a reload")
        #expect(await engine.api.threadRevision.value == 1)
        // Before anyone writes, 0 is not a revision to send.
        let (_, fresh) = try makeEngine()
        await fresh.apply(.hello(lastSeq: 0, readSeq: 0, rev: 0))
        #expect(await fresh.api.threadRevision.value == nil)
    }

    @Test("5. ThreadResponse teamReadSeq feeds the Read receipt")
    @MainActor func threadTeamReadSeq() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on(
            "GET thread",
            .ok(
                #"{"thread":{"id":"thr_1","status":"resolved","lastSeq":2,"readSeq":2,"teamReadSeq":2,"unread":0,"rev":1},"messages":[],"hasOlder":false,"team":[],"policy":{"canSend":true}}"#
            ))
        let (facade, engine) = try makeEngine()
        await engine.loadThread()
        #expect(facade.conversation.teamReadSeq == 2)
        #expect(facade.conversation.status == .resolved)
    }

    // 6. Code points

    @Test("6. Limits count Unicode code points, as the server does")
    func codePoints() {
        #expect(TextLimit.count("👍🏽") == 2)
        #expect(TextLimit.count("e\u{301}") == 2)
        #expect(TextLimit.count("日本") == 2)
        #expect(TextLimit.remaining(String(repeating: "👍🏽", count: 2000)) == 0)
        #expect(TextLimit.remaining(String(repeating: "👍🏽", count: 2001)) == -2)
    }

    @Test("6. A report over the limit is refused, not truncated, and nothing is sent")
    @MainActor func reportOverLimit() async throws {
        let (facade, _) = try makeEngine()
        await #expect(throws: PingFrontError.invalidInput("The report is longer than 4000 characters.")) {
            try await facade.reportBug(text: String(repeating: "a", count: 4001))
        }
        #expect(await server.requests.isEmpty)
    }

    // 7. Partial PATCH

    @Test(
        "7. rejected[] fields leave the pending patch and are not retried; the rest stays applied",
        .timeLimit(.minutes(1)))
    func rejectedFields() async throws {
        let (coalescer, sent) = await makeCoalescer(replies: [
            UpdateMeResponse(
                person: PersonSummary(id: "p", level: .guest, name: nil),
                rejected: [RejectedField(field: "traits.plan", code: "too_long", message: "x")])
        ])
        var responses = coalescer.responseStream.makeAsyncIterator()
        await coalescer.stage(.traits(["plan": String(repeating: "x", count: 10), "city": "Izmir"]))
        // The flush timer must be asleep before time moves, or it sleeps from the later instant and never fires.
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(250))
        // The coalescer applies the answer after the sender returns: wait for the answer, not for the request
        // (the request is recorded before the answer arrives, so checking then races the coalescer).
        #expect(await responses.next()?.rejected.map(\.field) == ["traits.plan"])
        #expect(await sent.count == 1)
        #expect(await coalescer.pendingPatch().isEmpty)
        clock.advance(by: .seconds(5))
        await settle()
        #expect(await sent.count == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test("7. A 422 with fields[] drops those fields and sends the rest")
    func invalidFieldsDropped() async throws {
        let failure = PingFrontError.server(
            ServerError(
                status: 422, code: .invalidRequest, message: "bad", docs: nil, retryAfter: nil, scope: nil, fields: ["identity.email"]))
        let (coalescer, sent) = await makeCoalescer(replies: [], failFirst: failure)
        await coalescer.stage(.identity(Identity(userId: "u", name: nil, email: "not-an-email", token: nil)))
        await coalescer.stage(.traits(["plan": "pro"]))
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(250))
        #expect(await eventually { await sent.count == 1 })
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(250))
        #expect(await eventually { await sent.count == 2 })
        let second = try #require(await sent.patches.last)
        #expect(second.identity == nil)
        #expect(second.traits == ["plan": "pro"])
    }

    @Test("7. Traits are capped at 30 keys client-side; existing keys still update")
    func traitCap() {
        var profile = Profile()
        profile.apply(.traits(Dictionary(uniqueKeysWithValues: (0..<35).map { (String(format: "k%02d", $0), "v") })))
        #expect(profile.traits.count == 30)
        profile.apply(.traits(["k00": "updated", "new": "x"]))
        #expect(profile.traits["k00"] == "updated")
        #expect(profile.traits["new"] == nil)
    }

    // 8. Uploads

    @Test("8. Uploads send a requestId that is stable for the same outbox photo")
    func uploadRequestId() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on(
            "POST uploads", .ok(#"{"attachmentId":"att_1","putUrl":"https://put.test/x","headers":{},"expiresAt":"2099-01-01T00:00:00Z"}"#))
        let (store, _, api) = makeStore()
        defer { withExtendedLifetime(store) {} }
        let uploader = Uploader(client: api, time: TimeSource(clock))
        let id = StableID.uuid(from: "c-1/outbox-c-1-0.jpg")
        _ = try? await uploader.upload(Data([1]), width: 1, height: 1, sha256: "x", requestId: id)
        #expect(await server.requests("POST uploads").first?.json?["requestId"] as? String == id)
        #expect(StableID.uuid(from: "c-1/outbox-c-1-0.jpg") == id)
        #expect(id.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil)
    }

    // 9. Store

    @Test("9. Store detections go out only for listened store events, with the signed transaction")
    @MainActor func storeEvents() async throws {
        await server.on("GET moments/listened", .ok(#"{"names":["paywall_closed"],"storeEvents":["trial_started"]}"#))
        await server.on("POST sessions", .ok(Wire.session(storeAccountToken: "5f0c7a52-9a5e-4c55-8f53-0c9d2a1b3e4f")))
        await server.on("POST moments", .ok(#"{"outcome":"scheduled","open":false}"#))
        let (facade, engine) = try makeEngine()
        engine.start()
        defer { engine.stop() }
        let ignored = await engine.storeEvent(StoreEventReport(name: "refunded", productId: "pro", occurredAt: .now))
        #expect(ignored == .notListened)
        let report = StoreEventReport(
            name: "trial_started", productId: "pro_yearly", transactionId: "2000001", originalTransactionId: "2000001", price: "0",
            currency: "USD", signedTransaction: "eyJhbGciOi.jws.sig", occurredAt: .now)
        #expect(await engine.storeEvent(report) == .scheduled)
        let body = try #require(await server.requests("POST moments").first?.json)
        #expect(body["name"] as? String == "trial_started")
        let store = try #require(body["store"] as? [String: Any])
        #expect(store["signedTransaction"] as? String == "eyJhbGciOi.jws.sig")
        #expect(store["productId"] as? String == "pro_yearly")
        #expect(body["clientId"] as? String == report.clientId)
        #expect(await eventually { @MainActor in facade.storeAccountToken == UUID(uuidString: "5f0c7a52-9a5e-4c55-8f53-0c9d2a1b3e4f") })
    }

    // 10. Push

    @Test("10. Push payloads: v1 known kinds parse; other versions and kinds are ignored")
    func pushPayloads() {
        let message = PushPayload(userInfo: ["pingfront": ["v": 1, "kind": "message", "appId": "app_1", "threadId": "thr_1", "unread": 3]])
        #expect(message?.kind == .message)
        #expect(message?.unread == 3)
        #expect(PushPayload(userInfo: ["pingfront": ["v": 1, "kind": "fireworks", "appId": "app_1"]]) == nil)
        #expect(PushPayload(userInfo: ["pingfront": ["v": 2, "kind": "message", "appId": "app_1"]]) == nil)
        #expect(PushPayload(userInfo: ["aps": ["alert": "hi"]]) == nil)
        #expect(PushPayload.isPingFront(["pingfront": ["v": 2]]))
    }

    @MainActor
    @Test("10. A push in the foreground updates unread; handlePush ignores unknown kinds; no badge by default")
    func pushUnread() async throws {
        let (facade, _) = try makeEngine()
        facade.pushReceived(userInfo: ["pingfront": ["v": 1, "kind": "message", "appId": "app_1", "unread": 4]])
        #expect(facade.unreadCount == 4)
        #expect(facade.handlePush(userInfo: ["pingfront": ["v": 1, "kind": "fireworks", "appId": "app_1"]]))
        #expect(!facade.handlePush(userInfo: ["aps": [:]]))
        #expect(!facade.usesAppBadge)
    }

    // 11. Unknown content

    @Test("11. Messages decode fallback text and the structured ping reason")
    func fallbackAndReason() throws {
        let json =
            #"{"id":"m1","seq":1,"author":{"kind":"team","name":"Deniz"},"parts":[{"type":"hologram","x":1}],"createdAt":"2026-10-30T18:00:00Z","fallback":"Your trial ends tomorrow","ping":{"kind":"play","explanation":"Gönderildi","reason":{"code":"store_event","params":{"event":"trial_expired"}}}}"#
        let message = try WireJSON.decode(Message.self, from: Data(json.utf8))
        #expect(message.fallback == "Your trial ends tomorrow")
        #expect(message.parts == [.unknown(type: "hologram")])
        #expect(message.ping?.reason?.code == .storeEvent)
        #expect(message.ping?.reason?.params?["event"] == "trial_expired")
        let future = try WireJSON.decode(PingReason.self, from: Data(#"{"code":"lunar"}"#.utf8))
        #expect(future.code == .unknown)
    }

    // 12. Paused apps

    @Test("12. policy.reason app_paused reaches the conversation (the composer shows the paused notice)")
    @MainActor func pausedPolicy() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on(
            "GET thread", .ok(#"{"thread":null,"messages":[],"hasOlder":false,"team":[],"policy":{"canSend":false,"reason":"app_paused"}}"#)
        )
        let (facade, engine) = try makeEngine()
        await engine.loadThread()
        #expect(facade.conversation.policy == SendPolicy.closed(.appPaused))
    }

    // 13. Erase

    @Test("13. eraseMyData wipes locally after 204, and after an already-done erase on retry")
    @MainActor func eraseIdempotent() async throws {
        try await storeCredentials()
        await server.on("DELETE me", .json(404, Wire.error("not_found")))
        let (facade, _) = try makeEngine()
        facade.conversation.draft = "secret"
        try await facade.eraseMyData()
        #expect(try await secure.read(SecureKeys.credentials) == nil)
        #expect(facade.conversation.draft.isEmpty)
        #expect(await server.requests("DELETE me").first?.headers["Authorization"] == nil)
    }

    // Export

    static let exportBody =
        #"{"format":"pingfront.person.v1","exportedAt":"2026-10-31T10:00:00Z","app":{"id":"app_1","name":"Clockwise"},"person":{}}"#

    @Test("exportMyData returns the server's PersonExport bytes unchanged, sent with the bearer token")
    @MainActor func exportReturnsRawJSON() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET me/export", .ok(Self.exportBody))
        let (facade, _) = try makeEngine()
        let data = try await facade.exportMyData()
        #expect(data == Data(Self.exportBody.utf8))
        let request = try #require(await server.requests("GET me/export").first)
        #expect(request.headers["Authorization"]?.hasPrefix("Bearer ") == true)
        #expect(await server.requests("POST sessions").count == 1)
    }

    @Test("exportMyData: a 429 names scope exports, then only exports cools down")
    @MainActor func exportRateLimited() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET me/export", .json(429, Wire.error("rate_limited", retryAfter: 600, scope: "exports")))
        await server.on("GET unread", .ok(#"{"unread":0,"lastSeq":0,"live":false}"#))
        let (facade, engine) = try makeEngine()
        do {
            _ = try await facade.exportMyData()
            Issue.record("expected 429")
        } catch {
            #expect(error.code == .rateLimited)
            guard case .server(let envelope) = error else { throw error }
            #expect(envelope.scope == .exports)
        }
        await #expect(throws: PingFrontError.coolingDown(scope: .exports, remaining: .seconds(600))) {
            _ = try await facade.exportMyData()
        }
        #expect(await server.requests("GET me/export").count == 1)
        // Other routes keep working.
        _ = try await engine.client.send(Endpoints.unread())
        #expect(await server.requests("GET unread").count == 1)
    }

    @Test("exportMyData rejects a body that is not an export")
    @MainActor func exportRejectsGarbage() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET me/export", .ok(#"[1,2]"#))
        let (facade, _) = try makeEngine()
        await #expect(throws: PingFrontError.invalidResponse("Unexpected response from the server")) {
            _ = try await facade.exportMyData()
        }
    }

    @Test("exportMyData before configure throws notConfigured")
    @MainActor func exportNotConfigured() async {
        await #expect(throws: PingFrontError.notConfigured) { _ = try await PingFront().exportMyData() }
    }

    // Helpers

    actor SentPatches {
        var patches: [UpdateMeRequest] = []
        var count: Int { patches.count }
        func add(_ patch: UpdateMeRequest) { patches.append(patch) }
    }

    func makeCoalescer(replies: [UpdateMeResponse], failFirst: PingFrontError? = nil) async -> (PatchCoalescer, SentPatches) {
        let coalescer = PatchCoalescer(time: TimeSource(clock))
        let sent = SentPatches()
        let queue = ReplyQueue(replies: replies, failFirst: failFirst)
        await coalescer.setSender { patch async throws(PingFrontError) in
            await sent.add(patch)
            // A network round trip: other work runs between the request going out and its answer.
            return try await queue.next()
        }
        await coalescer.activate()
        return (coalescer, sent)
    }

    actor ReplyQueue {
        var replies: [UpdateMeResponse]
        var failFirst: PingFrontError?
        init(replies: [UpdateMeResponse], failFirst: PingFrontError?) {
            self.replies = replies
            self.failFirst = failFirst
        }
        func next() throws(PingFrontError) -> UpdateMeResponse {
            if let failure = failFirst {
                failFirst = nil
                throw failure
            }
            return replies.isEmpty ? UpdateMeResponse(person: PersonSummary(id: "p", level: .guest, name: nil)) : replies.removeFirst()
        }
    }
}

@MainActor final class KeepAlive: Sendable {
    var objects: [AnyObject] = []
    nonisolated init() {}
}
