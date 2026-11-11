import Foundation

/// Reads the device context groups.
///
/// Every reader is cheap and non-blocking. Production uses `.system`; tests inject their own.
package struct ContextSource: Sendable {
    package var build: @Sendable () async -> BuildContext?
    package var display: @Sendable () async -> DisplayContext?
    /// The network path, as it changes (`lowPower` is read separately); the first value is the current path.
    package var paths: @Sendable () -> AsyncStream<ConnectionContext>
    /// Low Power Mode.
    package var lowPower: @Sendable () -> Bool?
    /// Battery, thermal state; `memoryPressure` is filled in by the reporter.
    package var health: @Sendable () async -> HealthContext?
    package var notifications: @Sendable () async -> NotificationContext?
    /// Memory warnings, observed passively (nothing is read or sent when one arrives).
    package var memoryWarnings: @Sendable () -> AsyncStream<Void>

    package init(
        build: @escaping @Sendable () async -> BuildContext?, display: @escaping @Sendable () async -> DisplayContext?,
        paths: @escaping @Sendable () -> AsyncStream<ConnectionContext>, lowPower: @escaping @Sendable () -> Bool?,
        health: @escaping @Sendable () async -> HealthContext?, notifications: @escaping @Sendable () async -> NotificationContext?,
        memoryWarnings: @escaping @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } }
    ) {
        self.build = build
        self.display = display
        self.paths = paths
        self.lowPower = lowPower
        self.health = health
        self.notifications = notifications
        self.memoryWarnings = memoryWarnings
    }
}

