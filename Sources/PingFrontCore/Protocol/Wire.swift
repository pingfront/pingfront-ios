public import Foundation

// Value types mirroring the component schemas of the pingfront protocol. Every model is a Sendable value type.

/// Limits shared by every SDK and the API (the protocol's `x-limit` values).
package enum Limits {
    /// Maximum characters in one message.
    package static let textChars = 4000
    /// Maximum images in one message.
    package static let imagesPerMessage = 6
    /// Maximum bytes per uploaded image.
    package static let imageBytes = 2 * 1024 * 1024
    /// Maximum pixel length of an image's longest edge.
    package static let imageMaxEdge = 2400
    /// Maximum number of traits.
    package static let traits = 30
    /// Maximum characters in a trait key.
    package static let traitKeyChars = 64
    /// Maximum characters in a trait value.
    package static let traitValueChars = 512
    /// Maximum characters in a user id.
    package static let userIdChars = 255
    /// Maximum characters in a name.
    package static let nameChars = 200
    /// Maximum characters in an email address.
    package static let emailChars = 254
    /// Maximum characters in an identity token.
    package static let identityTokenChars = 4096
    /// Default page size.
    package static let pageSize = 50
    /// Maximum bytes of log tail in a bug report.
    package static let reportLogBytes = 64 * 1024
}

/// The platform an install runs on.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum Platform: String, Sendable, Codable { case ios, android, web, macos }

/// Device facts sent with a session.
///
/// No advertising identifiers.
package struct Device: Codable, Sendable, Equatable {
    package struct SDK: Codable, Sendable, Equatable {
        package var name: String
        package var version: String
    }
    package struct App: Codable, Sendable, Equatable {
        package var version: String
        package var build: String
        package var bundleId: String
        /// The registered screens (`AppInfo.screens`), only on the requests that carry them (`ScreensReporter`).
        package var screens: [AppScreen]?
    }
    package var installId: String
    package var platform: Platform
    package var sdk: SDK
    package var app: App
    package var os: String
    package var model: String
    package var locale: String
    package var language: String
    package var timeZone: String
    /// Coarse device context, attached only to the request it rides on (`ContextReporter`); `nil` in the
    /// staged profile, so a context change alone never makes a `PATCH /me`.
    package var context: DeviceContext?
}

/// Who the person is in the host app.
///
/// A `token` makes them verified.
package struct Identity: Codable, Sendable, Equatable {
    package var userId: String
    package var name: String?
    package var email: String?
    package var token: String?
}

/// The person's subscription state, as the app or a store module knows it.
public struct Entitlement: Codable, Sendable, Equatable, Hashable {
    /// Subscription lifecycle states.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum State: String, Codable, Sendable, CaseIterable, TolerantStringEnum {
        case none, trial, active, grace
        case billingRetry = "billing_retry"
        case cancelled, expired, lifetime
        /// A state this SDK version does not know. Never sent.
        case unknown
        package static var fallback: State { .unknown }
        /// Decodes the raw value; values this SDK version does not know become `.unknown`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Where the entitlement came from.
    ///
    /// A struct, so vendor adapters can name their own source without an SDK update.
    public struct Source: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        /// The source name.
        public let rawValue: String
        /// Wraps a source name.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// The source name.
        public var description: String { rawValue }

