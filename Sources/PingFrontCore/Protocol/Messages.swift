public import Foundation

/// Who wrote a message.
public struct Author: Codable, Sendable, Equatable, Hashable {
    /// The kind of author.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Kind: String, Codable, Sendable, TolerantStringEnum {
        case person, team, ai, system
        /// The server sent a kind this SDK does not know; shown like a team message.
        case unknown
        /// The case used for values this SDK version does not know.
        package static var fallback: Kind { .unknown }

        /// Decodes the raw value; values this SDK version does not know become `.unknown`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Person, team, AI or system.
    public var kind: Kind
    /// Team member id.
    public var id: String?
    /// Display name.
    public var name: String?
    /// Avatar image URL.
    public var avatarURL: URL?

    /// Creates an author.
    @_spi(Fixtures) public init(kind: Kind, id: String? = nil, name: String? = nil, avatarURL: URL? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, name
        case avatarURL = "avatarUrl"
    }
}

/// An image attachment in a message.
public struct ImagePart: Codable, Sendable, Equatable, Hashable {
    /// Attachment id; resolve an expired `url` with `GET /attachments/:id`.
    public var attachmentId: String
    /// Pixel width.
    public var width: Int
    /// Pixel height.
    public var height: Int
    /// Short-lived download URL.
    public var url: URL?
    /// The app's retention deleted the photo: there is no `url`, and the chat shows a "Photo removed" placeholder
    /// instead of fetching it.
    public var removed: Bool

    /// Creates an image part.
    @_spi(Fixtures) public init(attachmentId: String, width: Int, height: Int, url: URL? = nil, removed: Bool = false) {
        self.attachmentId = attachmentId
        self.width = width
        self.height = height
        self.url = url
        self.removed = removed
    }

    private enum CodingKeys: String, CodingKey { case attachmentId, width, height, url, removed }

    /// Decodes the wire format; `removed` is absent unless retention deleted the photo.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attachmentId = try c.decode(String.self, forKey: .attachmentId)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
        // A removed photo has no bytes: drop any url so nothing tries to fetch it.
        url = removed ? nil : try c.decodeIfPresent(URL.self, forKey: .url)
    }

    /// Encodes the wire format; `removed` is written only when true.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(attachmentId, forKey: .attachmentId)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encodeIfPresent(url, forKey: .url)
        if removed { try c.encode(true, forKey: .removed) }
    }
}

/// An offer card: opens the app's offer (paywall or promo) named by `offerId`.
public struct OfferCard: Codable, Sendable, Equatable, Hashable {
    /// Card id.
    public var id: String
    /// The `OfferSlot.id` to show.
    public var offerId: String
    /// Card title.
    public var title: String
    /// Optional body text.
    public var body: String?
    /// Button label.
    public var button: String
    /// The store offer the button redeems (promotional, win-back, offer code, intro), if any.
    public var offer: StoreOffer?

    /// Creates an offer card.
    @_spi(Fixtures) public init(id: String, offerId: String, title: String, body: String? = nil, button: String, offer: StoreOffer? = nil) {
        self.id = id
        self.offerId = offerId
        self.title = title
        self.body = body
        self.button = button
        self.offer = offer
    }
}

/// A store offer an offer card redeems on top of opening the paywall (the protocol's `StoreOffer`).
public struct StoreOffer: Codable, Sendable, Equatable, Hashable {
    /// The kind of store offer.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Kind: String, Codable, Sendable, TolerantStringEnum {
        /// An App Store promotional offer (signed by the server).
        case promotional
        /// An App Store win-back offer (iOS 18+).
        case winback
        /// An offer code: the redemption sheet opens.
        case code
        /// An introductory offer the store applies to eligible people.
        case intro
        /// A kind this SDK version does not know: the paywall opens without an offer.
        case unknown
        /// The case used for values this SDK version does not know.
        package static var fallback: Kind { .unknown }

        /// Decodes the raw value; values this SDK version does not know become `.unknown`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// The kind.
    public var kind: Kind
    /// The offer identifier (App Store Connect).
    public var id: String
    /// The product the offer applies to.
    public var productId: String?

