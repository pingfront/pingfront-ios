internal import os

/// The unread count: the single place it changes (emitting `.unreadChanged` only when the value
/// changes), and the `GET /unread` polling without push.
///
/// Polling runs every 20 s for two minutes after activity, then every two minutes for an hour, and
/// only while the chat is closed, push is off, and this install already has a session. While the app is
/// paused nothing is polled: the next foreground asks once, and an answer clears the pause (as on Android).
@MainActor
package final class UnreadMonitor {
    private weak var facade: PingFront?
    private let client: AuthorizedClient
    private let session: SessionStore
    private let time: TimeSource
    private let activityWake = WakeSignal()
    private var lastActivity: Duration = .zero
    private var loop: Task<Void, Never>?
    /// Push registered: the server pushes instead, so polling stops.
    package var pushRegistered = false
    /// Offline previews never poll.
    package var isPreview = false
    /// The service answered a read: the app is not paused (a paused app refuses it).
    package var answered: (@MainActor () -> Void)?

    package init(facade: PingFront, client: AuthorizedClient, session: SessionStore, time: TimeSource) {
        self.facade = facade
        self.client = client
        self.session = session
        self.time = time
    }

    /// The current count.
    package var count: Int { facade?.unreadCount ?? 0 }

    /// Sets the count.
    ///
    /// The only writer of `PingFront.unreadCount`.
    package func set(_ value: Int) {
        guard let facade, value != facade.unreadCount else { return }
        facade.unreadCount = max(value, 0)
        facade.emit(.unreadChanged(facade.unreadCount))
    }

    /// One more unread message.
    package func increment() { set(count + 1) }

    /// The person did something: polling speeds up again.
    package func noteActivity() {
        lastActivity = time.now()
        activityWake.notify()
    }

    package func start() {
        loop?.cancel()
        loop = Task { [weak self] in await self?.poll() }
    }

    package func stop() {
        loop?.cancel()
        loop = nil
    }

    /// `GET /unread`, only when this install already has a session (never creates one).
    package func refresh() async {
        guard !isPreview, await session.hasInstall() else { return }
        let generation = await session.generation
        do {
            let unread = try await client.send(Endpoints.unread(), reason: .prepare).unread
            // A count for the previous person (logout during the request) is dropped.
            guard await session.generation == generation else { return }
            set(unread)
            // A paused app refuses this read: an answer means it is not paused, so polling and sending come back and
            // messages a pause held go.
            answered?()
        } catch {
            // Paused: polling stops until something says it was resumed (this read on the next foreground, a thread
            // load that allows sending).
            if error.code == .appPaused { facade?.conversation.policy = .closed(.appPaused) }
            Log.network(.debug)?.debug("Unread check failed: \(error.logDescription, privacy: .public)")
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            await activityWake.wait()
            while !Task.isCancelled, let interval = UnreadSchedule.interval(sinceActivity: time.now() - lastActivity) {
                guard await time.pause(interval) else { return }
                // Paused, the server refuses the read (`app_paused`): nothing to poll until a load allows sending.
                guard facade?.isChatVisible == false, !pushRegistered, !isPreview,
                    facade?.conversation.policy.reason != .appPaused
                else { continue }
                await refresh()
            }
        }
    }
}

/// Read receipts: `POST /thread/read` half a second after new messages show while the chat is open.
@MainActor
package final class ReadReceipts {
    private weak var facade: PingFront?
    private let client: AuthorizedClient
    private let session: SessionStore
    private let time: TimeSource
    private let unread: UnreadMonitor
    private var pending: Task<Void, Never>?

    package init(facade: PingFront, client: AuthorizedClient, session: SessionStore, time: TimeSource, unread: UnreadMonitor) {
        self.facade = facade
        self.client = client
        self.session = session
        self.time = time
        self.unread = unread
    }

    /// Debounced: one receipt for a burst of messages.
    package func schedule() {
        pending?.cancel()
        let time = time
        pending = Task { [weak self] in
            guard await time.pause(Timing.readReceipt) else { return }
            await self?.send()
        }
    }

    package func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Marks the thread read now, visible or not: a custom chat UI says when the person has seen it.
    package func sendNow() {
        pending?.cancel()
        pending = Task { [weak self] in await self?.send(requireVisible: false) }
    }

    private func send(requireVisible: Bool = true) async {
        guard let facade, !requireVisible || facade.isChatVisible, let upTo = facade.conversation.messages.last?.seq, upTo > 0
        else { return }
        let generation = await session.generation
        do {
            let count = try await client.send(Endpoints.read(upTo: upTo)).unread
            guard await session.generation == generation else { return }
            unread.set(count)
        } catch {
            Log.network(.info)?.info("Read receipt failed: \(error.logDescription, privacy: .public)")
        }
    }
}

/// Typing in both directions: the person's typing goes out throttled (one event per 3 s, in order);
/// a teammate's typing shows the dots for at most 8 s.
///
/// Only a human teammate who is actually typing shows dots. Assistant and automated (play) messages
/// never get typing dots before them.
@MainActor
package final class TypingController {
    private weak var facade: PingFront?
    private let time: TimeSource
    private var sentAt: Duration?
    private var clear: Task<Void, Never>?
    private let outgoing: AsyncStream<Bool>.Continuation
    private var sender: Task<Void, Never>?
    /// Offline previews send nothing.
    package var isPreview = false

    package init(facade: PingFront, live: LiveConnection, time: TimeSource) {
        self.facade = facade
        self.time = time
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .unbounded)
        outgoing = continuation
        sender = Task { [live] in
            for await on in stream { await live.send(.typing(on: on)) }
        }
    }

    /// The person typed (or cleared the field).
    package func setTyping(_ on: Bool) {
        guard !isPreview else { return }
        let now = time.now()
        if on {
            if let sentAt, now - sentAt < LiveProtocol.typingThrottle { return }
            sentAt = now
        } else {
            guard sentAt != nil else { return }
            sentAt = nil
        }
        outgoing.yield(on)
    }

    /// A live `typing` event.
    package func received(kind: ServerEvent.TypingAuthorKind, name: String?, on: Bool) {
        guard let conversation = facade?.conversation else { return }
        clear?.cancel()
        // Dots only for a person on the team; the assistant's replies arrive without a typing preamble.
        guard on, kind == .team else {
            conversation.typing = nil
            return
        }
        conversation.typing = TypingIndicator(name: name, isAI: false)
        let time = time
        clear = Task { [weak self] in
            guard await time.pause(Timing.typingTimeout) else { return }
            self?.facade?.conversation.typing = nil
        }
    }

    /// A message arrived from the team or the assistant: the dots end.
    package func messageArrived() {
        clear?.cancel()
        facade?.conversation.typing = nil
    }

    package func stop() {
        clear?.cancel()
        sender?.cancel()
        outgoing.finish()
    }
}