        /// StoreKit 2.
        public static let storekit = Source(rawValue: "storekit")
        /// Google Play Billing.
        public static let play = Source(rawValue: "play")
        /// RevenueCat.
        public static let revenuecat = Source(rawValue: "revenuecat")
        /// Superwall.
        public static let superwall = Source(rawValue: "superwall")
        /// Adapty.
        public static let adapty = Source(rawValue: "adapty")
        /// Stripe.
        public static let stripe = Source(rawValue: "stripe")
        /// Your app, through `setEntitlement(_:)`.
        public static let app = Source(rawValue: "app")
    }
    /// Current state.
    public var state: State
    /// The product that grants it.
    public var productId: String?
    /// The next renewal while it auto-renews (trial, active).
    public var renewsAt: Date?
    /// The end of the current period: when access ends (cancelled) or ended (expired).
    public var expiresAt: Date?
    /// The day access ends unless the payment is fixed (grace, billing retry).
    public var gracePeriodEndsAt: Date?
    /// Which system reported it.
    public var source: Source?
    /// The store environment of the purchase behind it ("production", "sandbox", "xcode"); `nil` when the
    /// store did not say or the app set it.
    public var environment: String?

    /// True for a test purchase (TestFlight, a sandbox account, StoreKit testing): any environment other than
    /// production.
    public var isTestPurchase: Bool {
        guard let environment else { return false }
        return environment.lowercased() != "production"
    }

    /// Creates an entitlement value.
    public init(
        state: State, productId: String? = nil, renewsAt: Date? = nil, expiresAt: Date? = nil, gracePeriodEndsAt: Date? = nil,
        source: Source? = .app
    ) {
        self.state = state
        self.productId = productId
        self.renewsAt = renewsAt
        self.expiresAt = expiresAt
        self.gracePeriodEndsAt = gracePeriodEndsAt
        self.source = source
    }

    /// True when the plan has a payment problem the person can fix (grace or billing retry).
    public var hasPaymentIssue: Bool { state == .grace || state == .billingRetry }
}

/// A push token registration.
package struct PushRegistration: Codable, Sendable, Equatable {
    package enum Provider: String, Codable, Sendable { case apns, fcm, webpush }
    package enum Environment: String, Codable, Sendable { case sandbox, production }
    package var provider: Provider
    package var token: String
    package var environment: Environment?
}

/// An offer the app can show, reported so the team (and plays) can reference it in offer cards.
public struct OfferSlot: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Offer flavours.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Kind: String, Codable, Sendable { case standard, discount, winback }
    /// Where the paywall behind a slot is built.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Source: String, Codable, Sendable, CaseIterable, TolerantStringEnum {
        /// RevenueCat paywalls (`PingFrontRevenueCat`).
        case revenuecat
        /// Superwall paywalls (`PingFrontSuperwall`).
        case superwall
        /// Adapty paywalls (`PingFrontAdapty`).
        case adapty
        /// StoreKit products (`.storeKit(products:)`).
        case storekit
        /// Google Play (Android SDK).
        case play
        /// The app's own paywall (`setOffers(_:)`).
        case app
        /// A source this SDK version does not know. Never sent.
        case unknown
        package static var fallback: Source { .unknown }
        /// Decodes the raw value; values this SDK version does not know become `.unknown`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// One purchasable product in the slot.
    public struct Product: Codable, Sendable, Equatable, Hashable {
        /// Store product id.
        public var id: String
        /// Localized display price, for example "€4.99".
        public var price: String
        /// ISO-8601 period such as "P1M".
        public var period: String?
        /// ISO-8601 trial period such as "P1W".
        public var trial: String?
        /// Creates a product entry.
        public init(id: String, price: String, period: String? = nil, trial: String? = nil) {
            self.id = id
            self.price = price
            self.period = period
            self.trial = trial
        }
    }
    /// Stable id referenced by offer cards (`[A-Za-z0-9_.-]{1,64}`).
    public var id: String
    /// Short title, at most 60 characters.
    public var title: String
    /// The flavour of offer.
    public var kind: Kind
    /// Whether the app can show it right now.
    public var isAvailable: Bool
    /// Products inside the offer.
    public var products: [Product]
    /// Where the paywall is built. `setOffers(_:)` fills in `.app` and modules their own source.
    public var source: Source?

    /// Creates an offer slot.
    public init(
        id: String, title: String, kind: Kind = .standard, isAvailable: Bool = true, products: [Product] = [], source: Source? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isAvailable = isAvailable
        self.products = products
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, products, source
        case isAvailable = "available"
    }

    /// Encodes the wire format; an unknown source is left out.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(kind, forKey: .kind)
        try c.encode(isAvailable, forKey: .isAvailable)
        try c.encode(products, forKey: .products)
        if let source, source != .unknown { try c.encode(source, forKey: .source) }
    }

    /// Decodes the wire format; values this SDK version does not know are kept as unknown.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(Kind.self, forKey: .kind)
        isAvailable = try c.decode(Bool.self, forKey: .isAvailable)
        products = try c.decodeIfPresent([Product].self, forKey: .products) ?? []
        source = try c.decodeIfPresent(Source.self, forKey: .source)
    }
}