    /// Creates a store offer.
    public init(kind: Kind, id: String, productId: String? = nil) {
        self.kind = kind
        self.id = id
        self.productId = productId
    }
}

/// A review card: native prompt or the store page.
public struct ReviewCard: Codable, Sendable, Equatable, Hashable {
    /// How the review is requested.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Mode: String, Codable, Sendable, TolerantStringEnum {
        case nativePrompt = "native_prompt"
        case storePage = "store_page"
        /// The case used for values this SDK version does not know.
        package static var fallback: Mode { .storePage }

        /// Decodes the raw value; values this SDK version does not know become `.storePage`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Card id.
    public var id: String
    /// Native prompt or store page.
    public var mode: Mode
    /// Store page URL.
    public var storeURL: URL?
    /// Button label.
    public var button: String

    /// Creates a review card.
    @_spi(Fixtures) public init(id: String, mode: Mode, storeURL: URL? = nil, button: String) {
        self.id = id
        self.mode = mode
        self.storeURL = storeURL
        self.button = button
    }

    private enum CodingKeys: String, CodingKey {
        case id, mode, button
        case storeURL = "storeUrl"
    }
}

/// A link or deep-link card.
public struct LinkCard: Codable, Sendable, Equatable, Hashable {
    /// Card id.
    public var id: String
    /// Card title.
    public var title: String
    /// A web URL or app deep link.
    ///
    /// With `screen`, the fallback for builds that didn't register it, or `""`.
    public var url: String
    /// Button label.
    public var button: String
    /// A screen of your app to open instead of `url` (a saved link): it reaches `PingFront.onScreen`.
    public var screen: LinkScreen?
    /// The saved link the card was made from.
    ///
    /// Only the server sets it.
    public var savedLinkId: String?

    /// Creates a link card.
    @_spi(Fixtures) public init(
        id: String, title: String, url: String, button: String, screen: LinkScreen? = nil, savedLinkId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.button = button
        self.screen = screen
        self.savedLinkId = savedLinkId
    }

    private enum CodingKeys: String, CodingKey { case id, title, url, button, screen, savedLinkId }

    /// Decodes the wire format; a `screen` this SDK version can't read is left out (the card keeps its `url`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        button = try c.decode(String.self, forKey: .button)
        screen = try? c.decodeIfPresent(LinkScreen.self, forKey: .screen)
        savedLinkId = try? c.decodeIfPresent(String.self, forKey: .savedLinkId)
    }
}

/// A screen of your app that a link card opens, and the parameters to open it with (`LinkScreen`).
public struct LinkScreen: Codable, Sendable, Equatable, Hashable {
    /// The screen's id, one your app registered (`AppScreen.id`).
    public var id: String
    /// String parameters for the screen (`"tab": "yearly"`), as the team set them.
    public var params: [String: String]

    /// Creates a screen target.
    @_spi(Fixtures) public init(id: String, params: [String: String] = [:]) {
        self.id = id
        self.params = params
    }

    private enum CodingKeys: String, CodingKey { case id, params }

    /// Decodes `{ id, params? }`; parameters that aren't strings are left out.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        params = Self.stringParams(in: c)
    }

    /// The string values of `params`, one by one: a value of another type drops only itself, not the map.
    private static func stringParams(in c: KeyedDecodingContainer<CodingKeys>) -> [String: String] {
        guard let map = try? c.nestedContainer(keyedBy: ParamKey.self, forKey: .params) else { return [:] }
        var params: [String: String] = [:]
        for key in map.allKeys {
            if let value = try? map.decode(String.self, forKey: key) { params[key.stringValue] = value }
        }
        return params
    }

    private struct ParamKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Encodes `{ id, params? }`.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if !params.isEmpty { try c.encode(params, forKey: .params) }
    }
}

/// A choices card: the person picks one option.
public struct ChoicesCard: Codable, Sendable, Equatable, Hashable {
    /// One option.
    public struct Option: Codable, Sendable, Equatable, Hashable, Identifiable {
        /// Option id.
        public var id: String
        /// Label.
        public var label: String

        /// Creates an option.
        @_spi(Fixtures) public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }
    /// Card id.
    public var id: String
    /// Two to six options.
    public var options: [Option]

