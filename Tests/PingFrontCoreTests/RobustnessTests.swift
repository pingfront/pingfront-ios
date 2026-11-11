import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

// MARK: Harness

/// A secure store whose writes can be held at the suspension point the test wants (a Keychain write in flight), and
/// that can be locked like the Keychain before the first unlock.
actor HeldSecureStore: SecureStore {
    enum Hold { case none, save, erase }
    private var items: [String: Data] = [:]
    private var hold: Hold = .none
    private var held: CheckedContinuation<Void, Never>?
    private(set) var isHolding = false
    var locked = false

    func holdNext(_ hold: Hold) { self.hold = hold }
    func setLocked(_ locked: Bool) { self.locked = locked }

    func release() {
        isHolding = false
        held?.resume()
        held = nil
    }

    func read(_ key: String) throws(StorageError) -> Data? {
        if locked { throw .unavailable }
        return items[key]
    }

    func write(_ key: String, _ data: Data?) async throws(StorageError) {
        if locked { throw .unavailable }
        if key == SecureKeys.credentials, (hold == .save && data != nil) || (hold == .erase && data == nil) {
            hold = .none
            isHolding = true
            await withCheckedContinuation { held = $0 }
        }
        items[key] = data
    }
}

/// Persistence whose write of one file is held until the test releases it.
actor HeldPersistence: Persistence {
    private var files: [String: Data] = [:]
    private var holding: String?
    private var held: CheckedContinuation<Void, Never>?
    private(set) var isHolding = false

    func holdNext(_ name: String) { holding = name }

    func release() {
        isHolding = false
        held?.resume()
        held = nil
    }

    func read(_ name: String) -> Data? { files[name] }

    func write(_ name: String, _ data: Data) async {
        if name == holding || (holding == "*" && name != Files.outbox) {
            holding = nil
            isHolding = true
            await withCheckedContinuation { held = $0 }
        }
        files[name] = data
    }

    func remove(_ name: String) { files[name] = nil }
    func has(_ name: String) -> Bool { files[name] != nil }
}

/// Robustness fixes from the iOS audit.
///
/// Logout races in the session store, the write retry policy, local wipes, the rating scale and link screen params.
/// Each race interleaves a logout at the suspension point the audit named.
@Suite("Robustness")
struct RobustnessTests {
    let key = "pk_test_abcdefghijklmnopqrstuvvd"

    func store(
        _ transport: GatedTransport, secure: any SecureStore, profile: PatchCoalescer? = nil, screens: ScreensReporter? = nil
    ) -> (SessionStore, PatchCoalescer) {
        let time = TimeSource(TestClock())
        let api = APIClient(baseURL: StubTransport.base, appKey: key, transport: transport, cooldowns: CooldownBook(time: time))
        let profile = profile ?? PatchCoalescer(time: time)
        return (SessionStore(api: api, secure: secure, time: time, profile: profile, screens: screens), profile)
    }

    static func credentials(_ id: String) throws -> Data {
        try JSONEncoder().encode(InstallCredentials(installId: id, installSecret: "secret_\(id)"))
    }

    // MARK: P1, logout races

    @Test("A refresh whose answer is being recorded when logout runs stores no token, person or event")
    func refreshLandsAfterLogout() async throws {
        let gate = Gate()
        let secure = HeldSecureStore()
        try await SessionStore.credentialsFile(secure).save(InstallCredentials(installId: "inst_old", installSecret: "s"))
        let registry = ScreenRegistry()
        registry.register([AppScreen(id: "settings")])
        let persistence = HeldPersistence()
        let screens = ScreensReporter(registry: registry, persistence: persistence)
        let (session, _) = store(GatedTransport(gate: gate), secure: secure, screens: screens)
        // The refresh carries the screens, so its answer suspends on recording them: logout runs right there.
        await persistence.holdNext(Files.screensSent)
        let refresh = Task { try await session.token(reason: .chatOpened) }
        #expect(await waitUntil { await gate.total == 1 })
        #expect(await gate.count("POST sessions/refresh") == 1)
        await gate.release(0, 200, Wire.refresh(token: "old_token"))
        #expect(await waitUntil { await persistence.isHolding })
        await session.wipe()
        await persistence.release()
        let result = await refresh.result
        #expect(throws: PingFrontError.cancelled) { try result.get() }
        #expect(await session.isActive == false)
        // The person is set right before `.refreshed` is emitted: neither came back for the previous person.
        #expect(await session.person == nil)
    }

    @Test("A session create whose Keychain write is in flight when logout runs leaves no install behind")
    func createSaveRacesLogout() async throws {
        let gate = Gate()
        let secure = HeldSecureStore()
        let (session, _) = store(GatedTransport(gate: gate), secure: secure)
        await secure.holdNext(.save)
        let create = Task { try await session.token(reason: .chatOpened) }
        #expect(await waitUntil { await gate.total == 1 })
        await gate.release(0, 200, Wire.session(token: "ghost", secret: "ghost_secret", installId: "inst_ghost"))
        #expect(await waitUntil { await secure.isHolding })
        // Logout erases while the save is in flight; the save lands after the erase.
        await session.wipe()
        await secure.release()
        let result = await create.result
        #expect(throws: PingFrontError.cancelled) { try result.get() }
        #expect(try await secure.read(SecureKeys.credentials) == nil, "the logged-out install came back")
        #expect(await session.isActive == false)
        // The next launch is a new guest: nothing to refresh.
        let (relaunched, _) = store(GatedTransport(gate: Gate()), secure: secure)
        #expect(await relaunched.hasInstall() == false)
    }