/// Why a session is being created.
package enum SessionReason: String, Codable, Sendable {
    case chatOpened = "chat_opened"
    case moment, prepare
    case pushOpened = "push_opened"
    case report
}

/// A summary of the person this install belongs to.
public struct PersonSummary: Codable, Sendable, Equatable {
    /// Identity levels.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Level: String, Codable, Sendable, TolerantStringEnum {
        case guest, named, verified
        /// The case used for values this SDK version does not know.
        package static var fallback: Level { .guest }

        /// Decodes the raw value; values this SDK version does not know become `.guest`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Server id of the person.
    public let id: String
    /// Guest, named or verified.
    public let level: Level
    /// Display name, if known.
    public let name: String?
    /// The plan as the server knows it from store events, for the chat's plan status line (absent until a store
    /// event was recorded for the person).
    public var entitlement: Entitlement?

    /// Creates a person summary.
    @_spi(Fixtures) public init(id: String, level: Level, name: String? = nil, entitlement: Entitlement? = nil) {
        self.id = id
        self.level = level
        self.name = name
        self.entitlement = entitlement
    }
}

/// A problem with the identity token, reported by the server without failing the request.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum IdentityProblem: String, Codable, Sendable, TolerantStringEnum {
    /// The signature did not verify.
    case tokenInvalid = "token_invalid"
    /// The token expired.
    case tokenExpired = "token_expired"
    /// The token belongs to a different user id.
    case userMismatch = "user_mismatch"
    /// A problem this SDK version does not know.
    case unknown
    /// The case used for values this SDK version does not know.
    package static var fallback: IdentityProblem { .unknown }

    /// Decodes the raw value; values this SDK version does not know become `.unknown`.
    public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
}

package struct CreateSessionRequest: Encodable, Sendable {
    package var device: Device
    /// Required to re-register an install id the server already knows; without it the server mints a new id.
    package var installSecret: String?
    package var identity: Identity?
    package var traits: [String: String]?
    package var entitlement: Entitlement?
    package var offers: [OfferSlot]?
    package var hostLook: HostLook?
    package var reason: SessionReason
}

package struct CreateSessionResponse: Decodable, Sendable {
    /// The install id the server registered (adopt it: it differs when the sent id could not be reused).
    package var installId: String?
    package var accessToken: String
    package var accessExpiresAt: Date
    /// Seconds until expiry as measured by the server.
    ///
    /// Refresh is scheduled from this, never the device clock.
    package var accessExpiresIn: Int?
    package var installSecret: String
    package var person: PersonSummary
    package var identityProblem: IdentityProblem?
    package var testDevice: Bool
    /// Per-person UUID passed to StoreKit as `appAccountToken`.
    package var storeAccountToken: String?
    /// The context groups the app collects; `nil` from older servers (collect every group).
    package var collect: ContextCollection?

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installId = try c.decodeIfPresent(String.self, forKey: .installId)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        accessExpiresAt = try c.decode(Date.self, forKey: .accessExpiresAt)
        accessExpiresIn = try c.decodeIfPresent(Int.self, forKey: .accessExpiresIn)
        installSecret = try c.decode(String.self, forKey: .installSecret)
        person = try c.decode(PersonSummary.self, forKey: .person)
        identityProblem = try c.decodeIfPresent(IdentityProblem.self, forKey: .identityProblem)
        testDevice = try c.decodeIfPresent(Bool.self, forKey: .testDevice) ?? false
        storeAccountToken = try c.decodeIfPresent(String.self, forKey: .storeAccountToken)
        // An unreadable collect never fails the session: the SDK keeps its last value.
        collect = c.tolerant(ContextCollection.self, forKey: .collect)
    }

    private enum CodingKeys: String, CodingKey {
        case installId, accessToken, accessExpiresAt, accessExpiresIn, installSecret, person, identityProblem, testDevice, storeAccountToken
        case collect
    }
}

