public import Foundation

/// The outcome of `PingFront.shared.moment(_:props:)`.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum MomentResult: Sendable, Equatable {
    /// The moment is not listened to by any play, so nothing was sent.
    case notListened
    /// Sent; no play reacted.
    case ignored
    /// A play scheduled a ping.
    case scheduled
    /// A ping was delivered now.
    case delivered
    /// The person is in a holdout group for this play.
    case heldOut
    /// The server asked to open the chat. `presented` is `true` when the SDK presented it, and `false`
    /// when `presentsChatForMoments` is off (present it yourself when it suits the screen).
    case openRequested(presented: Bool)
    /// The moment name is invalid (`[a-z0-9][a-z0-9_.-]{0,63}`).
    case invalidName
    /// Sending failed.
    case failed(PingFrontError)
}

/// Caches `GET /moments/listened` for 5 minutes so only listened moments are sent.
package actor MomentGate {
    package static let ttl: Duration = .seconds(300)
    private let time: TimeSource
    private var names: Set<String> = []
    private var storeEvents: Set<String> = []
    private var fetchedAt: Duration?

    package init(time: TimeSource) { self.time = time }

    package func isFresh() -> Bool {
        guard let fetchedAt else { return false }
        return time.now() - fetchedAt < Self.ttl
    }

    package func contains(_ name: String) -> Bool { names.contains(name) }

    /// True when a live play reacts to this store event (`trial_started`, `refunded`, …).
    package func listensToStoreEvent(_ name: String) -> Bool { storeEvents.contains(name) }

    package func update(_ listened: [String], storeEvents events: [String] = []) {
        names = Set(listened)
        storeEvents = Set(events)
        fetchedAt = time.now()
    }

    package static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...64).contains(bytes.count) else { return false }
        func lowerOrDigit(_ b: UInt8) -> Bool { (97...122).contains(b) || (48...57).contains(b) }
        guard lowerOrDigit(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { lowerOrDigit($0) || $0 == 95 || $0 == 46 || $0 == 45 }
    }
}

/// A purchase or subscription change a store module detected on the device.
public struct StoreEventReport: Sendable, Equatable {
    /// The normalized event: `trial_started`, `trial_converted`, `trial_cancelled`, `trial_expired`,
    /// `subscription_started`, `subscription_renewed`, `subscription_cancelled`, `billing_issue`,
    /// `subscription_expired` or `refunded`.
    public var name: String
    /// The store product id.
    public var productId: String
    /// The store transaction id.
    public var transactionId: String?
    /// The first transaction of the subscription.
    public var originalTransactionId: String?
    /// Decimal price in `currency`, for example `"9.99"`.
    public var price: String?
    /// ISO 4217 currency code.
    public var currency: String?
    /// StoreKit 2 `jwsRepresentation`.
    ///
    /// Without it the server never links the transaction to the person.
    public var signedTransaction: String?
    /// When it happened.
    public var occurredAt: Date
    /// Idempotency key; the same transaction and event always report once.
    public var clientId: String

    /// Creates a store event report.
    public init(
        name: String, productId: String, transactionId: String? = nil, originalTransactionId: String? = nil,
        price: String? = nil, currency: String? = nil, signedTransaction: String? = nil, occurredAt: Date, dedupeKey: String? = nil
    ) {
        self.name = name
        self.productId = productId
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.price = price
        self.currency = currency
        self.signedTransaction = signedTransaction
        self.occurredAt = occurredAt
        // The same detection always has the same clientId, so the server stores it once.
        self.clientId = StableID.uuid(from: "store/\(name)/\(dedupeKey ?? transactionId ?? productId)")
    }

    var props: StoreMomentProps {
        StoreMomentProps(
            productId: String(productId.prefix(100)), transactionId: transactionId, originalTransactionId: originalTransactionId,
            price: price, currency: currency, signedTransaction: signedTransaction.flatMap { $0.count <= 16_000 ? $0 : nil }
        )
    }
}

/// Unread polling without push: every 20 s for 2 minutes after the last activity,
/// then every 2 minutes for an hour, then stop until the next foreground.
package enum UnreadSchedule {
    package static func interval(sinceActivity elapsed: Duration) -> Duration? {
        if elapsed < Timing.unreadFastFor { return Timing.unreadFast }
        if elapsed < Timing.unreadFastFor + Timing.unreadSlowFor { return Timing.unreadSlow }
        return nil
    }
}