/// Decides which `DeviceContext` groups ride on the requests the SDK makes anyway (`POST /sessions`,
/// `POST /sessions/refresh`, `PATCH /me`). It never makes a request of its own and never logs a value.
///
/// - Session start (create, and the first request in this process that carries context, which for a new install is
///   the one after its first answer): every allowed group, health included.
/// - Later requests: `build`, `display` and `notifications` when they changed since they were last sent;
///   `connection` when it changed and at least 5 minutes after it was last sent; never `health`.
/// - Only the groups the latest `ContextCollection` allows (kept on disk with the install); no group at all until
///   the install's first answer.
///
/// Drafts are two-phase: a group counts as sent only after the request carrying it succeeded.
package actor ContextReporter {
    package enum Moment: Sendable {
        case create, refresh, patch
    }

    /// What one request carries, and what to mark as sent once it succeeds.
    package struct Draft: Sendable {
        package let context: DeviceContext
        let sessionStart: Bool
        let at: Duration
    }

    private let source: ContextSource
    private let persistence: (any Persistence)?
    private let time: TimeSource
    private let connectionInterval: Duration
    private let memoryWindow: Duration

    private var collection: ContextCollection?
    private var sent = DeviceContext()
    private var connectionSentAt: Duration?
    /// Session-start context went out in this process (health then waits for the next process or login).
    private var sessionStartSent = false
    private var path: ConnectionContext?
    private var pathTask: Task<Void, Never>?
    private var pathWaiters: [CheckedContinuation<Void, Never>] = []
    private var memoryWarningAt: Duration?
    private var memoryTask: Task<Void, Never>?

    package init(
        source: ContextSource,
        persistence: (any Persistence)?,
        time: TimeSource,
        connectionInterval: Duration = Timing.contextConnectionInterval,
        memoryWindow: Duration = Timing.contextMemoryWindow
    ) {
        self.source = source
        self.persistence = persistence
        self.time = time
        self.connectionInterval = connectionInterval
        self.memoryWindow = memoryWindow
    }

    deinit {
        pathTask?.cancel()
        memoryTask?.cancel()
    }

    // MARK: Collection

    /// The groups the app collects (persisted with the install), or `nil` before the first session answer.
    ///
    /// Until the server says which groups the app's privacy switches leave on, nothing is sent.
    package func currentCollection() async -> ContextCollection? {
        if let collection { return collection }
        if let data = try? await persistence?.read(Files.contextCollection),
            let stored = try? WireJSON.decode(ContextCollection.self, from: data)
        {
            collection = stored
            return stored
        }
        return nil
    }

    /// A session answer arrived: keep its `collect` (absent means every group) with the install.
    package func update(collection value: ContextCollection?) async {
        let next = value ?? .all
        guard next != collection else { return }
        collection = next
        if let data = try? WireJSON.encode(next) { try? await persistence?.write(Files.contextCollection, data) }
    }

    // MARK: Drafts

    /// The context for a request that is going out anyway, or `nil` when there is nothing to add.
    package func draft(for moment: Moment) async -> Draft? {
        // The switches aren't known yet (a new install's first session): no context at all.
        guard let allowed = await currentCollection() else { return nil }
        // A create, or the first request in this process that carries context: for a new install whose create went
        // out before its switches were known, that is the request after the answer, whatever it is (as the protocol defines it).
        let start = moment == .create || !sessionStartSent
        if start { await startPathMonitor() }
        let now = time.now()
        var context = DeviceContext()
        if allowed.build, let build = await source.build(), start || build != sent.build { context.build = build }
        if allowed.display, let display = await source.display(), start || display != sent.display { context.display = display }
        if allowed.notifications, let notifications = await source.notifications(), start || notifications != sent.notifications {
            context.notifications = notifications
        }
        if allowed.connection, let connection = currentConnection() {
            let due = connectionSentAt.map { now - $0 >= connectionInterval } ?? true
            if start || (connection != sent.connection && due) { context.connection = connection }
        }
        if start, allowed.health, var health = await source.health() {
            health.freeStorage = nil
            let warned = memoryWarningAt.map { now - $0 < memoryWindow } ?? false
            health.memoryPressure = warned ? .warning : .normal
            context.health = health
        }
        guard !context.isEmpty else { return nil }
        return Draft(context: context, sessionStart: start, at: now)
    }

    /// The request carrying `draft` succeeded (or the server answered it): its groups count as sent.
    package func delivered(_ draft: Draft) {
        let context = draft.context
        if let build = context.build { sent.build = build }
        if let display = context.display { sent.display = display }
        if let notifications = context.notifications { sent.notifications = notifications }
        if let connection = context.connection {
            sent.connection = connection
            connectionSentAt = draft.at
        }
        if draft.sessionStart { sessionStartSent = true }
    }

    // MARK: Observation

    /// Starts observing memory warnings (passive; nothing is read or sent when one arrives).
    package func observeMemoryWarnings() {
        guard memoryTask == nil else { return }
        let warnings = source.memoryWarnings()
        memoryTask = Task { [weak self] in
            for await _ in warnings { await self?.noteMemoryWarning() }
        }
    }

    private func noteMemoryWarning() { memoryWarningAt = time.now() }

    /// The path monitor starts with the first session request (never at launch) and runs until `reset()`.
    ///
    /// The session request waits for the first path, which the monitor delivers right away.
    private func startPathMonitor() async {
        if pathTask == nil {
            let paths = source.paths()
            pathTask = Task { [weak self] in
                for await path in paths { await self?.record(path) }
                await self?.pathsEnded()
            }
        }
        guard path == nil, pathTask != nil else { return }
        // Bounded: a path that is slow to arrive never holds the session up for long.
        let timeout = Task { [time, weak self] in
            if await time.pause(Timing.contextPathWait) { await self?.resumeWaiters() }
        }
        await withCheckedContinuation { pathWaiters.append($0) }
        timeout.cancel()
    }

    private func record(_ value: ConnectionContext) {
        path = value
        resumeWaiters()
    }

    private func pathsEnded() { resumeWaiters() }

    private func resumeWaiters() {
        let waiters = pathWaiters
        pathWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func currentConnection() -> ConnectionContext? {
        guard var value = path else { return nil }
        value.lowPower = source.lowPower()
        return value
    }

    /// The latest network path, for tests.
    package var latestPath: ConnectionContext? { path }

    /// Logout, erase or teardown: stop observing the path and forget what was sent.
    ///
    /// The next session is a session start. The collection stays: it belongs to the app, not the person.
    package func reset() {
        pathTask?.cancel()
        pathTask = nil
        path = nil
        resumeWaiters()
        sent = DeviceContext()
        connectionSentAt = nil
        sessionStartSent = false
    }

    /// Teardown: `reset()` and stop observing memory warnings.
    package func stop() {
        reset()
        memoryTask?.cancel()
        memoryTask = nil
    }
}