    /// Creates a choices card.
    @_spi(Fixtures) public init(id: String, options: [Option]) {
        self.id = id
        self.options = options
    }
}

/// A 1–5 rating card.
public struct RatingCard: Codable, Sendable, Equatable, Hashable {
    /// Card id.
    public var id: String
    /// The question.
    public var question: String
    /// Always 5.
    ///
    /// A value outside 1...5 from the server is clamped into it when the card is decoded.
    public var scale: Int

    /// The scales the protocol allows (the protocol fixes `RatingCard.scale` at 5).
    package static let scales = 1...5

    /// Creates a rating card.
    @_spi(Fixtures) public init(id: String, question: String, scale: Int = 5) {
        self.id = id
        self.question = question
        self.scale = scale
    }

    /// Decodes a rating card, clamping `scale` into the protocol's range so a bad value never draws a row of stars
    /// that cannot fit (or traps on an empty range).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        question = try container.decode(String.self, forKey: .question)
        scale = Self.clamped(try container.decode(Int.self, forKey: .scale))
    }

    /// The number of stars to draw: `scale` in the protocol's range, however the card was made.
    package var stars: Int { Self.clamped(scale) }

    private static func clamped(_ scale: Int) -> Int { min(max(scale, scales.lowerBound), scales.upperBound) }

    private enum CodingKeys: String, CodingKey { case id, question, scale }
}

/// A bug report card: opens the report flow.
public struct ReportCard: Codable, Sendable, Equatable, Hashable {
    /// Card id.
    public var id: String
    /// Card title.
    public var title: String
    /// Button label.
    public var button: String
}

/// A card that opens one of Apple's own App Store sheets inside the app: manage subscriptions, fix a billing
/// issue, request a refund, redeem a code or restore purchases (`store_action` on the wire).
public struct StoreActionCard: Codable, Sendable, Equatable, Hashable {
    /// The App Store sheet the card opens.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Action: String, Codable, Sendable, TolerantStringEnum {
        /// Apple's manage-subscriptions sheet.
        case manageSubscriptions = "manage_subscriptions"
        /// Apple's billing-issue message when one is pending, otherwise the manage-subscriptions sheet.
        case billingIssue = "billing_issue"
        /// Apple's refund request sheet for a transaction.
        case requestRefund = "request_refund"
        /// Apple's offer code redemption sheet.
        case redeemCode = "redeem_code"
        /// Syncs purchases with the App Store.
        case restorePurchases = "restore_purchases"
        /// An action this SDK version does not know: the card opens Apple's subscriptions page.
        case unknown
        package static var fallback: Action { .unknown }
        /// Decodes the raw value; values this SDK version does not know become `.unknown`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Which store the card was written for (a hint; the SDK uses the platform's store either way).
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Store: String, Codable, Sendable, TolerantStringEnum {
        case appStore = "app_store"
        case play
        /// A store this SDK version does not know.
        case unknown
        package static var fallback: Store { .unknown }
        /// Decodes the raw value; values this SDK version does not know become `.unknown`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Card id.
    public var id: String
    /// The sheet the card opens.
    public var action: Action
    /// Card title (at most 80 characters); the SDK's own title for the action when absent.
    public var title: String?
    /// Card text (at most 280 characters); the SDK's own line for the action when absent.
    public var body: String?
    /// Button label (at most 40 characters); the SDK's own label for the action when absent.
    public var button: String?
    /// The product the action is about.
    public var productId: String?
    /// The subscription group the manage sheet opens on.
    public var subscriptionGroupId: String?
    /// The transaction a refund request is for (set by the server only).
    public var transactionId: String?
    /// The store the card was written for, a hint.
    public var store: Store?

    /// Creates a store action card.
    @_spi(Fixtures) public init(
        id: String, action: Action, title: String? = nil, body: String? = nil, button: String? = nil, productId: String? = nil,
        subscriptionGroupId: String? = nil, transactionId: String? = nil, store: Store? = nil
    ) {
        self.id = id
        self.action = action
        self.title = title
        self.body = body
        self.store = store
        self.button = button
        self.productId = productId
        self.subscriptionGroupId = subscriptionGroupId
        self.transactionId = transactionId
    }

    /// Apple's web page for the action, used when the app has no StoreKit module (`nil` for restore, which
    /// has no web page).
    public var fallbackURL: URL? {
        switch action {
        case .requestRefund: URL(string: "https://reportaproblem.apple.com")
        case .redeemCode: URL(string: "https://apps.apple.com/redeem")
        case .restorePurchases: nil
        case .manageSubscriptions, .billingIssue, .unknown: URL(string: "https://apps.apple.com/account/subscriptions")
        }
    }
}

/// A structured card inside a message.
///
/// Unknown kinds decode as `.unknown` and are skipped by the UI.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum Card: Sendable, Equatable, Hashable, Codable {
    case offer(OfferCard)
    case review(ReviewCard)
    case link(LinkCard)
    case choices(ChoicesCard)
    case rating(RatingCard)
    case report(ReportCard)
    /// Opens one of Apple's App Store sheets (`store_action`).
    case storeAction(StoreActionCard)
    /// A card kind this SDK version does not know.
    case unknown(kind: String, id: String?)

