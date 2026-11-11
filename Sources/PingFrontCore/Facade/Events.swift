/// Events from `PingFront.shared.events`.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum PingFrontEvent: Sendable, Equatable {
    /// The chat became visible.
    case chatOpened
    /// The chat was closed.
    case chatClosed
    /// A team or assistant message arrived.
    case messageReceived(ReceivedMessage)
    /// The server accepted a message the person wrote (after any queueing and photo uploads).
    case messageSent(SentMessage)
    /// The person tapped a card (offer, review, link, report, store action) or answered one (choices, rating).
    case cardOpened(OpenedCard)
    /// The unread count changed.
    case unreadChanged(Int)
    /// A session started (lazily, on first use).
    case sessionStarted(PersonSummary)
    /// The server reported a problem with the identity token.
    case identityProblem(IdentityProblem)
    /// The person tapped an offer card.
    case offerRequested(OfferRequest)
    /// An offer module finished showing an offer (purchased, pending approval, cancelled, …).
    case offerCompleted(OfferRequest, OfferOutcome)
    /// The chat look changed (published or draft).
    case lookChanged(revision: Int, draft: Bool)
    /// A configuration problem was found.
    case configurationProblem(ConfigurationProblem)
    /// A bug report was sent.
    case reportSent
    /// The server revoked this install; the SDK started over as a guest.
    ///
    /// By design, everything local to the revoked install is dropped with it: its credentials, the cached thread and
    /// any messages still waiting in the outbox. The protocol requires this: queued sends are wiped and never sent
    /// under a new session. The person starts a new conversation; the next chat open creates a new session
    /// (`auth-refresh-revoked` in the protocol scenarios).
    case sessionRevoked
}

/// A summary of a received message, safe to show in an in-app banner.
public struct ReceivedMessage: Sendable, Equatable {
    /// Message id.
    public let id: String
    /// Author display name.
    public let authorName: String?
    /// The first text part, truncated.
    public let preview: String
    /// True when the team reached out before the person wrote.
    public let isPing: Bool
    /// True when written by the assistant.
    public let isAI: Bool
}

/// A summary of a message the person sent, for the host's analytics.
///
/// It carries no message text.
public struct SentMessage: Sendable, Equatable {
    /// Message id.
    public let id: String
    /// Characters of text (0 for a photo-only message).
    public let textLength: Int
    /// Photos attached.
    public let photoCount: Int
    /// True when the latest team message before it is a ping (the person is answering a ping).
    public let repliesToPing: Bool

    /// A summary (public for tests of a host's event handling).
    @_spi(Fixtures) public init(id: String, textLength: Int, photoCount: Int, repliesToPing: Bool) {
        self.id = id
        self.textLength = textLength
        self.photoCount = photoCount
        self.repliesToPing = repliesToPing
    }
}

/// A card the person tapped or answered.
public struct OpenedCard: Sendable, Equatable {
    /// What kind of card.
    public let kind: CardKind
    /// The card id.
    public let cardId: String
    /// The message the card is in.
    public let messageId: String

    /// A card event (public for tests of a host's event handling).
    @_spi(Fixtures) public init(kind: CardKind, cardId: String, messageId: String) {
        self.kind = kind
        self.cardId = cardId
        self.messageId = messageId
    }
}

/// A card kind, as on the wire (`offer`, `review`, …).
///
/// Open: kinds added later keep their wire name.
public struct CardKind: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    /// The wire name.
    public let rawValue: String
    /// A kind from its wire name.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// The wire name.
    public var description: String { rawValue }

    /// An offer card.
    public static let offer = CardKind(rawValue: "offer")
    /// A review ask.
    public static let review = CardKind(rawValue: "review")
    /// A link or deep link.
    public static let link = CardKind(rawValue: "link")
    /// Quick choices.
    public static let choices = CardKind(rawValue: "choices")
    /// A rating (CSAT).
    public static let rating = CardKind(rawValue: "rating")
    /// Report a problem.
    public static let report = CardKind(rawValue: "report")
    /// One of Apple's App Store sheets.
    public static let storeAction = CardKind(rawValue: "store_action")
}

extension Card {
    /// The card's kind.
    public var kind: CardKind {
        switch self {
        case .offer: .offer
        case .review: .review
        case .link: .link
        case .choices: .choices
        case .rating: .rating
        case .report: .report
        case .storeAction: .storeAction
        case .unknown(let kind, _): CardKind(rawValue: kind)
        }
    }
}

extension SentMessage {
    init(_ message: Message, repliesToPing: Bool) {
        var photos = 0
        for part in message.parts { if case .image = part { photos += 1 } }
        self.init(id: message.id, textLength: message.plainText.count, photoCount: photos, repliesToPing: repliesToPing)
    }
}

/// Multicasts events to every `events` stream.
///
/// No tasks: terminated streams are dropped on the next yield.
@MainActor final class EventHub {
    private var continuations: [AsyncStream<PingFrontEvent>.Continuation] = []

    func stream() -> AsyncStream<PingFrontEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: PingFrontEvent.self, bufferingPolicy: .bufferingNewest(32))
        continuations.append(continuation)
        return stream
    }

    func emit(_ event: PingFrontEvent) {
        continuations.removeAll { continuation in
            if case .terminated = continuation.yield(event) { return true }
            return false
        }
    }
}

/// What a silent push did, for the system's background-fetch result.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum BackgroundPushResult: Sendable, Equatable {
    /// Something changed (a new chat look was fetched).
    case newData
    /// Nothing to do, or nothing changed.
    case noData
    /// The fetch failed (offline, server error).
    case failed
}
