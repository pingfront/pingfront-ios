public import Foundation

/// An action a teammate ran from the inbox that your app has to do ("Fix it for them"), such as extending a trial
/// or repairing a sync.
///
/// Read them from ``PingFront/teamActions``. Do the work once per ``id``, then call ``complete()`` or
/// ``fail(message:)``. When ``ackRequired`` is true the receipt line in the thread waits for `complete()`.
/// The same action may also reach your server as a signed webhook; do it in one place.
public struct TeamAction: Sendable, Identifiable {
    /// This run's id.
    ///
    /// Do the work once per id.
    public let id: String
    /// Which action: `extend_trial`, `grant_access`, or the id of one of your own actions.
    public let actionId: String
    /// The action's name, as your team sees it.
    public let name: String
    /// The values the teammate filled in, by field key.
    public let fields: [String: String]
    /// Days, for `extend_trial` and `grant_access`.
    public let days: Int?
    /// The new end of access, for `extend_trial` and `grant_access`.
    public let until: Date?
    /// True when the receipt line in the thread waits for ``complete()``.
    public let ackRequired: Bool
    /// When the teammate ran it.
    public let createdAt: Date
    /// After this the action expires and nothing is posted.
    public let expiresAt: Date

    let answer: @Sendable (TeamActionAck) async -> Void

    package init(_ payload: TeamActionPayload, answer: @escaping @Sendable (TeamActionAck) async -> Void) {
        id = payload.id
        actionId = payload.actionId
        name = payload.name
        fields = payload.fields
        days = payload.days
        until = payload.until
        ackRequired = payload.ackRequired
        createdAt = payload.createdAt
        expiresAt = payload.expiresAt
        self.answer = answer
    }

    /// Tells the team the action is done; the receipt line posts in the thread.
    ///
    /// Stored and retried until the server has it. The first answer wins.
    public func complete() async { await answer(TeamActionAck(ok: true)) }

    /// Tells the team the action could not be done.
    ///
    /// - Parameter message: What went wrong, shown to the team and never to the person (at most 200
    ///   characters).
    public func fail(message: String) async { await answer(TeamActionAck(ok: false, message: message)) }
}

/// Delivers team actions to every ``PingFront/teamActions`` stream, once per action id.
///
/// Actions not answered yet are replayed to each new stream, so one that arrives before the app starts listening
/// is not lost.
@MainActor final class TeamActionHub {
    private var continuations: [AsyncStream<TeamAction>.Continuation] = []
    /// Delivered and not answered yet, oldest first.
    private var open: [TeamAction] = []
    /// Every action id delivered or answered since the last logout.
    private var seen: Set<String> = []
    /// Action ids the app answered since the last logout (the first answer wins).
    private var answeredIds: Set<String> = []

    func stream() -> AsyncStream<TeamAction> {
        let (stream, continuation) = AsyncStream.makeStream(of: TeamAction.self, bufferingPolicy: .unbounded)
        for action in open { continuation.yield(action) }
        continuations.append(continuation)
        return stream
    }

    /// Delivers `action` unless its id was seen before.
    ///
    /// Returns whether it was delivered.
    @discardableResult
    func deliver(_ action: TeamAction) -> Bool {
        guard seen.insert(action.id).inserted else { return false }
        open.append(action)
        continuations.removeAll { continuation in
            if case .terminated = continuation.yield(action) { return true }
            return false
        }
        return true
    }

    func isKnown(_ id: String) -> Bool { seen.contains(id) }

    /// The app answered: stop replaying it.
    ///
    /// Returns false for a second answer, which is ignored.
    @discardableResult
    func answered(_ id: String) -> Bool {
        seen.insert(id)
        open.removeAll { $0.id == id }
        return answeredIds.insert(id).inserted
    }

    /// Logout or erase: the next person starts with nothing.
    func reset() {
        open = []
        seen = []
        answeredIds = []
    }
}