    /// The card id.
    public var id: String {
        switch self {
        case .offer(let c): c.id
        case .review(let c): c.id
        case .link(let c): c.id
        case .choices(let c): c.id
        case .rating(let c): c.id
        case .report(let c): c.id
        case .storeAction(let c): c.id
        case .unknown(_, let id): id ?? ""
        }
    }

    private enum Keys: String, CodingKey { case kind, id }

    /// Decodes the wire format; values this SDK version does not know are kept as unknown.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let id = try? c.decode(String.self, forKey: .id)
        do {
            switch kind {
            case "offer": self = .offer(try OfferCard(from: decoder))
            case "review": self = .review(try ReviewCard(from: decoder))
            case "link": self = .link(try LinkCard(from: decoder))
            case "choices": self = .choices(try ChoicesCard(from: decoder))
            case "rating": self = .rating(try RatingCard(from: decoder))
            case "report": self = .report(try ReportCard(from: decoder))
            case "store_action": self = .storeAction(try StoreActionCard(from: decoder))
            default: self = .unknown(kind: kind, id: id)
            }
        } catch {
            self = .unknown(kind: kind, id: id)
        }
    }

    /// Encodes the wire format.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .offer(let card):
            try c.encode("offer", forKey: .kind)
            try card.encode(to: encoder)
        case .review(let card):
            try c.encode("review", forKey: .kind)
            try card.encode(to: encoder)
        case .link(let card):
            try c.encode("link", forKey: .kind)
            try card.encode(to: encoder)
        case .choices(let card):
            try c.encode("choices", forKey: .kind)
            try card.encode(to: encoder)
        case .rating(let card):
            try c.encode("rating", forKey: .kind)
            try card.encode(to: encoder)
        case .report(let card):
            try c.encode("report", forKey: .kind)
            try card.encode(to: encoder)
        case .storeAction(let card):
            try c.encode("store_action", forKey: .kind)
            try card.encode(to: encoder)
        case .unknown(let kind, let id):
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(id, forKey: .id)
        }
    }
}

/// The final state of a card the person acted on, filled by the server.
public struct CardResult: Codable, Sendable, Equatable, Hashable {
    /// When the person acted.
    public var at: Date
    /// The answer, for choices and rating cards.
    public var answer: CardAnswer?

    /// Creates a result.
    @_spi(Fixtures) public init(at: Date, answer: CardAnswer? = nil) {
        self.at = at
        self.answer = answer
    }

    /// The chosen option id, for choices cards.
    public var choiceId: String? {
        if case .choice(let id) = answer { return id }
        return nil
    }

    /// The rating, for rating cards.
    public var rating: Int? {
        if case .rating(let value) = answer { return value }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case at, choiceId, rating }

    /// Decodes `{ at, choiceId?, rating? }`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Date.self, forKey: .at)
        if let id = try c.decodeIfPresent(String.self, forKey: .choiceId) {
            answer = .choice(id: id)
        } else if let value = try c.decodeIfPresent(Int.self, forKey: .rating) {
            answer = .rating(value)
        }
    }

    /// Encodes `{ at, choiceId?, rating? }`.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(choiceId, forKey: .choiceId)
        try c.encodeIfPresent(rating, forKey: .rating)
    }
}