    @Test("A token request during wipe() fails fast; the next session never carries the old identity")
    func tokenDuringWipe() async throws {
        let gate = Gate()
        let secure = HeldSecureStore()
        let (session, profile) = store(GatedTransport(gate: gate, auto: ["POST sessions": (200, Wire.session())]), secure: secure)
        await profile.stage(.identity(Identity(userId: "alice", name: nil, email: nil, token: nil)))
        _ = try await session.token(reason: .chatOpened)
        #expect(await gate.count("POST sessions") == 1)
        // Logout suspends on the Keychain erase; the PATCH flush, an unread poll or a retry asks for a token there.
        await secure.holdNext(.erase)
        let wipe = Task { await session.wipe() }
        #expect(await waitUntil { await secure.isHolding })
        await #expect(throws: PingFrontError.cancelled) { try await session.token(reason: .chatOpened) }
        #expect(await gate.count("POST sessions") == 1, "a session was created during the wipe")
        // The staged identity is gone before the first suspension.
        #expect(await profile.stagedProfile().identity == nil)
        await secure.release()
        await wipe.value
        _ = try await session.token(reason: .chatOpened)
        let creates = await gate.log.filter { $0.method == "POST" && $0.path == "sessions" }
        #expect(creates.count == 2)
        #expect(creates.last?.json?["identity"] == nil, "the new guest carried the previous person's identity")
    }

    @Test("Logout with the Keychain locked owes the erase; it is settled and logged out once the Keychain opens")
    func logoutWhileLocked() async throws {
        let gate = Gate()
        let secure = HeldSecureStore()
        try await SessionStore.credentialsFile(secure).save(InstallCredentials(installId: "inst_old", installSecret: "s"))
        await secure.setLocked(true)
        let (session, _) = store(
            GatedTransport(gate: gate, auto: ["POST sessions": (200, Wire.session(installId: "inst_new"))]), secure: secure)
        await session.wipe()
        #expect(await session.eraseOwed)
        // Still locked: nothing changes.
        #expect(await session.settleOwedErase().isEmpty)
        await secure.setLocked(false)
        let owed = await session.settleOwedErase()
        #expect(owed.map(\.installId) == ["inst_old"])
        #expect(await session.eraseOwed == false)
        #expect(try await secure.read(SecureKeys.credentials) == nil)
        // The next session is a new guest: the old install's secret never goes out again.
        _ = try await session.token(reason: .chatOpened)
        let create = await gate.log.first { $0.path == "sessions" }
        #expect(create?.json?["installSecret"] == nil)
    }

    // MARK: P1, retry policy

    @Test("Writes back off up to 5 minutes, live reconnects up to 30 s")
    func backoffCaps() {
        #expect(Backoff.writes.nominal(attempt: 0) == .seconds(1))
        #expect(Backoff.writes.nominal(attempt: 8) == .seconds(256))
        #expect(Backoff.writes.nominal(attempt: 9) == .seconds(300))
        #expect(Backoff.writes.nominal(attempt: 40) == .seconds(300))
        #expect(Backoff.writes.delay(attempt: 40, unit: 1) == .seconds(360))
        #expect(Backoff.writes.delay(attempt: 40, unit: -1) == .seconds(240))
        #expect(Backoff.live.nominal(attempt: 40) == .seconds(30))
    }

    static func serverError(_ status: Int, _ code: String) -> PingFrontError {
        .server(ErrorEnvelope.serverError(status: status, data: Data(Wire.error(code).utf8), retryAfterHeader: nil))
    }

    @Test("401 and 409 thread_reset are final for the write loops; 408 retries")
    func transientClassification() {
        #expect(!Self.serverError(401, "unauthorized").isTransient)
        #expect(!Self.serverError(409, "thread_reset").isTransient)
        #expect(Self.serverError(408, "timeout").isTransient)
        #expect(Self.serverError(503, "unavailable").isTransient)
    }

    @Test("A send that keeps getting 401 after the client's refresh fails instead of retrying forever")
    func persistentUnauthorized() async {
        let outbox = Outbox(persistence: MemoryPersistence())
        await outbox.enqueue(PendingMessage(clientId: "c1", text: "hi"))
        let calls = CallCount()
        let result = await outbox.drain(uploadsPaused: false) { _ throws(PingFrontError) in
            await calls.bump()
            throw Self.serverError(401, "unauthorized")
        }
        #expect(result == .idle)
        #expect(await calls.value == 1)
        #expect(await outbox.all().first?.state == .failed)
    }