package struct RefreshSessionRequest: Encodable, Sendable {
    package var installId: String
    package var installSecret: String
    /// Current device facts (time zone, locale, app and SDK version).
    package var device: Device?
}

package struct RefreshSessionResponse: Decodable, Sendable {
    package var accessToken: String
    package var accessExpiresAt: Date
    package var accessExpiresIn: Int?
    package var person: PersonSummary
    package var testDevice: Bool
    package var storeAccountToken: String?
    /// The context groups the app collects; `nil` from older servers (collect every group).
    package var collect: ContextCollection?

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        accessExpiresAt = try c.decode(Date.self, forKey: .accessExpiresAt)
        accessExpiresIn = try c.decodeIfPresent(Int.self, forKey: .accessExpiresIn)
        person = try c.decode(PersonSummary.self, forKey: .person)
        testDevice = try c.decodeIfPresent(Bool.self, forKey: .testDevice) ?? false
        storeAccountToken = try c.decodeIfPresent(String.self, forKey: .storeAccountToken)
        // An unreadable collect never fails the session: the SDK keeps its last value.
        collect = c.tolerant(ContextCollection.self, forKey: .collect)
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, accessExpiresAt, accessExpiresIn, person, testDevice, storeAccountToken, collect
    }
}

/// `PATCH /me`.
///
/// Only changed fields are present; `push` can be explicitly `null` to unregister.
package struct UpdateMeRequest: Encodable, Sendable, Equatable {
    package enum PushChange: Sendable, Equatable {
        case set(PushRegistration)
        case clear
    }
    /// Device facts that changed (time zone, locale, app or SDK version).
    package var device: Device?
    package var identity: Identity?
    package var traits: [String: String]?
    package var entitlement: Entitlement?
    package var offers: [OfferSlot]?
    package var push: PushChange?
    package var hostLook: HostLook?

    package var isEmpty: Bool {
        device == nil && identity == nil && traits == nil && entitlement == nil && offers == nil && push == nil && hostLook == nil
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(device, forKey: .device)
        try c.encodeIfPresent(identity, forKey: .identity)
        try c.encodeIfPresent(traits, forKey: .traits)
        try c.encodeIfPresent(entitlement, forKey: .entitlement)
        try c.encodeIfPresent(offers, forKey: .offers)
        try c.encodeIfPresent(hostLook, forKey: .hostLook)
        switch push {
        case .set(let registration): try c.encode(registration, forKey: .push)
        case .clear: try c.encodeNil(forKey: .push)
        case nil: break
        }
    }

    private enum CodingKeys: String, CodingKey { case device, identity, traits, entitlement, offers, push, hostLook }
}

/// A field `PATCH /me` did not apply (the rest were applied).
package struct RejectedField: Decodable, Sendable, Equatable {
    package var field: String
    package var code: String
    package var message: String
}

package struct UpdateMeResponse: Decodable, Sendable {
    package var person: PersonSummary
    package var identityProblem: IdentityProblem?
    package var rejected: [RejectedField]

    package init(person: PersonSummary, identityProblem: IdentityProblem? = nil, rejected: [RejectedField] = []) {
        self.person = person
        self.identityProblem = identityProblem
        self.rejected = rejected
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        person = try c.decode(PersonSummary.self, forKey: .person)
        identityProblem = try c.decodeIfPresent(IdentityProblem.self, forKey: .identityProblem)
        rejected = try c.decodeLossyArray(RejectedField.self, forKey: .rejected)
    }

    private enum CodingKeys: String, CodingKey { case person, identityProblem, rejected }
}