/// What the person answered on a card.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum CardAnswer: Sendable, Equatable, Hashable {
    /// An option of a choices card.
    case choice(id: String)
    /// A value on a rating card's scale.
    case rating(Int)
}

/// A card part: the card plus its result once acted on.
public struct CardPart: Codable, Sendable, Equatable, Hashable {
    /// The card.
    public var card: Card
    /// Set once the person acted.
    public var result: CardResult?

    /// Creates a card part.
    @_spi(Fixtures) public init(card: Card, result: CardResult? = nil) {
        self.card = card
        self.result = result
    }
}

/// A centered system line recording something done for the person.
public struct ReceiptPart: Codable, Sendable, Equatable, Hashable {
    /// What was done.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Action: String, Codable, Sendable, TolerantStringEnum {
        case trialExtended = "trial_extended"
        case promoGranted = "promo_granted"
        case purchasesRestored = "purchases_restored"
        case reportFiled = "report_filed"
        case dataExported = "data_exported"
        /// The AI teammate handed the conversation to the team. Nothing was done for the person, so the chat
        /// shows it without the check.
        case handedOff = "handed_off"
        case custom
        /// The case used for values this SDK version does not know.
        package static var fallback: Action { .custom }

        /// Decodes the raw value; values this SDK version does not know become `.custom`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// What was done.
    public var action: Action
    /// The line to show, for example "Trial extended to 14 Nov".
    public var text: String

    /// Creates a receipt.
    @_spi(Fixtures) public init(action: Action, text: String) {
        self.action = action
        self.text = text
    }
}

/// One part of a message.
///
/// Unknown part types decode as `.unknown` so new server content never crashes old SDKs.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum MessagePart: Sendable, Equatable, Hashable, Codable {
    case text(String)
    case image(ImagePart)
    case card(CardPart)
    case receipt(ReceiptPart)
    /// A part type this SDK version does not know.
    case unknown(type: String)

    private enum Keys: String, CodingKey { case type, text }

    /// Decodes the wire format; values this SDK version does not know are kept as unknown.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        do {
            switch type {
            case "text": self = .text(try c.decode(String.self, forKey: .text))
            case "image": self = .image(try ImagePart(from: decoder))
            case "card": self = .card(try CardPart(from: decoder))
            case "receipt": self = .receipt(try ReceiptPart(from: decoder))
            default: self = .unknown(type: type)
            }
        } catch {
            self = .unknown(type: type)
        }
    }

    /// Encodes the wire format.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .image(let part):
            try c.encode("image", forKey: .type)
            try part.encode(to: encoder)
        case .card(let part):
            try c.encode("card", forKey: .type)
            try part.encode(to: encoder)
        case .receipt(let part):
            try c.encode("receipt", forKey: .type)
            try part.encode(to: encoder)
        case .unknown(let type): try c.encode(type, forKey: .type)
        }
    }
}

/// Why a team or AI message arrived before the person wrote.
///
/// Shown to the person, never configurable.
public struct PingOrigin: Codable, Sendable, Equatable, Hashable {
    /// Manual (a teammate wrote it) or play (a rule sent it).
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Kind: String, Codable, Sendable, TolerantStringEnum {
        case manual, play
        /// The case used for values this SDK version does not know.
        package static var fallback: Kind { .manual }

        /// Decodes the raw value; values this SDK version does not know become `.manual`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// Manual or play.
    public var kind: Kind
    /// The play that sent it.
    public var playId: String?
    /// For example "Sent automatically after you closed Plans", localized by the server.
    public var explanation: String
    /// A structured reason (`manual`, `moment`, `store_event`, `scheduled`) with optional parameters.
    public var reason: PingReason?

    /// Creates a ping origin.
    @_spi(Fixtures) public init(kind: Kind, playId: String? = nil, explanation: String, reason: PingReason? = nil) {
        self.kind = kind
        self.playId = playId
        self.explanation = explanation
        self.reason = reason
    }
}

/// Why a ping was sent, machine-readable.
public struct PingReason: Codable, Sendable, Equatable, Hashable {
    /// Reason codes.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum Code: String, Codable, Sendable, TolerantStringEnum {
        case manual, moment
        case storeEvent = "store_event"
        case scheduled
        /// A code this SDK version does not know.
        case unknown
        /// The case used for values this SDK version does not know.
        package static var fallback: Code { .unknown }

