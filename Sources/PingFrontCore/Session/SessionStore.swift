import Foundation
internal import os

/// Events the session store reports to the engine.
package enum SessionEvent: Sendable, Equatable {
    case started(PersonSummary, testDevice: Bool, identityProblem: IdentityProblem?)
    case refreshed(PersonSummary, testDevice: Bool)
    /// The server revoked the install secret. Local state was wiped; a new guest session follows.
    case revoked
    /// The server refused the staged identity (a different verified user without logout). It was dropped
    /// and is never sent again; the session continues without it.
    case identityRejected(IdentityProblem)
    /// The Keychain refused to store the install credentials: the next launch starts a new guest.
    case credentialsNotStored(StorageError)
}

/// Owns the install credentials (Keychain) and the short-lived access token (memory only).
/// Creates sessions lazily and single-flights concurrent token requests.
package actor SessionStore: Authenticator {
    package typealias DeviceProvider = @Sendable (_ installId: String) -> Device

    private let api: APIClient
    /// The install id and secret in the Keychain (versioned; legacy raw JSON migrates).
    private let stored: VersionedFile<InstallCredentials>
    private let time: TimeSource
    private let profile: PatchCoalescer
    private let device: DeviceProvider
    /// Adds the device context to the session requests (`nil`: no context, as in most tests).
    private let context: ContextReporter?
    /// Adds the registered screens to the session requests that carry them (`nil`: none, as in most tests).
    private let screens: ScreensReporter?
    private var credentials: InstallCredentials?
    private var loaded = false
    private var accessToken: String?
    private var accessValidUntil: Duration = .zero
    /// The single in-flight create/refresh, tagged so only its own caller clears it.
    private var inflight: (id: UInt64, task: Task<Result<String, PingFrontError>, Never>)?
    private var nextFlightId: UInt64 = 0
    /// Bumped by `wipe()`.
    ///
    /// A create or refresh started in an older generation is discarded on arrival:
    /// no Keychain write, no token, no event (logout and erase win over in-flight requests).
    private(set) package var generation: UInt64 = 0
    private(set) package var person: PersonSummary?
    private(set) package var testDevice = false
    /// Per-person UUID for StoreKit's `appAccountToken`, from the latest session or refresh.
    private(set) package var storeAccountToken: String?
    private let continuation: AsyncStream<SessionEvent>.Continuation
    /// Session lifecycle events.
    package nonisolated let events: AsyncStream<SessionEvent>

    package init(
        api: APIClient, secure: any SecureStore, time: TimeSource, profile: PatchCoalescer,
        device: @escaping DeviceProvider = DeviceInfo.current(installId:), context: ContextReporter? = nil,
        screens: ScreensReporter? = nil, holdsAfterRevoke: Bool = false
    ) {
        self.screens = screens
        self.holdsAfterRevoke = holdsAfterRevoke
        self.api = api
        self.stored = Self.credentialsFile(secure)
        self.time = time
        self.profile = profile
        self.device = device
        self.context = context
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    /// The Keychain record that holds the install credentials.
    package static func credentialsFile(_ secure: any SecureStore) -> VersionedFile<InstallCredentials> {
        VersionedFile(
            SecureKeys.credentials, version: 1, records: SecureRecords(secure),
            migrations: [0: { try JSONDecoder().decode(InstallCredentials.self, from: $0) }])
    }

    /// The current device facts, once an install exists (for `PATCH /me` when they change).
    package func currentDevice() async -> Device? {
        try? await loadCredentials()
        return credentials.map { device($0.installId) }
    }

    /// True when this install has a session from an earlier launch (no network). `false` while the
    /// Keychain is locked.
    package func hasInstall() async -> Bool {
        try? await loadCredentials()
        return credentials != nil
    }

    /// True when an access token is held in memory.
    package var isActive: Bool { accessToken != nil }

    package func installCredentials() async throws(StorageError) -> InstallCredentials? {
        try await loadCredentials()
        return credentials
    }

    /// A valid access token, creating or refreshing the session if needed.
    package func token(reason: SessionReason) async throws(PingFrontError) -> String {
        // While an erase or a wipe is in flight nothing may refresh or re-register the person being forgotten.
        guard !erasing, !revoked, wipes == 0 else { throw .cancelled }
        if let accessToken, time.now() < accessValidUntil { return accessToken }
        if let inflight { return try await inflight.task.value.get() }
        nextFlightId += 1
        let id = nextFlightId
        let flightGeneration = generation
        let task = Task { await self.establish(reason: reason, generation: flightGeneration) }
        inflight = (id, task)
        let result = await task.value
        if inflight?.id == id { inflight = nil }
        return try result.get()
    }

    #if DEBUG
        /// Behaviour scenarios: start from a known in-memory access token (debug builds only).
        package func adoptForTesting(token: String, validFor: Duration = .seconds(900)) {
            accessToken = token
            accessValidUntil = time.now() + validFor
        }

        /// Behaviour scenarios: the in-memory access token (debug builds only).
        package var accessTokenForTesting: String? { accessToken }
    #endif

    /// Drops the access token after a 401 so the next call refreshes.
    package func invalidate(token: String) {
        if accessToken == token { accessToken = nil }
    }

    /// True between `beginErase()` and `endErase(erased:)`: token requests fail fast.
    private(set) package var erasing = false
    /// The install was revoked: no token until the engine has dropped what belonged to it (`endRevoke()`), so nothing
    /// queued for it goes out under the new guest a token request would start.
    private(set) package var revoked = false

    /// Whether a revoke holds token requests until `endRevoke()` (the engine drops the revoked install's data first).
    private let holdsAfterRevoke: Bool

    /// The revoked install's local data is gone: token requests may start a new guest.
    package func endRevoke() { revoked = false }

    /// Erase starts: no token request may refresh or re-create the session while `DELETE /me` is in
    /// flight, and the staged profile (identity, traits) is forgotten before the request.
    package func beginErase() async {
        erasing = true
        generation += 1
        inflight?.task.cancel()
        inflight = nil
        accessToken = nil
        await profile.reset()
        await context?.reset()
    }

    /// Erase ended.
    ///
    /// On success everything local is forgotten; on failure nothing is restored and the erase can be
    /// retried (it is idempotent).
    package func endErase(erased: Bool) async {
        if erased { await wipe() }
        erasing = false
    }

    /// How many `wipe()` calls are running: token requests fail fast meanwhile, so nothing re-registers the person
    /// being forgotten with their staged identity before the profile is reset.
    private var wipes = 0

    /// Forgets the install (logout, erase).
    ///
    /// Everything in memory goes before the first suspension (the generation, the token, the credentials, then the
    /// staged profile), and no token request runs until the stored credentials are erased too. The next session is a
    /// new guest.
    package func wipe() async {
        generation += 1
        wipes += 1
        inflight?.task.cancel()
        inflight = nil
        clearMemory()
        await profile.reset()
        await context?.reset()
        await eraseStored()
        wipes -= 1
    }

    /// Clears credentials and tokens but keeps the staged profile (the app's identify calls still apply): a revoked
    /// install.
    private func clearLocal() async {
        clearMemory()
        await eraseStored()
    }

    private func clearMemory() {
        accessToken = nil
        person = nil
        testDevice = false
        storeAccountToken = nil
        credentials = nil
        loaded = true
    }

    private func eraseStored() async {
        do { try await stored.erase() } catch {
            // The Keychain is locked (before the first unlock after a restart): this launch never reads the old
            // install again (`loaded`), and the erase is owed until the Keychain opens (`settleOwedErase()`).
            eraseOwed = true
            Log.session(.error)?.error("Could not delete the install credentials: \(error.logDescription, privacy: .public)")
        }
    }

    /// A logout or erase could not delete the stored install (the Keychain was locked).
    private(set) package var eraseOwed = false
    /// Installs found in the Keychain after an owed erase, for `POST /me/logout`.
    private var owedLogouts: [InstallCredentials] = []

    /// Finishes an owed erase once the Keychain can be read, and returns the installs it removed so the engine queues
    /// their `POST /me/logout`.
    ///
    /// The engine calls it when protected data becomes available and before it drains pending logouts; a session
    /// request does it before it creates or refreshes. Still locked: nothing changes and it is tried again next time.
    package func settleOwedErase() async -> [InstallCredentials] {
        if eraseOwed { await retryOwedErase() }
        let owed = owedLogouts
        owedLogouts = []
        return owed
    }

    private func retryOwedErase() async {
        let flight = generation
        let found: InstallCredentials?
        do { found = try await stored.load() } catch { return }
        guard eraseOwed, flight == generation else { return }
        // Nothing stored, or the install this launch uses now: nothing of the logged-out person is left.
        guard let found, found.installId != credentials?.installId else {
            eraseOwed = false
            return
        }
        do {
            // A guest this launch started meanwhile (kept in memory) replaces the stale record; otherwise it goes.
            if let credentials { try await stored.save(credentials) } else { try await stored.erase() }
        } catch {
            return
        }
        if !owedLogouts.contains(where: { $0.installId == found.installId }) { owedLogouts.append(found) }
        // A wipe that ran during the write decides again on the next call.
        if flight == generation { eraseOwed = false }
    }

    /// The create in an older generation saved its install after a wipe erased the Keychain: put back what this
    /// generation holds (nothing after a logout, or a newer guest's install).
    private func restoreStoredCredentials() async {
        do {
            if let credentials { try await stored.save(credentials) } else { try await stored.erase() }
        } catch {
            eraseOwed = credentials == nil
            Log.session(.error)?.error("Could not undo a late install write: \(error.logDescription, privacy: .public)")
        }
    }

    /// Reads the credentials once.
    ///
    /// While the Keychain is locked this throws and stays unloaded, so the
    /// next call reads again; a locked Keychain never counts as "no install" (that would mint a new one).
    private func loadCredentials() async throws(StorageError) {
        guard !loaded else { return }
        credentials = try await stored.load()
        loaded = true
    }

    private func establish(reason: SessionReason, generation flight: UInt64) async -> Result<String, PingFrontError> {
        do { try await loadCredentials() } catch {
            Log.session(.info)?.notice("The Keychain is locked; the session waits for protected data")
            return .failure(.protectedDataUnavailable)
        }
        // An erase a logout owes goes first, so a new install never overwrites the record its logout still needs.
        if eraseOwed { await retryOwedErase() }
        // A wipe bumps the generation before it resets the profile: read here, the epoch tags this flight's profile
        // writes, so they are dropped if a logout lands while they are in flight.
        let profileEpoch = await profile.resets
        guard flight == generation else { return .failure(.cancelled) }
        if let credentials {
            do {
                // Refresh carries the device facts, so time zone, locale and versions stay current.
                let facts = device(credentials.installId)
                // The context rides on this refresh (it goes out anyway); the staged profile never holds it.
                let draft = await context?.draft(for: .refresh)
                guard flight == generation else { return .failure(.cancelled) }
                var withContext = facts
                withContext.context = draft?.context
                // The screens ride on a refresh only when the list or the app version changed since this install sent it.
                let screensDraft = await screens?.ifChanged(installId: credentials.installId, appVersion: facts.app.version)
                withContext.app.screens = screensDraft?.screens
                let request = RefreshSessionRequest(
                    installId: credentials.installId, installSecret: credentials.installSecret, device: withContext)
                let response = try await api.send(Endpoints.refreshSession(request))
                guard flight == generation else { return .failure(.cancelled) }
                if let draft { await context?.delivered(draft) }
                if let screensDraft { await screens?.delivered(screensDraft, installId: credentials.installId) }
                await context?.update(collection: response.collect)
                // Logged out while those were recorded (actor re-entrancy): check again, with no suspension between this
                // check and the writes, so the old token and person never come back after a wipe.
                guard flight == generation else { return .failure(.cancelled) }
                store(token: response.accessToken, expiresIn: response.accessExpiresIn, expiresAt: response.accessExpiresAt)
                person = response.person
                testDevice = response.testDevice
                storeAccountToken = response.storeAccountToken ?? storeAccountToken
                continuation.yield(.refreshed(response.person, testDevice: response.testDevice))
                await profile.markDeviceSent(facts, epoch: profileEpoch)
                await profile.activate(epoch: profileEpoch)
                guard flight == generation else { return .failure(.cancelled) }
                return .success(response.accessToken)
            } catch {
                guard flight == generation else { return .failure(.cancelled) }
                switch error.code {
                case .sessionRevoked?:
                    // Wipe, and don't retry: the request that hit the 401 fails, and the next call (the next
                    // chat open) starts a new session (scenario auth-refresh-revoked).
                    Log.session(.info)?.notice("Install secret revoked; local state wiped")
                    revoked = holdsAfterRevoke
                    generation += 1
                    await clearLocal()
                    continuation.yield(.revoked)
                    return .failure(error)
                case .unauthorized?, .notFound?:
                    // The secret is unknown to the server (for example a reset dev database). Create a new one.
                    break
                default:
                    return .failure(error)
                }
            }
        }
        return await create(reason: reason, generation: flight, profileEpoch: profileEpoch)
    }

    private func create(
        reason: SessionReason, generation flight: UInt64, profileEpoch: UInt64, retried: Bool = false
    ) async -> Result<
        String, PingFrontError
    > {
        let installId = credentials?.installId ?? UUID().uuidString.lowercased()
        let staged = await profile.stagedProfile()
        let facts = device(installId)
        let draft = await context?.draft(for: .create)
        guard flight == generation else { return .failure(.cancelled) }
        var withContext = facts
        withContext.context = draft?.context
        // Every session request carries the registered screens.
        let screensDraft = await screens?.forCreate(appVersion: facts.app.version)
        guard flight == generation else { return .failure(.cancelled) }
        withContext.app.screens = screensDraft?.screens
        let request = CreateSessionRequest(
            device: withContext,
            // Re-registering a known install needs its secret; without it the server mints a new id.
            installSecret: credentials?.installSecret,
            identity: staged.identity,
            traits: staged.traits.isEmpty ? nil : staged.traits,
            entitlement: staged.entitlement,
            offers: staged.offers,
            hostLook: staged.hostLook,
            reason: reason
        )
        do {
            let response = try await api.send(Endpoints.createSession(request))
            // Logged out or erased while the request was in flight: drop it.
            guard flight == generation else { return .failure(.cancelled) }
            // Adopt the id the server registered (a fresh one when the sent id could not be reused).
            let registeredId = response.installId ?? installId
            if registeredId != installId { Log.session(.info)?.notice("The server assigned a new install id") }
            let newCredentials = InstallCredentials(installId: registeredId, installSecret: response.installSecret)
            // No suspension between the check above and this: a wipe either ran before (and the check failed) or runs
            // after, and then erases what is saved here.
            credentials = newCredentials
            do { try await stored.save(newCredentials) } catch {
                // Kept in memory for this launch; the next launch refreshes or re-registers.
                Log.session(.error)?.error("Could not store the install credentials: \(error.logDescription, privacy: .public)")
                continuation.yield(.credentialsNotStored(error))
            }
            guard flight == generation else {
                // A wipe ran while the Keychain write was in flight and may have erased before it landed.
                await restoreStoredCredentials()
                return .failure(.cancelled)
            }
            if let screensDraft { await screens?.delivered(screensDraft, installId: registeredId) }
            if let draft { await context?.delivered(draft) }
            await context?.update(collection: response.collect)
            guard flight == generation else { return .failure(.cancelled) }
            store(token: response.accessToken, expiresIn: response.accessExpiresIn, expiresAt: response.accessExpiresAt)
            person = response.person
            testDevice = response.testDevice
            storeAccountToken = response.storeAccountToken
            // The push token is not part of POST /sessions; leave it unsent so the PATCH carries it.
            var sent = staged
            sent.push = nil
            sent.device = registeredId == installId ? facts : device(registeredId)
            await profile.markSent(sent, epoch: profileEpoch)
            await profile.activate(epoch: profileEpoch)
            guard flight == generation else { return .failure(.cancelled) }
            continuation.yield(.started(response.person, testDevice: response.testDevice, identityProblem: response.identityProblem))
            Log.session(.info)?.info(
                "Session created for person \(response.person.id, privacy: .private) (\(response.person.level.rawValue, privacy: .public))")
            return .success(response.accessToken)
        } catch  where error.code == .identityUserMismatch && !retried && flight == generation {
            // A different verified user without logout: drop the identity for good and continue without it.
            Log.session(.error)?.error("The server refused the identity (identity_user_mismatch); it was dropped")
            await profile.dropIdentity()
            continuation.yield(.identityRejected(.userMismatch))
            return await create(reason: reason, generation: flight, profileEpoch: profileEpoch, retried: true)
        } catch {
            return .failure(error)
        }
    }

    /// Schedules the refresh from the server's `accessExpiresIn` on the injected monotonic clock, with a
    /// 60 s margin.
    ///
    /// The device's wall clock is never compared with `accessExpiresAt` (it is often wrong);
    /// that is only a fallback for a server that omits `accessExpiresIn`.
    private func store(token: String, expiresIn: Int?, expiresAt: Date) {
        accessToken = token
        let seconds: Double = expiresIn.map(Double.init) ?? max(expiresAt.timeIntervalSinceNow, 0)
        accessValidUntil = time.now() + .milliseconds(Int64(seconds * 1000)) - Timing.tokenMargin
    }
}
