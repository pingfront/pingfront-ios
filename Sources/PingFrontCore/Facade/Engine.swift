import Foundation
internal import os

/// One tapped Send, waiting for photo preparation.
package struct SendJob: Sendable {
    let message: PendingMessage
    let photos: [Data]
    /// The person the send was tapped for (`Engine.personEpoch`): a job prepared after logout or erase is dropped.
    var epoch = 0
}

/// Orchestrates the actors for one configured app key.
///
/// Lives on the main actor because it feeds
/// observable UI state; every network or disk operation runs inside the actors or `@concurrent` helpers.
/// All long-lived loops are owned tasks, cancelled in `stop()`.
@MainActor
package final class Engine {
    /// Ordered profile and lifecycle commands from the synchronous facade.
    package enum Command: Sendable {
        case stage(ProfileChange)
        case logout
    }

    unowned let facade: PingFront
    package let key: AppKey
    let configuration: PingFrontConfiguration
    package let time: TimeSource
    package let api: APIClient
    /// `api` with bearer auth and the 401 refresh, backed by `session`.
    package let client: AuthorizedClient
    let persistence: any Persistence
    package let coalescer: PatchCoalescer
    /// The device context that rides on session requests and `PATCH /me`.
    let context: ContextReporter?
    package let session: SessionStore
    package let outbox: Outbox
    let uploader: Uploader
    package let live: LiveConnection
    let configStore: ConfigStore
    let moments: MomentGate
    let outboxWake = WakeSignal()
    let logouts: LogoutQueue
    let threadCache: ThreadCache
    /// The host app's answers to team actions, queued on disk.
    package let teamActionAcks: TeamActionAcks
    let acksWake = WakeSignal()
    /// Card action reports, queued on disk and retried safely (`CardActionReports`).
    package let cardReports: CardActionReports
    let cardReportsWake = WakeSignal()
    var cardReportsTask: Task<Void, Never>?
    /// Sends team action answers; cancelled with the outbox on logout and erase.
    var acksTask: Task<Void, Never>?
    /// The outbox drain loop, cancelled on logout and erase so no send outlives the session.
    var outboxTask: Task<Void, Never>?
    /// Sends in the order the person tapped Send: one consumer prepares photos and enqueues.
    var sendJobs: AsyncStream<SendJob>.Continuation?
    /// Messages tapped Send but not yet in the outbox (photos preparing), or failed before enqueueing.
    var stagedSends: [PendingMessage] = []
    /// The APNs token the app last passed (hex): the device's, kept across logout and erase.
    var devicePushToken: String?
    /// Bumped by logout and erase: work started for the previous person checks it before it writes anything.
    var personEpoch = 0
    /// When this engine started (the wall clock): what StoreKit replays from before it is a launch-time detection.
    let launchedAt = Date.now
    var repairFailures = 0
    /// The last `GET /thread` failed: an open chat reads it again on the next foreground.
    var threadLoadFailed = false

    package private(set) var remoteConfig: AppConfig?
    var offers: [OfferSlot] = []
    private var commands: AsyncStream<Command>.Continuation?
    private var loops: [Task<Void, Never>] = []
    private let tasks = TaskBag()
    var draftTask: Task<Void, Never>?
    var hostLookVersionSent: String?
    #if DEBUG
        /// Offline preview (`-PingFrontPreview`, snapshots): nothing is sent.
        ///
        /// Debug builds only.
        var preview = false {
            didSet {
                unread.isPreview = preview
                typing.isPreview = preview
            }
        }
    #else
        /// Release builds never run the offline preview.
        var preview: Bool { false }
    #endif
    /// The unread count and polling.
    package let unread: UnreadMonitor
    let readReceipts: ReadReceipts
    let typing: TypingController
    let cards: CardActions

    package var conversation: Conversation { facade.conversation }

    init(facade: PingFront, key: AppKey, configuration: PingFrontConfiguration, dependencies: Dependencies) {
        self.facade = facade
        self.key = key
        self.configuration = configuration
        time = dependencies.time
        persistence = dependencies.persistence
        let cooldowns = CooldownBook(time: dependencies.time)
        api = APIClient(
            baseURL: configuration.baseURL, appKey: key.rawValue, transport: dependencies.transport, cooldowns: cooldowns,
            verbose: configuration.logLevel >= .debug, wrapper: configuration.wrapper)
        let context = dependencies.context.map {
            ContextReporter(source: $0, persistence: dependencies.persistence, time: dependencies.time)
        }
        self.context = context
        let screens = ScreensReporter(registry: facade.screenRegistry, persistence: dependencies.persistence)
        coalescer = PatchCoalescer(time: dependencies.time, context: context, screens: screens)
        session = SessionStore(
            api: api, secure: dependencies.secure, time: dependencies.time, profile: coalescer, device: dependencies.device,
            context: context, screens: screens, holdsAfterRevoke: true)
        client = AuthorizedClient(api: api, authenticator: session)
        outbox = Outbox(persistence: dependencies.persistence)
        uploader = Uploader(client: client, time: dependencies.time)
        live = LiveConnection(api: api, session: session, time: dependencies.time)
        configStore = ConfigStore(client: client, persistence: dependencies.persistence, time: dependencies.time)
        moments = MomentGate(time: dependencies.time)
        logouts = LogoutQueue(secure: dependencies.secure)
        threadCache = ThreadCache(persistence: dependencies.persistence)
        teamActionAcks = TeamActionAcks(persistence: dependencies.persistence)
        unread = UnreadMonitor(facade: facade, client: client, session: session, time: dependencies.time)
        readReceipts = ReadReceipts(facade: facade, client: client, session: session, time: dependencies.time, unread: unread)
        typing = TypingController(facade: facade, live: live, time: dependencies.time)
        cardReports = CardActionReports(persistence: dependencies.persistence)
        cards = CardActions(facade: facade, client: client, time: dependencies.time, reports: cardReports, wake: cardReportsWake)
        facade.conversation.driver = self
        facade.conversation.time = dependencies.time
        unread.answered = { [weak self] in self?.unreadAnswered() }
    }

    // MARK: Start and stop

    func start() {
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self, bufferingPolicy: .unbounded)
        commands = continuation
        let (jobs, jobInput) = AsyncStream.makeStream(of: SendJob.self, bufferingPolicy: .unbounded)
        sendJobs = jobInput
        startOutboxLoop()
        let client = client
        loops = [
            Task { [weak self] in
                // The PATCH sender closure captures only Sendable values.
                await self?.coalescer.setSender { patch async throws(PingFrontError) in
                    try await client.send(Endpoints.updateMe(patch), reason: .prepare)
                }
                for await command in stream { await self?.handle(command) }
            },
            Task { [weak self, session] in
                for await event in session.events { self?.handle(event) }
            },
            Task { [weak self, coalescer] in
                for await response in coalescer.responseStream { self?.patched(response) }
            },
            Task { [weak self, outbox] in
                for await items in outbox.changes { self?.publishPending(items) }
            },
            Task { [weak self, outbox] in
                for await delivery in outbox.deliveries { self?.delivered(delivery.message) }
            },
            Task { [weak self, live] in
                for await signal in live.signals { await self?.handle(signal) }
            },
            Task { [weak self] in
                for await event in AppLifecycle.events() { self?.lifecycle(event) }
            },
            Task { [weak self] in await self?.sendLoop(jobs) },
            Task { [weak self] in await self?.restoreLocalState() },
            // Passive: a memory warning only marks the next session-start health as `warning`.
            Task { [context] in await context?.observeMemoryWarnings() },
        ]
        unread.start()
    }

    /// Called after modules registered: start entitlement sources, stage the host look.
    func modulesInstalled() {
        for source in facade.entitlementSources {
            loops.append(
                Task { [weak self] in
                    for await entitlement in source.entitlementUpdates() { self?.submit(.stage(.entitlement(entitlement))) }
                })
        }
        // Each module source keeps its own slots up to date; the app's `setOffers(_:)` slots stay.
        for source in facade.offerSources {
            loops.append(
                Task { [weak self] in
                    for await slots in source.offerUpdates() { self?.facade.setOffers(slots, from: source.slotSource) }
                })
        }
        run { [weak self] in await self?.stageHostLookIfNeeded() }
    }

    func startOutboxLoop() {
        outboxTask?.cancel()
        outboxTask = Task { [weak self] in await self?.outboxLoop() }
        acksTask?.cancel()
        acksTask = Task { [weak self] in await self?.teamActionAcksLoop() }
        cardReportsTask?.cancel()
        cardReportsTask = Task { [weak self] in await self?.cardReportsLoop() }
    }

    /// Stops every write for the current person (logout, erase).
    func stopWrites() {
        outboxTask?.cancel()
        acksTask?.cancel()
        cardReportsTask?.cancel()
    }

    func stop() {
        commands?.finish()
        sendJobs?.finish()
        stopWrites()
        loops.forEach { $0.cancel() }
        tasks.cancelAll()
        pausedRecheck?.cancel()
        pausedRecheck = nil
        unread.stop()
        readReceipts.cancel()
        typing.stop()
        cards.cancelAll()
        draftTask?.cancel()
        loops = []
        let live = live
        let context = context
        if conversation.driver === self { conversation.driver = nil }
        // Teardown is synchronous (reconfigure); the engine's own tasks are already cancelled, so this
        // last hop into the live and context actors is the one fire-and-forget task. It ends as soon as the
        // socket closes and the path monitor is cancelled.
        Task {
            await live.stop()
            await context?.stop()
        }
    }

    /// Runs an owned one-shot operation; cancelled by `stop()`.
    func run(_ operation: @escaping @MainActor () async -> Void) { tasks.run(operation) }

    package func submit(_ command: Command) { commands?.yield(command) }

    private func handle(_ command: Command) async {
        switch command {
        case .stage(let change):
            if case .entitlement(let entitlement) = change { facade.currentEntitlement = entitlement }
            // An offline preview sends nothing: a store change only updates what the chat shows.
            guard !preview else { return }
            await coalescer.stage(change)
        case .logout:
            await performLogout()
        }
    }

    private func restoreLocalState() async {
        // An offline preview shows only its fixture: never the real (cached) thread, queue or draft.
        guard !preview else { return }
        let pending = await outbox.load()
        guard !preview else { return }
        conversation.setPending(pending)
        if let data = try? await persistence.read(Files.draft), let text = String(data: data, encoding: .utf8), conversation.draft.isEmpty,
            !preview
        {
            conversation.draft = text
        }
        if let cached = await threadCache.load(), conversation.messages.isEmpty, !preview {
            // The tracker stays at 0: the next thread load sets it from the server, never from the cache.
            conversation.messages = cached.messages
            conversation.team = cached.team
            conversation.hasOlder = cached.hasOlder
            conversation.phase = .ready
        }
        if let config = await configStore.cached() { apply(config) }
        if let data = try? await persistence.read(Files.hostLookVersion) { hostLookVersionSent = String(data: data, encoding: .utf8) }
    }

    /// The host app info changed after configure (the icon arrived): stage it if this version's look was
    /// not sent yet.
    func hostLookChanged() { run { [weak self] in await self?.stageHostLookIfNeeded() } }

    private func stageHostLookIfNeeded() async {
        if hostLookVersionSent == nil, let data = try? await persistence.read(Files.hostLookVersion) {
            hostLookVersionSent = String(data: data, encoding: .utf8)
        }
        guard let host = facade.hostApp, hostLookVersionSent != host.appVersion else { return }
        await coalescer.stage(.hostLook(host.hostLook))
    }

    private func hostLookDelivered() {
        guard let host = facade.hostApp, hostLookVersionSent != host.appVersion else { return }
        hostLookVersionSent = host.appVersion
        let persistence = persistence
        run { try? await persistence.write(Files.hostLookVersion, Data(host.appVersion.utf8)) }
    }

    // MARK: Session events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .started(let person, let testDevice, let identityProblem):
            facade.person = person
            facade.isTestDevice = testDevice
            hostLookDelivered()
            facade.emit(.sessionStarted(person))
            syncStoreAccountToken()
            if let identityProblem { facade.reportIdentityProblem(identityProblem) }
            run { [weak self] in await self?.drainPendingLogouts() }
            outboxWake.notify()
            acksWake.notify()
            catchUpTeamActions()
        case .refreshed(let person, let testDevice):
            facade.person = person
            facade.isTestDevice = testDevice
            syncStoreAccountToken()
            outboxWake.notify()
            acksWake.notify()
            cardReportsWake.notify()
        case .identityRejected(let problem):
            facade.reportIdentityProblem(problem)
        case .credentialsNotStored(let error):
            facade.report(
                ConfigurationProblem(
                    kind: .keychain,
                    message:
                        "The Keychain refused to store this install (\(error.logDescription)). Every launch starts a new guest and the chat looks empty. Sign the app (simulator: CODE_SIGN_IDENTITY \"-\") and check the Keychain entitlement.",
                    disablesSDK: false))
        case .revoked:
            conversation.clear()
            unread.set(0)
            facade.emit(.sessionRevoked)
            // The revoked install's thread, queues and draft belong to no one now (scenario auth-refresh-revoked): the
            // same wipe as a logout, except the staged profile, which the next guest keeps. Only then may a token
            // request start a new guest.
            stopWrites()
            run { [weak self] in
                await self?.wipeLocal(.revoked)
                self?.startOutboxLoop()
            }
        }
    }

    private func syncStoreAccountToken() {
        let session = session
        run { [weak self] in
            let token = await session.storeAccountToken.flatMap(UUID.init(uuidString:))
            if self?.facade.storeAccountToken != token { self?.facade.storeAccountToken = token }
        }
    }

    func patched(_ response: UpdateMeResponse) {
        facade.person = response.person
        hostLookDelivered()
        if let problem = response.identityProblem ?? Self.identityProblem(in: response.rejected) {
            facade.reportIdentityProblem(problem)
        } else if response.person.level == .verified {
            signedIn()
        }
    }

    /// The person is verified now (a signed identity was accepted).
    ///
    /// Messages held because the app wants a sign-in go, even with the chat closed. Refused again, a message is simply
    /// held again.
    private func signedIn() {
        // The composer the sign-in closed opens again; a pause's hold still waits for its own answer.
        if conversation.policy.reason == .verificationRequired { conversation.policy = .open }
        let outbox = outbox
        run { [weak self] in
            guard await outbox.retryHeld(for: .verificationRequired) else { return }
            self?.publishPending(await outbox.all())
            self?.outboxWake.notify()
        }
    }

    /// A refused identity in `rejected[]` (`identity_user_mismatch`).
    ///
    /// Token problems come in `identityProblem`.
    static func identityProblem(in rejected: [RejectedField]) -> IdentityProblem? {
        guard let field = rejected.first(where: { $0.field.split(separator: ".").first == "identity" }) else { return nil }
        switch field.code {
        case ErrorCode.identityUserMismatch.rawValue: return .userMismatch
        default: return .unknown
        }
    }

    /// Maps request failures that reveal configuration problems (unknown key, paused app).
    func noteFailure(_ error: PingFrontError) {
        // A failure to reach the service sets it; an answer from the service, even an error (a 5xx), clears it.
        if error.isOffline {
            conversation.serverUnreachable = error.isServerUnreachable
        } else if case .server = error {
            conversation.serverUnreachable = false
        }
        // N10: any refused request (a session refresh, a thread load, a send) that says the person can't send closes the
        // composer now; the next thread load that allows sending reopens it.
        if let reason = SendPolicy.Reason(refusal: error.code) { closePolicy(reason) }
        switch error.code {
        case .invalidAppKey?:
            facade.report(
                ConfigurationProblem(
                    kind: .unknownKey,
                    message:
                        "The server does not know this app key (\(key.description)). Copy it again from Dashboard > App > Connect, and check test vs live.",
                    disablesSDK: false))
        case .appPaused?:
            facade.report(
                ConfigurationProblem(
                    kind: .appPaused, message: "This app is paused in the dashboard. Resume it in Dashboard > App > Settings.",
                    disablesSDK: false))
        case .threadReset?:
            // 409 thread_reset: the server replaced the thread. Drop the cache, keep the draft and outbox, reload.
            run { [weak self] in await self?.resetThread() }
        default: break
        }
        refreshCooldowns()
    }

    // MARK: Chat visibility

    func chatDidAppear() {
        noteActivity()
        guard !preview else { return }
        run { [weak self] in await self?.openThread() }
        updatePausedRecheck()
    }

    func chatDidDisappear() {
        noteActivity()
        updatePausedRecheck()
        setTyping(false)
        let live = live
        run { await live.stop() }
    }

    func openThread() async {
        // The spinner only before the first answer: a retry after a failed load keeps the welcome (offline,
        // unreachable) or the failure on screen instead of flashing the spinner every 5 s.
        if conversation.messages.isEmpty, conversation.phase == .idle { conversation.phase = .loading }
        do {
            _ = try await session.token(reason: .chatOpened)
        } catch {
            noteFailure(error)
            if conversation.messages.isEmpty, conversation.phase != .ready { conversation.phase = .failed(error) }
            conversation.live = .waiting(retryIn: .zero, offline: error.isOffline)
            scheduleOpenRetry()
            return
        }
        let testDevice = await session.testDevice
        let generation = await session.generation
        let config = await configStore.refresh(testDevice: testDevice)
        // A draft look fetched for the previous person never applies after logout.
        guard await session.generation == generation else {
            await configStore.clearDraft()
            return
        }
        if let config { apply(config) }
        await loadThread()
        // Paused, the server refuses the socket (and read receipts): no live connection until a load allows sending.
        // Blocked or verification required, live replies and reads still work.
        if facade.isChatVisible, !isPaused {
            await live.start(api.liveEndpoint(override: remoteConfig?.liveUrl))
        }
        outboxWake.notify()
    }

    private func scheduleOpenRetry() {
        run { [weak self] in
            guard let self, await self.time.pause(Timing.openRetry), self.facade.isChatVisible, await !self.session.isActive else { return }
            // Closed (the app paused, blocked, verification required): retrying every 5 s gets the same refusal. The
            // next chat open, foreground or live event tries again.
            guard self.conversation.policy.canSend else { return }
            await self.openThread()
        }
    }

    /// Sends a person-scoped request and returns `nil` when logout or erase happened while it was in
    /// flight: an answer for the previous person is never applied, shown or cached.
    func current<Response>(_ endpoint: Endpoint<Response>, reason: SessionReason = .chatOpened) async throws(PingFrontError) -> Response? {
        let generation = await session.generation
        let response = try await client.send(endpoint, reason: reason)
        guard await session.generation == generation, !Task.isCancelled else { return nil }
        return response
    }

    func loadThread() async {
        do {
            guard let response = try await current(Endpoints.thread()) else { return }
            threadLoadFailed = false
            conversation.serverUnreachable = false
            let wasPaused = isPaused
            await api.threadRevision.set(response.thread?.rev)
            conversation.replace(with: response)
            if let reason = response.policy.reason { policyClosed(reason) }
            defer { updatePausedRecheck() }
            if response.policy.canSend {
                reopened()
                // A socket that stopped after a refusal comes back with sending.
                if wasPaused, facade.isChatVisible {
                    let live = live
                    let endpoint = api.liveEndpoint(override: remoteConfig?.liveUrl)
                    run { await live.start(endpoint) }
                }
            }
            unread.set(response.thread?.unread ?? 0)
            cacheThread()
            if facade.isChatVisible, !isPaused { readReceipts.schedule() }
        } catch {
            threadLoadFailed = true
            noteFailure(error)
            if conversation.messages.isEmpty { conversation.phase = .failed(error) }
        }
    }

    func cacheThread() {
        let cached = CachedThread(
            messages: Array(conversation.messages.suffix(Limits.pageSize)), team: conversation.team,
            hasOlder: conversation.hasOlder || conversation.messages.count > Limits.pageSize)
        let threadCache = threadCache
        run { await threadCache.save(cached) }
    }

    /// Server `reset`, a new `rev` in `hello`, or 409 `thread_reset`: drop the cached thread and the stale
    /// revision, keep the draft and unsent messages, and reload.
    func resetThread() async {
        await api.threadRevision.set(nil)
        await threadCache.clear()
        conversation.clearThread()
        publishPending(await outbox.all())
        await loadThread()
        // The kept outbox goes out now, against the new thread and its revision.
        outboxWake.notify()
    }

    /// Pending rows: the outbox plus sends still preparing (or failed before they reached the outbox).
    func publishPending(_ outboxItems: [PendingMessage]) {
        let queued = Set(outboxItems.map(\.clientId))
        stagedSends.removeAll { queued.contains($0.clientId) && $0.state != .failed }
        conversation.setPending(outboxItems + stagedSends.filter { !queued.contains($0.clientId) })
    }

    // MARK: Live events

    private func handle(_ signal: LiveConnection.Signal) async {
        switch signal {
        case .state(let state):
            conversation.live = state
            if state == .live {
                conversation.serverUnreachable = false
                outboxWake.notify()
                // Back online: queued card reports go at once, then the backoff goes on.
                cardReportsWake.notify()
                // An action sent while the socket was down arrives here.
                catchUpTeamActions()
            }
        case .event(let event):
            await apply(event)
        case .refused(let error):
            // The live socket stopped after a refusal; a reason closes the composer as any refused request does. A
            // refused handshake carries no body (a WebSocket task exposes the response, not its body), so the thread is
            // read again: `GET /thread` is allowed while paused and its policy says why.
            if let error {
                noteFailure(error)
            } else {
                run { [weak self] in await self?.loadThread() }
            }
        }
    }

    package func apply(_ event: ServerEvent) async {
        switch event {
        case .hello(let lastSeq, _, let teamReadSeq, let rev, let status):
            if let rev {
                // A hello with no thread (rev 0) while we hold a revision is late, not news: the socket said hello
                // before the first send created the thread, whose revision came back in that send's
                // PF-Thread-Rev. A thread is never deleted without a merge or erase, and those give a new non-zero
                // revision (or end the session), so the hello is ignored instead of costing a reload.
                // A different non-zero revision means the thread was merged or reset while we were away.
                if let known = await api.threadRevision.value, rev != 0, known != rev {
                    await resetThread()
                    return
                }
                // No thread yet: there is no revision to send, so 0 is never stored.
                if rev != 0 { await api.threadRevision.set(rev) }
            }
            if let teamReadSeq { conversation.teamReadSeq = max(conversation.teamReadSeq, teamReadSeq) }
            if let status { conversation.status = status }
            if lastSeq > conversation.tracker.lastSeq {
                let before = Set(conversation.messages.map(\.id))
                let epoch = personEpoch
                let repaired = await repair(after: conversation.tracker.lastSeq)
                // Logged out or erased during the repair: the hello was the previous person's.
                guard epoch == personEpoch else { return }
                if repaired { conversation.tracker.advance(to: lastSeq) }
                announceNew(since: before)
            }
        case .message(let seq, let message), .messageUpdated(let seq, let message):
            let before = Set(conversation.messages.map(\.id))
            switch conversation.tracker.decide(seq) {
            case .apply, .duplicate:
                conversation.merge([message])
                conversation.tracker.advance(to: seq)
            case .gap(let after):
                let epoch = personEpoch
                let repaired = await repair(after: after)
                // Logged out or erased during the repair: the message and the repair belonged to the previous person.
                guard epoch == personEpoch else { return }
                conversation.merge([message])
                // A failed repair keeps lastSeq where it was, so the gap is fetched again after reconnecting.
                if repaired { conversation.tracker.advance(to: seq) }
            }
            if message.author.kind != .person { typing.messageArrived() }
            announceNew(since: before)
            cacheThread()
        case .typing(let kind, let name, let on):
            typing.received(kind: kind, name: name, on: on)
        case .read(let upToSeq):
            conversation.teamReadSeq = max(conversation.teamReadSeq, upToSeq)
        case .thread(let status):
            conversation.status = status
        case .reset:
            await resetThread()
        case .threadReset:
            // The team reset the conversation (a live `thread_reset`): the socket stays open. The cached thread, its
            // messages, the stored revision and the unread count go; the draft and the outbox stay (an unsent message
            // starts the new thread), and the reload shows the empty chat.
            unread.set(0)
            await resetThread()
        case .config(_, let draft):
            let testDevice = await session.testDevice
            guard !draft || testDevice else { return }
            if let config = await configStore.refresh(testDevice: testDevice, force: true) {
                apply(config)
                facade.emit(.lookChanged(revision: config.revision, draft: config.draft))
            }
        case .teamAction(let payload):
            await receiveTeamActions([payload])
        case .reauth, .unknown:
            break
        }
    }

    /// Every team or assistant message that appeared since `before` (live or repaired) counts as received:
    /// unread count, `messageReceived` and read receipts all see it.
    private func announceNew(since before: Set<String>) {
        for message in conversation.messages
        where !before.contains(message.id) && message.author.kind != .person && message.author.kind != .system {
            received(message)
        }
    }

    private func received(_ message: Message) {
        if facade.isChatVisible {
            if !isPaused { readReceipts.schedule() }
        } else {
            unread.increment()
        }
        facade.emit(
            .messageReceived(
                ReceivedMessage(
                    id: message.id, authorName: message.author.name, preview: String(message.plainText.prefix(140)),
                    isPing: message.ping != nil, isAI: message.author.kind == .ai)))
    }

    /// Fetches everything after `seq` (gap repair).
    ///
    /// On success the tracker moves to the highest seq fetched;
    /// on failure it stays, and the live socket reconnects after a backoff so the repair runs again.
    @discardableResult
    package func repair(after seq: Int) async -> Bool {
        var after = seq
        var highest = seq
        let epoch = personEpoch
        do throws(PingFrontError) {
            while true {
                guard let page = try await current(Endpoints.messages(after: after, limit: 200)), epoch == personEpoch else {
                    return false
                }
                conversation.merge(page.messages)
                highest = max(highest, page.messages.map(\.seq).max() ?? highest)
                guard page.hasMore, highest > after else { break }
                after = highest
            }
            conversation.tracker.advance(to: highest)
            repairFailures = 0
            return true
        } catch {
            Log.live(.info)?.info("Gap repair failed: \(error.logDescription, privacy: .public)")
            noteFailure(error)
            scheduleReconnectAfterRepairFailure()
            return false
        }
    }

    private func scheduleReconnectAfterRepairFailure() {
        let delay = Backoff.live.delay(attempt: repairFailures)
        repairFailures += 1
        let live = live
        let time = time
        let endpoint = api.liveEndpoint(override: remoteConfig?.liveUrl)
        run { [weak self] in
            guard await time.pause(delay), let self, self.facade.isChatVisible, await live.isRunning else { return }
            await live.reconnectNow(endpoint)
        }
    }

    func applyConfig(_ config: AppConfig) { apply(config) }

    private func apply(_ config: AppConfig) {
        remoteConfig = config
        conversation.refreshTeam(from: config.team)
        facade.refreshLook()
    }

    // MARK: Conversation driver

    private func delivered(_ message: Message) {
        // The send got through: the service is reachable again.
        conversation.serverUnreachable = false
        let known = conversation.messages.contains { $0.id == message.id }
        let repliesToPing = conversation.messages.last { !$0.isFromPerson && $0.author.kind != .system }?.ping != nil
        conversation.merge([message])
        if !known { facade.emit(.messageSent(SentMessage(message, repliesToPing: repliesToPing))) }
        noteActivity()
        cacheThread()
    }

    private func outboxLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            await outboxWake.wait()
            if Task.isCancelled { return }
            guard await session.isActive else { continue }
            while !Task.isCancelled {
                let uploadsPaused = await api.cooldowns.remaining(.uploads) != nil
                let result = await outbox.drain(uploadsPaused: uploadsPaused, deliver: deliverer())
                refreshCooldowns()
                guard case .retryLater(let error) = result else {
                    attempt = 0
                    break
                }
                noteFailure(error)
                let delay: Duration
                if case .coolingDown(_, let remaining) = error {
                    delay = remaining
                } else {
                    delay = Backoff.writes.delay(attempt: attempt)
                    attempt += 1
                }
                await outboxWake.wait(timeout: delay, time: time)
            }
        }
    }

    /// The delivery closure: uploads missing photos, then sends with the same clientId (idempotent).
    package func deliverer() -> Outbox.Deliver {
        let send = sender()
        return { [weak self] item async throws(PingFrontError) in
            do throws(PingFrontError) {
                return try await send(item)
            } catch {
                // N10: the server says the person can't send (blocked, paused, verification required): close the
                // composer now rather than at the next thread load, which reopens it when sending is allowed again.
                if let reason = SendPolicy.Reason(refusal: error.code) { await self?.closePolicy(reason) }
                // 409 thread_reset: reload the thread (the outbox stays) before the outbox sends it once more.
                if error.code == .threadReset { await self?.resetThread() }
                throw error
            }
        }
    }

    /// The app is paused: the server refuses the live socket, read receipts and unread reads (`app_paused`), unlike a
    /// blocked person or one who must verify, who keep live replies and reads.
    var isPaused: Bool { conversation.policy.reason == .appPaused }

    /// Closes the policy after a refused request.
    func closePolicy(_ reason: SendPolicy.Reason) {
        conversation.policy = .closed(reason)
        policyClosed(reason)
        updatePausedRecheck()
    }

    /// How often an open chat that is paused reads the thread again, to notice that the app was resumed.
    static let pausedRecheckInterval: Duration = .seconds(60)

    /// The open chat's slow check for a resume while the app is paused.
    ///
    /// `GET /thread` (allowed while paused) every 60 s on the injected clock, so the chat notices a resume without a
    /// foreground. One owned task, cancelled when the chat hides or the pause ends (Android and the web do the same).
    var pausedRecheck: Task<Void, Never>?

    func updatePausedRecheck() {
        guard facade.isChatVisible, isPaused, !preview else {
            pausedRecheck?.cancel()
            pausedRecheck = nil
            return
        }
        guard pausedRecheck == nil else { return }
        let time = time
        pausedRecheck = Task { [weak self] in
            while await time.pause(Self.pausedRecheckInterval) {
                guard let self, self.facade.isChatVisible, self.isPaused else { break }
                await self.loadThread()
            }
            // Ended by itself (resumed, or hidden between ticks), not replaced: forget it.
            if !Task.isCancelled { self?.pausedRecheck = nil }
        }
    }

    /// A blocked person is promised nothing: messages a pause or a required sign-in held stop waiting.
    private func policyClosed(_ reason: SendPolicy.Reason) {
        guard !reason.holdsMessages, reason != .unknown else { return }
        let outbox = outbox
        run { [weak self] in
            await outbox.releaseHeld()
            self?.publishPending(await outbox.all())
        }
    }

    /// `GET /unread` answered: a paused app refuses it, so the app is not paused (any other reason is the thread's to
    /// say, on its next load).
    ///
    /// Known paused in this process: sending reopens. Either way messages a pause held go, also those held before a
    /// relaunch, which this process never saw paused; messages held for a sign-in wait for a load that allows sending.
    private func unreadAnswered() {
        if isPaused {
            conversation.policy = .open
            reopened()
            updatePausedRecheck()
            return
        }
        let outbox = outbox
        run { [weak self] in
            guard await outbox.retryHeld(for: .appPaused) else { return }
            self?.publishPending(await outbox.all())
            self?.outboxWake.notify()
        }
    }

    /// Sending is allowed (again): messages a closed policy held go out, and the debug "app is paused" setup banner,
    /// now out of date, goes.
    private func reopened() {
        if case .appPaused? = facade.configurationProblem?.kind { facade.clearConfigurationProblem() }
        // Every load that allows sending, not only one that reopened it in this process: a message held before a
        // relaunch is persisted held and goes now.
        let outbox = outbox
        run { [weak self] in
            if await outbox.retryHeld() { self?.publishPending(await outbox.all()) }
            self?.outboxWake.notify()
            // Team action answers a pause kept go too.
            self?.acksWake.notify()
        }
    }

    /// Uploads missing photos, then sends with the same clientId.
    private func sender() -> Outbox.Deliver {
        let client = client
        let session = session
        let uploader = uploader
        let outbox = outbox
        return { item async throws(PingFrontError) in
            // A send that started before logout or erase must not reach the server for the next person.
            let generation = await session.generation
            _ = try await session.token(reason: .chatOpened)
            guard await session.generation == generation else { throw .cancelled }
            var attachmentIds: [String] = []
            for photo in item.photos {
                if let id = photo.attachmentId {
                    attachmentIds.append(id)
                    continue
                }
                guard let data = await outbox.photoData(photo) else { throw .invalidInput("The photo is no longer on this device.") }
                // A stable requestId per photo: a retry after a lost response returns the same attachment.
                let requestId = StableID.uuid(from: "\(item.clientId)/\(photo.file)")
                let id = try await uploader.upload(
                    data, width: photo.width, height: photo.height, sha256: photo.sha256, requestId: requestId)
                await outbox.recordUpload(clientId: item.clientId, file: photo.file, attachmentId: id)
                attachmentIds.append(id)
            }
            let request = SendMessageRequest(
                clientId: item.clientId, text: item.text, attachmentIds: attachmentIds.isEmpty ? nil : attachmentIds,
                replyToCard: item.replyToCard)
            guard await session.generation == generation, !Task.isCancelled else { throw .cancelled }
            return try await client.send(Endpoints.sendMessage(request)).message
        }
    }

    func refreshCooldowns() {
        let book = api.cooldowns
        let time = time
        run { [weak self] in
            let active = await book.active()
            let now = time.now()
            self?.conversation.cooldownDeadlines = active.mapValues { now + $0 }
        }
    }

    // MARK: Unread polling

    func noteActivity() { unread.noteActivity() }

    /// The host changed `PingFront.shared.language`: the server learns it with the next PATCH.
    package func languageChanged() {
        let session = session
        let coalescer = coalescer
        run {
            guard await session.isActive, let device = await session.currentDevice() else { return }
            await coalescer.stage(.device(device))
        }
    }

    func lifecycle(_ event: AppLifecycle.Event) {
        switch event {
        case .foreground:
            noteActivity()
            cardReportsWake.notify()
            // While the app is paused the server refuses the socket: the thread load decides when it opens again.
            if facade.isChatVisible, !preview, !isPaused {
                let live = live
                let endpoint = api.liveEndpoint(override: remoteConfig?.liveUrl)
                run { await live.reconnectNow(endpoint) }
            }
            // An open chat that is paused, or whose last thread load failed, reads the thread once (`GET /thread` is
            // allowed while paused): it learns that the app was resumed, or shows what it could not load. One read per
            // foreground, no loop.
            if facade.isChatVisible, !preview, isPaused || threadLoadFailed {
                run { [weak self] in await self?.loadThread() }
            }
            // Push stops the polling, and a paused app is not polled: check once on the way back (pushes may have been
            // missed; an answer while paused means the app was resumed).
            if unread.pushRegistered || isPaused, !facade.isChatVisible { run { [weak self] in await self?.unread.refresh() } }
            // Device facts can change in the background (time zone, locale, an app update).
            let session = session
            let coalescer = coalescer
            run {
                guard await session.isActive, let device = await session.currentDevice() else { return }
                await coalescer.stage(.device(device))
            }
        case .background:
            let live = live
            run { await live.stop() }
        case .protectedDataAvailable:
            // Work that waited for the Keychain or protected files (locked since restart) resumes now, with an erase a
            // logout owes (and that install's POST /me/logout).
            let outbox = outbox
            run { [weak self] in
                await outbox.load()
                self?.outboxWake.notify()
                if let self, self.facade.isChatVisible, !self.preview { await self.openThread() }
                if let self, !self.preview { await self.drainPendingLogouts() }
            }
        }
    }
}
