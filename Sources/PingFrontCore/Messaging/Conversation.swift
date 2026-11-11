public import Foundation
public import Observation

/// Who is typing.
public struct TypingIndicator: Sendable, Equatable {
    /// The teammate or assistant name.
    public var name: String?
    /// True when the assistant is typing.
    public var isAI: Bool

    /// Creates a typing indicator.
    @_spi(Fixtures) public init(name: String?, isAI: Bool) {
        self.name = name
        self.isAI = isAI
    }
}

/// The actions a conversation forwards to the engine.
@MainActor package protocol ConversationDriver: AnyObject {
    func send(text: String?, photos: [Data], replyTo: CardReply?)
    func retry(_ clientId: String)
    func discard(_ clientId: String)
    func loadOlder()
    func act(card: Card, messageId: String, answer: CardAnswer?)
    func setTyping(_ on: Bool)
    func reload()
    func reloadAndWait() async
    func markRead()
    func draftChanged(_ text: String)
    func photoData(_ photo: PendingMessage.Photo) async -> Data?
    func imageURL(_ part: ImagePart) async -> URL?
}

/// The thread as observable state, plus the actions a chat UI needs. `PingFrontUI` renders it;
/// teams building their own UI can use it directly from `PingFront.shared.conversation`.
@MainActor @Observable
public final class Conversation {
    /// Loading state of the thread.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Phase: Sendable, Equatable {
        /// Nothing loaded yet.
        case idle
        /// Loading the latest page.
        case loading
        /// Loaded (possibly from cache while offline).
        case ready
        /// Loading failed and nothing is cached.
        case failed(PingFrontError)
    }

    /// Loading state.
    public package(set) var phase: Phase = .idle
    /// Messages in sequence order.
    public package(set) var messages: [Message] = [] {
        didSet { rebuildTimeline() }
    }
    /// Messages the person sent that the server has not acknowledged.
    public package(set) var pending: [PendingMessage] = [] {
        didSet { rebuildTimeline() }
    }
    /// True when older messages can be loaded.
    public package(set) var hasOlder = false
    /// True while older messages are loading.
    public package(set) var isLoadingOlder = false
    /// The team, for the header and welcome.
    public package(set) var team: [TeamMember] = []

    /// The author as the chat shows it now: a teammate's current name and photo from ``team`` (they can change
    /// both in the dashboard), falling back to what the message carried when it was sent.
    public func displayAuthor(of message: Message) -> Author {
        guard message.author.kind == .team, let id = message.author.id, let member = team.first(where: { $0.id == id })
        else { return message.author }
        var author = message.author
        author.name = member.name
        author.avatarURL = member.avatarURL ?? message.author.avatarURL
        return author
    }

    /// Takes teammates' current names and photos from a newer app config, keeping the thread's own team list.
    package func refreshTeam(from members: [TeamMember]) {
        if team.isEmpty {
            team = members
            return
        }
        let byId = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = team.map { byId[$0.id] ?? $0 }
        if updated != team { team = updated }
    }
    /// The server's reply expectation, already localized.
    public package(set) var replyExpectation: String?
    /// Whether the person can send.
    public package(set) var policy: SendPolicy = .open
    /// Open or resolved.
    public package(set) var status: ThreadStatus = .open
    /// Who is typing right now.
    public package(set) var typing: TypingIndicator?
    /// The live channel state.
    public package(set) var live: LiveState = .stopped
    /// Active rate-limit cooldowns: scope to the monotonic deadline (see `cooldownRemaining`).
    package var cooldownDeadlines: [RateScope: Duration] = [:]
    /// The highest sequence number the team has read.
    public package(set) var teamReadSeq = 0
    /// The person's unsent text.
    ///
    /// Persisted between launches.
    public var draft: String = "" {
        didSet { if draft != oldValue { driver?.draftChanged(draft) } }
    }
    /// Text to put into the composer once (topic prefill, `openChat(topic:)`).
    ///
    /// The UI clears it.
    public var composerInsertion: String?

    @ObservationIgnored package weak var driver: (any ConversationDriver)?
    @ObservationIgnored package var time: TimeSource = .continuous
    @ObservationIgnored package var tracker = SeqTracker()

    /// An empty conversation.
    public init() {}

    /// The timeline the UI renders: messages and pending sends, grouped.
    ///
    /// Rebuilt when they change, never
    /// while a view renders.
    public private(set) var timeline: [TimelineItem] = []
    /// The timeline row id of the newest message the person wrote (for "Delivered" and "Read").
    public private(set) var lastPersonItemId: String?
    /// The seq of the newest message the person wrote.
    public private(set) var lastPersonSeq: Int?

    /// Bumped when something asks for the composer (opening the chat while an embedded one shows): the chat UI puts
    /// the cursor in it.
    package private(set) var composerFocusRequest = 0

    /// Asks the chat on screen to put the cursor in its composer.
    package func requestComposerFocus() { composerFocusRequest += 1 }

    /// Offer cards whose purchase waits for approval (Ask to Buy, Strong Customer Authentication).
    public package(set) var awaitingApproval: Set<String> = []

    /// Offer cards a newer offer card replaced: shown as one line, never stacked.
    public private(set) var supersededOfferCardIds: Set<String> = []

    private func rebuildTimeline() {
        let offers = messages.flatMap { message in
            message.parts.compactMap { part -> String? in
                if case .card(let card) = part, case .offer = card.card { return card.card.id }
                return nil
            }
        }
        supersededOfferCardIds = Set(offers.dropLast())
        timeline = Timeline.build(messages: messages, pending: pending)
        let last = messages.last { $0.author.kind == .person }
        lastPersonItemId = last.map { $0.clientId ?? $0.id }
        lastPersonSeq = last?.seq
    }

    /// True when the thread has no messages and nothing is pending (show the welcome).
    public var isEmpty: Bool { messages.isEmpty && pending.isEmpty }

    /// True when the device looks offline.
    public var isOffline: Bool {
        if case .waiting(_, let offline) = live { return offline }
        return false
    }

    /// The last request could not reach the service although the device has a network (see
    /// `PingFrontError.isServerUnreachable`); cleared by the next request that gets through or the live socket going
    /// live.
    package var serverUnreachable = false

    /// True when the chat can't reach its service although the device is online.
    ///
    /// The service is down, a firewall, a captive portal: the chat says it can't reach the chat instead of "You're
    /// offline". Messages still wait in the outbox and go when it is back. Set by a request that failed to find the
    /// host or to connect to it (`PingFrontError.isServerUnreachable`); never by a server error (a 5xx is an answer),
    /// a timeout or the live socket alone; cleared by the next request to the service that gets through, or when the
    /// live socket connects.
    public var isServerUnreachable: Bool {
        guard serverUnreachable else { return false }
        if isOffline { return true }
        if case .failed(let error) = phase { return error.isOffline }
        return false
    }

    /// Time left on a cooldown, or `nil`.
    public func cooldownRemaining(_ scope: RateScope) -> Duration? {
        guard let deadline = cooldownDeadlines[scope] else { return nil }
        let left = deadline - time.now()
        return left > .zero ? left : nil
    }

    /// A topic's starter text placed in the composer: the starter alone in an empty field; otherwise the
    /// starter on its own line before what the person typed, never replacing it (and never twice).
    nonisolated package static func inserting(_ insertion: String, into draft: String) -> String {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { return insertion }
        if typed.hasPrefix(insertion.trimmingCharacters(in: .whitespacesAndNewlines)) { return draft }
        return insertion.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + typed
    }

    /// Sends text and photos (any image data; re-encoded as JPEG ≤ 2 MB, ≤ 2400 px).
    ///
    /// Returns immediately;
    /// the message shows as pending and is delivered by the outbox, also after relaunch.
    public func send(text: String, photos: [Data] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !photos.isEmpty else { return }
        driver?.send(text: trimmed.isEmpty ? nil : trimmed, photos: photos, replyTo: nil)
    }

    /// Retries a failed message with the same idempotency key.
    public func retry(_ message: PendingMessage) { driver?.retry(message.clientId) }

    /// Removes a failed message from the queue.
    public func discard(_ message: PendingMessage) { driver?.discard(message.clientId) }

    /// The most messages kept in memory.
    package static let window = 500

    /// Loads the previous page (call when the top of the list appears).
    ///
    /// Stops at the in-memory window.
    public func loadOlder() {
        guard hasOlder, !isLoadingOlder, messages.count < Self.window else { return }
        driver?.loadOlder()
    }

    /// Picks an option on a choices card.
    public func choose(_ option: ChoicesCard.Option, on card: ChoicesCard, in message: Message) {
        driver?.act(card: .choices(card), messageId: message.id, answer: .choice(id: option.id))
    }

    /// Rates on a rating card, clamped to the card's scale (`1...card.scale`).
    public func rate(_ rating: Int, on card: RatingCard, in message: Message) {
        driver?.act(card: .rating(card), messageId: message.id, answer: .rating(min(max(rating, 1), max(card.scale, 1))))
    }

    /// Opens a card's action (offer, review, link, report).
    public func open(_ card: Card, in message: Message) {
        driver?.act(card: card, messageId: message.id, answer: nil)
    }

    /// Tells the team the person is typing (throttled to one event per 3 s).
    public func setTyping(_ on: Bool) { driver?.setTyping(on) }

    /// Reloads the thread.
    public func reload() { driver?.reload() }

    /// Reloads the thread and returns when the reload has finished.
    ///
    /// When it failed, `phase` says why (`.failed`) for a thread with nothing to show; a thread already on screen
    /// stays. For pull to refresh in a custom UI:
    ///
    /// ```swift
    /// List(conversation.timeline) { … }
    ///     .refreshable { await conversation.reload() }
    /// ```
    public func reload() async { await driver?.reloadAndWait() }

    /// Marks every message on screen as read, for a chat UI of your own.
    ///
    /// The SDK's own chat does this by itself while it is visible. A custom UI calls it when the person has seen the
    /// thread (for example when it appears, and when new messages arrive while it shows): the team sees Read, and
    /// `PingFront.shared.unreadCount` drops to 0. Nothing is sent when there is nothing to mark, or while the app is
    /// paused.
    public func markRead() { driver?.markRead() }

    /// The JPEG bytes of a photo that is still waiting to be sent.
    public func photoData(for photo: PendingMessage.Photo) async -> Data? { await driver?.photoData(photo) }

    /// A fresh URL for an image whose short-lived URL expired.
    public func refreshedURL(for image: ImagePart) async -> URL? { await driver?.imageURL(image) }

    // MARK: State updates (engine)

    /// Inserts or replaces messages by id, drops pending items they acknowledge, keeps seq order.
    package func merge(_ incoming: [Message]) {
        guard !incoming.isEmpty else { return }
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for message in incoming { byId[message.id] = message }
        let newest = messages.last?.seq ?? 0
        var merged = byId.values.sorted { $0.seq == $1.seq ? $0.createdAt < $1.createdAt : $0.seq < $1.seq }
        // A bounded window: when newer messages push past it, the oldest leave memory (they load again
        // on scroll). Older pages never evict the newest.
        if merged.count > Self.window, (incoming.map(\.seq).max() ?? 0) > newest {
            merged.removeFirst(merged.count - Self.window)
            hasOlder = true
        }
        messages = merged
        let acknowledged = Set(incoming.compactMap(\.clientId))
        if !acknowledged.isEmpty { pending.removeAll { acknowledged.contains($0.clientId) } }
        // The seq tracker is not advanced here: only live events and successful repairs move it, so an
        // acknowledged send, older pages or a report never hide a gap in the team's messages.
    }

    /// Replaces the whole thread (first load, reset).
    package func replace(with response: ThreadResponse) {
        messages = response.messages.sorted { $0.seq < $1.seq }
        hasOlder = response.hasOlder
        if !response.team.isEmpty { team = response.team }
        replyExpectation = response.replyExpectation
        policy = response.policy
        status = response.thread?.status ?? .open
        teamReadSeq = max(teamReadSeq, response.thread?.teamReadSeq ?? 0)
        tracker.reset(to: max(response.thread?.lastSeq ?? 0, messages.last?.seq ?? 0))
        let acknowledged = Set(messages.compactMap(\.clientId))
        pending.removeAll { acknowledged.contains($0.clientId) }
        phase = .ready
    }

    /// Sets the pending queue, hiding items the server already acknowledged.
    package func setPending(_ items: [PendingMessage]) {
        let acknowledged = Set(messages.compactMap(\.clientId))
        pending = items.filter { !acknowledged.contains($0.clientId) }
    }

    /// Clears the thread after a server `reset`, keeping the person's draft and unsent messages.
    package func clearThread() {
        messages = []
        hasOlder = false
        isLoadingOlder = false
        typing = nil
        status = .open
        teamReadSeq = 0
        phase = .idle
        tracker.reset(to: 0)
    }

    /// Clears everything (logout, erase).
    package func clear() {
        awaitingApproval = []
        messages = []
        pending = []
        hasOlder = false
        isLoadingOlder = false
        typing = nil
        policy = .open
        status = .open
        teamReadSeq = 0
        draft = ""
        phase = .idle
        tracker.reset(to: 0)
    }
}