package struct InstallCredentials: Codable, Sendable, Equatable {
    package var installId: String
    package var installSecret: String
}

/// Whether the person can send, and why not.
///
/// An enum, so "can send" and "why not" can never disagree.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum SendPolicy: Codable, Sendable, Equatable {
    /// The person can send.
    case open
    /// Sending is off, for a reason the chat explains.
    case closed(Reason)

    /// Why sending is off.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Reason: String, Codable, Sendable, TolerantStringEnum {
        case blocked
        case appPaused = "app_paused"
        /// The app accepts messages only from verified people: the person must sign in to the host app.
        case verificationRequired = "verification_required"
        case unknown
        /// The case used for values this SDK version does not know.
        package static var fallback: Reason { .unknown }

        /// Decodes the raw value; values this SDK version does not know become `.unknown`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }

        /// The reason a refused send names (403 `blocked`, `app_paused`, `verification_required`), or `nil`.
        package init?(refusal code: ErrorCode?) {
            switch code {
            case .blocked?: self = .blocked
            case .appPaused?: self = .appPaused
            case .verificationRequired?: self = .verificationRequired
            default: return nil
            }
        }

        /// The reason's stable wire code.
        ///
        /// `blocked`, `app_paused` or `verification_required` (`unknown` for a reason this SDK version doesn't know): the
        /// same strings as Android's `SendPolicy.Reason.code`.
        public var code: String { rawValue }

        /// True when a message refused for this reason waits and goes again by itself when sending reopens.
        ///
        /// A pause or a required sign-in ends without the person writing again. A blocked person is promised nothing.
        package var holdsMessages: Bool { self == .appPaused || self == .verificationRequired }
    }
    /// True when the composer is enabled.
    public var canSend: Bool { self == .open }

    /// Why sending is off; `nil` when it is not.
    public var reason: Reason? {
        if case .closed(let reason) = self { return reason }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case canSend, reason }

    /// Decodes `{ canSend, reason? }`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(Bool.self, forKey: .canSend) {
            self = .open
        } else {
            self = .closed(try c.decodeIfPresent(Reason.self, forKey: .reason) ?? .unknown)
        }
    }

    /// Encodes `{ canSend, reason? }`.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(canSend, forKey: .canSend)
        try c.encodeIfPresent(reason, forKey: .reason)
    }
}

/// Open or resolved.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum ThreadStatus: String, Codable, Sendable, TolerantStringEnum {
    case open, resolved
    /// The case used for values this SDK version does not know.
    package static var fallback: ThreadStatus { .open }

    /// Decodes the raw value; values this SDK version does not know become `.open`.
    public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
}

package struct ThreadInfo: Codable, Sendable, Equatable {
    package var id: String
    package var status: ThreadStatus
    package var lastSeq: Int
    package var readSeq: Int
    /// How far the team has read: "Read" under the person's last message.
    package var teamReadSeq: Int?
    package var unread: Int
    /// Bumped on merge or reset; sent back as `PF-Thread-Rev`.
    package var rev: Int?
}