    @Test("A send that gets 409 thread_reset goes once more at once; a second reset fails it")
    func threadResetRetriesOnce() async {
        let persistence = MemoryPersistence()
        let outbox = Outbox(persistence: persistence)
        await outbox.enqueue(PendingMessage(clientId: "c1", text: "hi"))
        let calls = CallCount()
        let result = await outbox.drain(uploadsPaused: false) { _ throws(PingFrontError) in
            await calls.bump()
            throw Self.serverError(409, "thread_reset")
        }
        #expect(result == .idle)
        #expect(await calls.value == 2)
        let item = await outbox.all().first
        #expect(item?.state == .failed)
        #expect(item?.retriedAfterReset == true)
        // The flag is stored: a relaunch does not get another free retry.
        let reloaded = Outbox(persistence: persistence)
        #expect(await reloaded.load().first?.retriedAfterReset == true)
        // Try again is the person's new attempt.
        await outbox.retry("c1")
        #expect(await outbox.all().first?.retriedAfterReset == nil)
    }

    @Test("A send that succeeds after one thread_reset is delivered")
    func threadResetThenDelivered() async {
        let outbox = Outbox(persistence: MemoryPersistence())
        await outbox.enqueue(PendingMessage(clientId: "c1", text: "hi"))
        let calls = CallCount()
        let result = await outbox.drain(uploadsPaused: false) { item throws(PingFrontError) in
            if await calls.bump() == 1 { throw Self.serverError(409, "thread_reset") }
            return makeMessage("m1", seq: 1, kind: .person, clientId: item.clientId)
        }
        #expect(result == .idle)
        #expect(await calls.value == 2)
        #expect(await outbox.all().isEmpty)
    }

    // MARK: P2

    @Test("A photo send whose files are written when logout clears the outbox is not queued")
    func photoEnqueueRacesClear() async {
        let persistence = HeldPersistence()
        let outbox = Outbox(persistence: persistence)
        await outbox.load()
        let photo = PendingMessage.Photo(file: "outbox-c1-0.jpg", width: 1, height: 1, bytes: 1, sha256: "00")
        var message = PendingMessage(clientId: "c1", text: nil)
        message.photos = [photo]
        await persistence.holdNext("outbox-c1-0.jpg")
        let enqueue = Task { await outbox.enqueue(message, photoData: [Data([1])]) }
        #expect(await waitUntil { await persistence.isHolding })
        await outbox.clear()
        await persistence.release()
        await enqueue.value
        #expect(await outbox.all().isEmpty)
        #expect(await persistence.has("outbox-c1-0.jpg") == false)
    }

    @Test("The attachment URL cache is bounded and cleared")
    func attachmentCache() async throws {
        let server = StubServer()
        let time = TimeSource(TestClock())
        let api = APIClient(
            baseURL: StubTransport.base, appKey: key, transport: StubTransport(server: server), cooldowns: CooldownBook(time: time))
        let (session, _) = store(GatedTransport(gate: Gate(), auto: ["POST sessions": (200, Wire.session())]), secure: MemorySecureStore())
        await session.adoptForTesting(token: "tok")
        let uploader = Uploader(client: AuthorizedClient(api: api, authenticator: session), time: time)
        for index in 0..<(Uploader.cacheLimit + 5) {
            await server.on(
                "GET attachments/att_\(index)", .ok(#"{"url":"https://cdn.example/\#(index)","expiresAt":"2099-01-01T00:00:00Z"}"#))
            _ = try await uploader.url(for: "att_\(index)")
        }
        #expect(await uploader.cachedCount == Uploader.cacheLimit)
        await uploader.clear()
        #expect(await uploader.cachedCount == 0)
    }

    @Test("A link screen's params drop only the values that aren't strings")
    func linkScreenParamsDropOneByOne() throws {
        func decode(_ json: String) throws -> LinkScreen { try JSONDecoder().decode(LinkScreen.self, from: Data(json.utf8)) }
        let mixed = try decode(
            #"{"id":"plans","params":{"tab":"yearly","count":3,"on":true,"nested":{"a":"b"},"none":null,"from":"chat"}}"#)
        #expect(mixed.id == "plans")
        #expect(mixed.params == ["tab": "yearly", "from": "chat"])
        #expect(try decode(#"{"id":"plans","params":"oops"}"#).params == [:])
        #expect(try decode(#"{"id":"plans"}"#).params == [:])
    }

    @Test("A rating card's scale is clamped into the protocol's 1...5 when decoded")
    func ratingScaleClamped() throws {
        func decode(_ scale: Int) throws -> RatingCard {
            try JSONDecoder().decode(RatingCard.self, from: Data(#"{"kind":"rating","id":"c","question":"Q","scale":\#(scale)}"#.utf8))
        }
        #expect(try decode(5).scale == 5)
        #expect(try decode(1_000_000).scale == 5)
        #expect(try decode(0).scale == 1)
        #expect(try decode(-3).scale == 1)
        #expect(RatingCard(id: "c", question: "Q", scale: 99).stars == 5)
        #expect(RatingCard(id: "c", question: "Q", scale: 0).stars == 1)
    }
}

actor CallCount {
    private(set) var value = 0
    @discardableResult func bump() -> Int {
        value += 1
        return value
    }
}
