import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

@Suite("Session store")
struct SessionTests {
    let server = StubServer()
    let secure = MemorySecureStore()
    let clock = TestClock()
    let key = "pk_test_abcdefghijklmnopqrstuvvd"

    func makeStore() -> (SessionStore, PatchCoalescer) {
        let time = TimeSource(clock)
        let api = APIClient(
            baseURL: StubTransport.base, appKey: key, transport: StubTransport(server: server), cooldowns: CooldownBook(time: time))
        let coalescer = PatchCoalescer(time: time)
        let store = SessionStore(api: api, secure: secure, time: time, profile: coalescer)
        return (store, coalescer)
    }

    func storedCredentials() async throws -> InstallCredentials {
        try #require(await SessionStore.credentialsFile(secure).load())
    }

    @Test("Creates a session lazily with device, identity and reason; stores the secret; reuses the token")
    func create() async throws {
        await server.on("POST sessions", .ok(Wire.session(token: "tok_1", secret: "sec_1")))
        let (store, coalescer) = makeStore()
        #expect(await server.requests.isEmpty)
        await coalescer.stage(.identity(Identity(userId: "u_42", name: "Ada", email: "ada@example.com", token: nil)))
        await coalescer.stage(.traits(["plan": "pro"]))

        let token = try await store.token(reason: .chatOpened)
        #expect(token == "tok_1")
        let again = try await store.token(reason: .chatOpened)
        #expect(again == "tok_1")

        let requests = await server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST" && request.path == "sessions")
        #expect(request.headers["PF-App-Key"] == key)
        #expect(request.headers["Authorization"] == nil)
        let body = try #require(request.json)
        #expect(body["reason"] as? String == "chat_opened")
        let device = try #require(body["device"] as? [String: Any])
        let installId = try #require(device["installId"] as? String)
        #expect(UUID(uuidString: installId) != nil && installId == installId.lowercased())
        #expect((body["identity"] as? [String: Any])?["userId"] as? String == "u_42")
        #expect((body["traits"] as? [String: String]) == ["plan": "pro"])

        let credentials = try await storedCredentials()
        #expect(credentials.installId == installId && credentials.installSecret == "sec_1")
        #expect(await store.isActive)
        #expect(await store.person?.id == "per_1")
        // Everything went out with the session; nothing is left to PATCH.
        #expect(await coalescer.pendingPatch().isEmpty)
    }

    @Test("Refreshes with stored credentials instead of creating a session")
    func refresh() async throws {
        let stored = InstallCredentials(installId: "11111111-2222-4333-8444-555555555555", installSecret: "sec_old")
        try await secure.write(SecureKeys.credentials, try JSONEncoder().encode(stored))
        await server.on("POST sessions/refresh", .ok(Wire.refresh(token: "tok_r")))
        let (store, _) = makeStore()
        #expect(await store.hasInstall())

        #expect(try await store.token(reason: .chatOpened) == "tok_r")
        let requests = await server.requests
        #expect(requests.map(\.path) == ["sessions/refresh"])
        let body = try #require(requests.first?.json)
        #expect(body["installId"] as? String == stored.installId)
        #expect(body["installSecret"] as? String == "sec_old")
        #expect(await store.person?.level == .named)
    }

    @Test("session_revoked on refresh wipes local credentials, fails that call, and the next one starts a new guest install")
    func revoked() async throws {
        let stored = InstallCredentials(installId: "11111111-2222-4333-8444-555555555555", installSecret: "sec_old")
        try await secure.write(SecureKeys.credentials, try JSONEncoder().encode(stored))
        await server.on("POST sessions/refresh", .json(401, Wire.error("session_revoked")))
        await server.on("POST sessions", .ok(Wire.session(token: "tok_new", secret: "sec_new")))
        let (store, coalescer) = makeStore()
        await coalescer.stage(.traits(["kept": "yes"]))

        // No retry: the call that met the revocation fails, and nothing else is sent.
        await #expect(throws: PingFrontError.self) { try await store.token(reason: .chatOpened) }
        #expect(await server.requests("POST sessions").isEmpty)
        #expect(try await store.token(reason: .chatOpened) == "tok_new")

        var iterator = store.events.makeAsyncIterator()
        #expect(await iterator.next() == .revoked)
        if case .started = await iterator.next() {} else { Issue.record("expected .started after .revoked") }

        let create = try #require(await server.requests("POST sessions").first?.json)
        let newInstallId = try #require((create["device"] as? [String: Any])?["installId"] as? String)
        #expect(newInstallId != stored.installId)
        // Staged traits survive a revocation; they belong to the app, not the install.
        #expect((create["traits"] as? [String: String]) == ["kept": "yes"])
        let credentials = try await storedCredentials()
        #expect(credentials.installId == newInstallId && credentials.installSecret == "sec_new")
    }

    @Test("Concurrent token requests share one session request")
    func singleFlight() async throws {
        await server.on("POST sessions", .delayed(.milliseconds(50), StubReplyBox(.ok(Wire.session()))))
        let (store, _) = makeStore()
        async let first = store.token(reason: .chatOpened)
        async let second = store.token(reason: .moment)
        async let third = store.token(reason: .prepare)
        let tokens = try await [first, second, third]
        #expect(Set(tokens) == ["tok_1"])
        #expect(await server.requests("POST sessions").count == 1)
    }

    @Test("Network failures surface as typed errors and leave no credentials")
    func offline() async throws {
        await server.on("POST sessions", .failure(.notConnectedToInternet))
        let (store, _) = makeStore()
        await #expect(throws: PingFrontError.network(.notConnectedToInternet)) {
            try await store.token(reason: .chatOpened)
        }
        #expect(try await secure.read(SecureKeys.credentials) == nil)
        #expect(await !store.isActive)
    }

    @Test("invalidate(token:) forces a refresh on the next call")
    func invalidate() async throws {
        await server.on("POST sessions", .ok(Wire.session(token: "tok_1")))
        await server.on("POST sessions/refresh", .ok(Wire.refresh(token: "tok_2")))
        let (store, _) = makeStore()
        let token = try await store.token(reason: .chatOpened)
        await store.invalidate(token: token)
        #expect(try await store.token(reason: .chatOpened) == "tok_2")
    }

    @Test("wipe() forgets credentials and the staged profile")
    func wipe() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        let (store, coalescer) = makeStore()
        await coalescer.stage(.traits(["a": "1"]))
        _ = try await store.token(reason: .chatOpened)
        await store.wipe()
        #expect(try await secure.read(SecureKeys.credentials) == nil)
        #expect(await !store.isActive)
        #expect(await coalescer.stagedProfile() == Profile())
    }
}