package struct ThreadResponse: Decodable, Sendable {
    package var thread: ThreadInfo?
    package var messages: [Message]
    package var hasOlder: Bool
    package var team: [TeamMember]
    package var replyExpectation: String?
    package var policy: SendPolicy

    package init(
        thread: ThreadInfo?, messages: [Message], hasOlder: Bool, team: [TeamMember], replyExpectation: String?, policy: SendPolicy
    ) {
        self.thread = thread
        self.messages = messages
        self.hasOlder = hasOlder
        self.team = team
        self.replyExpectation = replyExpectation
        self.policy = policy
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thread = try c.decodeIfPresent(ThreadInfo.self, forKey: .thread)
        messages = try c.decodeLossyArray(Message.self, forKey: .messages)
        hasOlder = try c.decodeIfPresent(Bool.self, forKey: .hasOlder) ?? false
        team = try c.decodeLossyArray(TeamMember.self, forKey: .team)
        replyExpectation = try c.decodeIfPresent(String.self, forKey: .replyExpectation)
        policy = try c.decodeIfPresent(SendPolicy.self, forKey: .policy) ?? .open
    }

    private enum CodingKeys: String, CodingKey { case thread, messages, hasOlder, team, replyExpectation, policy }
}

package struct MessagesPage: Decodable, Sendable {
    package var messages: [Message]
    package var hasMore: Bool

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeLossyArray(Message.self, forKey: .messages)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }

    private enum CodingKeys: String, CodingKey { case messages, hasMore }
}

package struct CardReply: Codable, Sendable, Equatable {
    package var messageId: String
    package var cardId: String
    package var choiceId: String?
    package var rating: Int?
}

package struct SendMessageRequest: Encodable, Sendable, Equatable {
    package var clientId: String
    package var text: String?
    package var attachmentIds: [String]?
    package var replyToCard: CardReply?
}

package struct SendMessageResponse: Decodable, Sendable {
    package var message: Message
    package var threadId: String
}

package struct ReadRequest: Encodable, Sendable { package var upToSeq: Int }
package struct ReadResponse: Decodable, Sendable {
    package var readSeq: Int
    package var unread: Int
}

package struct CardActionRequest: Codable, Sendable, Equatable {
    /// `failed` is for link cards only: the tap's link didn't open (`failure` says why).
    package enum Action: String, Codable, Sendable { case opened, chosen, rated, dismissed, failed }
    /// Made once per report and kept across its retries (`CardActionReports`): the server records the report once.
    package var clientId: String?
    package var messageId: String
    package var action: Action
    package var choiceId: String?
    package var rating: Int?
    package var failure: LinkFailure?

    package init(messageId: String, action: Action, answer: CardAnswer? = nil, failure: LinkFailure? = nil) {
        self.messageId = messageId
        self.action = action
        if case .choice(let id) = answer { choiceId = id }
        if case .rating(let value) = answer { rating = value }
        self.failure = failure
    }
}

/// Why a link card didn't open (`LinkFailure`).
package enum LinkFailure: String, Codable, Sendable, Equatable, TolerantStringEnum {
    /// The card names a screen and the app's handler returned false, or the app set none.
    case notHandled = "not_handled"
    /// The card names a screen this build didn't register, and has no URL to fall back to.
    case unknownScreen = "unknown_screen"
    /// Nothing could open the URL.
    case cannotOpen = "cannot_open"
    case unknown
    package static var fallback: LinkFailure { .unknown }

    package init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
}

/// `POST /store-actions`: what a store action did on the device, for the team's receipt line.
package struct StoreActionResultRequest: Encodable, Sendable, Equatable {
    package var clientId: String
    package var action: String
    package var result: String
    package var cardId: String?
    package var messageId: String?
    package var productName: String?

    package init(
        clientId: String, action: String, result: String, cardId: String? = nil, messageId: String? = nil, productName: String? = nil
    ) {
        self.clientId = clientId
        self.action = action
        self.result = result
        self.cardId = cardId
        self.messageId = messageId
        self.productName = productName.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(100))) }
    }
}

/// The receipt the server wrote, or `nil` when it wrote none (no conversation yet, or a store receipt already says it).
package struct StoreActionResultResponse: Decodable, Sendable {
    package var message: Message?
}

package struct UnreadResponse: Decodable, Sendable {
    package var unread: Int
    package var lastSeq: Int
    package var live: Bool
}