        /// Decodes the raw value; values this SDK version does not know become `.unknown`.
        public init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
    }
    /// The reason code.
    public var code: Code
    /// Parameters such as the moment name.
    public var params: [String: String]?

    /// Creates a ping reason.
    @_spi(Fixtures) public init(code: Code, params: [String: String]? = nil) {
        self.code = code
        self.params = params
    }
}

/// A machine translation of a message's text parts.
public struct Translation: Codable, Sendable, Equatable, Hashable {
    /// Target language tag.
    public var language: String
    /// The language the message was written in (a language tag), when the server knows it.
    public var from: String?
    /// Translated text parts.
    public var texts: [String]

    private enum Keys: String, CodingKey { case language, from, parts }
    private struct TextPartWire: Codable {
        var type = "text"
        var text: String
    }

    /// Creates a translation.
    @_spi(Fixtures) public init(language: String, from: String? = nil, texts: [String]) {
        self.language = language
        self.from = from
        self.texts = texts
    }

    /// Decodes the wire format; values this SDK version does not know are kept as unknown.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        language = try c.decode(String.self, forKey: .language)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        texts = try c.decodeLossyArray(TextPartWire.self, forKey: .parts).map(\.text)
    }

    /// Encodes the wire format.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(from, forKey: .from)
        try c.encode(texts.map { TextPartWire(text: $0) }, forKey: .parts)
    }
}

/// A message in the thread.
public struct Message: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Server id.
    public var id: String
    /// Position in the thread.
    public var seq: Int
    /// The sender's idempotency key (person messages sent from an SDK).
    public var clientId: String?
    /// Who wrote it.
    public var author: Author
    /// Text, images, cards and receipts.
    public var parts: [MessagePart]
    /// When the server accepted it.
    public var createdAt: Date
    /// Set when the team reached out before the person wrote.
    public var ping: PingOrigin?
    /// Machine translation, when enabled.
    public var translation: Translation?
    /// Plain-text rendering of the whole message, shown for parts or cards this SDK does not know.
    public var fallback: String?

    /// Creates a message.
    @_spi(Fixtures) public init(
        id: String, seq: Int, clientId: String? = nil, author: Author, parts: [MessagePart], createdAt: Date, ping: PingOrigin? = nil,
        translation: Translation? = nil, fallback: String? = nil
    ) {
        self.id = id
        self.seq = seq
        self.clientId = clientId
        self.author = author
        self.parts = parts
        self.createdAt = createdAt
        self.ping = ping
        self.translation = translation
        self.fallback = fallback
    }

    private enum Keys: String, CodingKey { case id, seq, clientId, author, parts, createdAt, ping, translation, fallback }

    /// Decodes the wire format; values this SDK version does not know are kept as unknown.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        seq = try c.decode(Int.self, forKey: .seq)
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
        author = try c.decode(Author.self, forKey: .author)
        parts = try c.decodeLossyArray(MessagePart.self, forKey: .parts)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        ping = try? c.decodeIfPresent(PingOrigin.self, forKey: .ping)
        translation = try? c.decodeIfPresent(Translation.self, forKey: .translation)
        fallback = try? c.decodeIfPresent(String.self, forKey: .fallback)
    }

    /// Encodes the wire format.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(seq, forKey: .seq)
        try c.encodeIfPresent(clientId, forKey: .clientId)
        try c.encode(author, forKey: .author)
        try c.encode(parts, forKey: .parts)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(ping, forKey: .ping)
        try c.encodeIfPresent(translation, forKey: .translation)
        try c.encodeIfPresent(fallback, forKey: .fallback)
    }

    /// The plain text of all text parts, joined by newlines.
    public var plainText: String {
        parts.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    /// True for messages written by the person on this or another device.
    public var isFromPerson: Bool { author.kind == .person }
}