/// One row of the timeline with its grouping.
public struct TimelineItem: Sendable, Equatable, Identifiable {
    /// Which side of the thread a row sits on.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Side: Sendable, Equatable {
        /// Left: team and AI.
        case team
        /// Right: the person.
        case person
        /// Centered: receipts and system lines.
        case system
    }
    /// What the row shows.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Content: Sendable, Equatable {
        /// A delivered message.
        case message(Message)
        /// A message waiting for the server.
        case pending(PendingMessage)
    }

    /// Stable id (message id or clientId).
    public var id: String
    /// The content.
    public var content: Content
    /// Which side.
    public var side: Side
    /// First row of a group from the same author (show the author name).
    public var startsGroup: Bool
    /// Last row of a group (show the timestamp, avatar, hand-off line).
    public var endsGroup: Bool
    /// First row of a run of pings (show the ping mark and its line).
    public var startsPing: Bool
    /// Written by the assistant (always labelled).
    public var isAI: Bool
    /// The author's display name.
    public var authorName: String?
    /// When it was written.
    public var date: Date
    /// First row after a pause of more than 5 minutes (or the first row): show a centered time caption.
    public var startsTimeSection = false
}

package enum Timeline {
    /// Rows from the same author within this window form a group.
    package static let groupWindow: Duration = .seconds(300)

    package static func build(messages: [Message], pending: [PendingMessage]) -> [TimelineItem] {
        var items: [TimelineItem] = []
        items.reserveCapacity(messages.count + pending.count)
        for message in messages {
            let side: TimelineItem.Side =
                switch message.author.kind {
                case .person: .person
                case .system: .system
                case .team, .ai, .unknown: message.parts.allSatisfy(isReceipt) ? .system : .team
                }
            items.append(
                TimelineItem(
                    // A sent message keeps the row id its pending row had, so acknowledgement never
                    // re-inserts (and re-animates) the row.
                    id: message.clientId ?? message.id,
                    content: .message(message),
                    side: side,
                    startsGroup: true,
                    endsGroup: true,
                    startsPing: false,
                    isAI: message.author.kind == .ai,
                    authorName: message.author.name,
                    date: message.createdAt
                ))
        }
        for message in pending {
            items.append(
                TimelineItem(
                    id: message.clientId, content: .pending(message), side: .person, startsGroup: true, endsGroup: true, startsPing: false,
                    isAI: false, authorName: nil, date: message.createdAt))
        }
        for index in items.indices {
            let previous = index > 0 ? items[index - 1] : nil
            items[index].startsTimeSection =
                previous.map { Duration.seconds(items[index].date.timeIntervalSince($0.date)) > groupWindow } ?? true
            let next = index + 1 < items.count ? items[index + 1] : nil
            items[index].startsGroup = !(previous.map { sameGroup($0, items[index]) } ?? false)
            items[index].endsGroup = !(next.map { sameGroup(items[index], $0) } ?? false)
            if case .message(let message) = items[index].content, let ping = message.ping {
                var previousPing: PingOrigin?
                var previousAuthor: Author?
                if case .message(let prior)? = previous?.content {
                    previousPing = prior.ping
                    previousAuthor = prior.author
                }
                items[index].startsPing = previousPing == nil || previousAuthor != message.author || previousPing?.playId != ping.playId
            }
        }
        return items
    }

    private static func isReceipt(_ part: MessagePart) -> Bool {
        if case .receipt = part { return true }
        return false
    }

    private static func authorKey(_ item: TimelineItem) -> String {
        switch item.content {
        case .message(let message): "\(message.author.kind.rawValue):\(message.author.id ?? message.author.name ?? "")"
        case .pending: "person:"
        }
    }

    private static func sameGroup(_ a: TimelineItem, _ b: TimelineItem) -> Bool {
        guard a.side == b.side, a.side != .system, authorKey(a) == authorKey(b) else { return false }
        // A new ping run always starts a new group so its line sits above it.
        if case .message(let message) = b.content, message.ping != nil {
            if case .message(let prior) = a.content, prior.ping?.playId == message.ping?.playId, prior.ping != nil {} else { return false }
        }
        let gap = b.date.timeIntervalSince(a.date)
        return gap >= 0 && Duration.seconds(gap) <= groupWindow
    }
}