package struct CreateUploadRequest: Encodable, Sendable {
    /// Idempotency key: the same id returns the same attachment.
    package var requestId: String
    package var contentType: String
    package var bytes: Int
    package var width: Int?
    package var height: Int?
    package var sha256: String
}

package struct CreateUploadResponse: Decodable, Sendable {
    package var attachmentId: String
    package var putUrl: URL
    package var headers: [String: String]
    package var expiresAt: Date
}

package struct AttachmentURL: Decodable, Sendable {
    package var url: URL
    package var expiresAt: Date
}

package struct CreateReportRequest: Encodable, Sendable {
    package var clientId: String
    package var text: String
    package var screenshotIds: [String]
    package var logTail: String?
    package var state: [String: String]?
}

/// A moment property value: string, number or boolean.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum MomentValue: Sendable, Equatable, Encodable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral
{
    /// A string, at most 256 characters.
    case string(String)
    /// A number.
    case number(Double)
    /// A boolean.
    case bool(Bool)

    /// A string value.
    public init(stringLiteral value: String) { self = .string(value) }
    /// An integer value.
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    /// A number value.
    public init(floatLiteral value: Double) { self = .number(value) }
    /// A Boolean value.
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    /// Encodes the wire format.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        }
    }
}

/// A purchase or subscription change detected on the device (`StoreMomentProps`).
package struct StoreMomentProps: Encodable, Sendable, Equatable {
    package var productId: String
    package var transactionId: String?
    package var originalTransactionId: String?
    package var price: String?
    package var currency: String?
    /// StoreKit 2 `jwsRepresentation`, verified by the server.
    package var signedTransaction: String?

    package init(
        productId: String, transactionId: String? = nil, originalTransactionId: String? = nil, price: String? = nil,
        currency: String? = nil, signedTransaction: String? = nil
    ) {
        self.productId = productId
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.price = price
        self.currency = currency
        self.signedTransaction = signedTransaction
    }
}

package struct MomentRequest: Encodable, Sendable {
    package var name: String
    package var props: [String: MomentValue]?
    package var store: StoreMomentProps?
    package var occurredAt: Date?
    package var clientId: String
}

package struct MomentResponse: Decodable, Sendable {
    package enum Outcome: String, Decodable, Sendable, TolerantStringEnum {
        case ignored, scheduled, delivered
        case heldOut = "held_out"
        /// The case used for values this SDK version does not know.
        package static var fallback: Outcome { .ignored }

        /// Decodes the raw value; values this SDK version does not know become `.ignored`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    package var outcome: Outcome
    package var open: Bool
}

package struct ListenedMomentsResponse: Decodable, Sendable {
    package var names: [String]
    /// Store events a live play reacts to; the store module reports only these.
    package var storeEvents: [String]

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = try c.decode([String].self, forKey: .names)
        storeEvents = try c.decodeIfPresent([String].self, forKey: .storeEvents) ?? []
    }

    private enum CodingKeys: String, CodingKey { case names, storeEvents }
}

package struct OfferSignatureRequest: Encodable, Sendable, Equatable {
    package var productId: String
    package var offerId: String
}

/// What StoreKit needs to buy a product with a promotional offer (`OfferSignatureResponse`).
public struct PromotionalOfferSignature: Decodable, Sendable, Equatable {
    /// The pre-iOS 26 signature parts.
    public struct Legacy: Decodable, Sendable, Equatable {
        /// The In-App Purchase key id.
        public var keyId: String
        /// The nonce (a UUID).
        public var nonce: String
        /// Milliseconds since the epoch.
        public var timestamp: Int64
        /// Base64 DER ECDSA signature.
        public var signature: String
    }
    /// The product.
    public var productId: String
    /// The promotional offer id.
    public var offerId: String
    /// Pass as `appAccountToken` with the purchase.
    public var appAccountToken: String
    /// The compact JWS for `promotionalOffer(_:compactJWS:)`.
    public var jws: String
    /// The legacy signature.
    public var legacy: Legacy
}
