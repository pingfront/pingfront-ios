public import Foundation

/// An optional module.
///
/// Modules register through `ModuleContext`, so Core never imports them.
///
/// The modules in this package add static members: `.chatUI`, `.push`, `.storeKit`, `.reports`. The vendor
/// adapters, one package per vendor (`pingfront-ios-revenuecat`, `-superwall`, `-adapty`), add `.revenueCat`,
/// `.superwall(…)` and `.adapty(…)` (`config.use(.revenueCat)`). Your own module registers through the same context:
/// ```swift
/// extension PingFrontModule {
///     static var myOffers: PingFrontModule {
///         PingFrontModule(id: "com.example.offers") { context in
///             context.setOfferHandler(MyOfferHandler())  // your type conforming to OfferHandling
///         }
///     }
/// }
/// ```
public struct PingFrontModule: Sendable {
    /// A unique id.
    ///
    /// Adding the same id twice has no effect.
    public let id: String
    let install: @MainActor @Sendable (ModuleContext) -> Void

    /// Creates a module. `install` runs once, on the main actor, during `configure`.
    public init(id: String, install: @escaping @MainActor @Sendable (ModuleContext) -> Void) {
        self.id = id
        self.install = install
    }
}

/// Presents and dismisses the chat.
///
/// Provided by `PingFrontUI`.
@MainActor public protocol ChatPresenting: AnyObject {
    /// Presents the chat sheet, optionally prefilled for a topic.
    func presentChat(topic: ChatTopic?)
    /// Dismisses the SDK-presented chat.
    func dismissChat()
    /// Dismisses the SDK-presented chat and returns once the dismissal finished.
    func dismissChatAndWait() async
    /// Whether this presenter has a chat on screen, or one about to open. Without one, `PingFront.closeChat()` returns
    /// at once: a chat the app embeds (`PingFrontChatView`) is the app's to remove.
    var isPresentingChat: Bool { get }
    /// Opens a web URL or deep link from a card.
    func open(_ url: URL)
    /// Opens a web URL or deep link from a card, and returns whether something opened it (a link card reports a link
    /// that didn't open).
    func openLink(_ url: URL) async -> Bool
    /// Presents a plain text bug report form (used when the reports module is not installed).
    func presentSimpleReport()
}

extension ChatPresenting {
    /// By default, dismisses and returns at once (for presenters without an animation to wait for).
    public func dismissChatAndWait() async { dismissChat() }
    /// By default, true: `closeChat()` asks a presenter that doesn't say to dismiss.
    public var isPresentingChat: Bool { true }
    /// By default, calls `open(_:)` and counts the link as opened.
    public func openLink(_ url: URL) async -> Bool {
        open(url)
        return true
    }
}

/// A presenter whose `dismissChatAndWait()` returns only once its chat is gone (the SDK's own sheet), so
/// `PingFront.closeChat()` does not also wait for the chat to report `.chatClosed`.
@MainActor package protocol ReportsChatDismissal: ChatPresenting {}

/// Handles offer cards.
///
/// Vendor adapters implement this to show their paywall.
@MainActor public protocol OfferHandling: AnyObject {
    /// Shows the offer and reports what happened.
    func handle(_ request: OfferRequest) async -> OfferOutcome
}

/// Produces offer slots (for example from StoreKit products) so the team can reference them in cards.
///
/// Each source owns its slots: what it reports replaces its earlier slots and leaves the app's own
/// (`setOffers(_:)`) and other modules' slots alone.
public protocol OfferSource: Sendable {
    /// Where these slots are built; stamped on every slot. Defaults to `.app`.
    var slotSource: OfferSlot.Source { get }
    /// The current offers.
    func offers() async -> [OfferSlot]
    /// The offers now and whenever they change. Defaults to `offers()` once.
    func offerUpdates() -> AsyncStream<[OfferSlot]>
}

extension OfferSource {
    /// `.app`.
    public var slotSource: OfferSlot.Source { .app }

    /// `offers()` once.
    public func offerUpdates() -> AsyncStream<[OfferSlot]> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(await offers())
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Streams the person's entitlement (StoreKit 2, RevenueCat, …).
public protocol EntitlementSource: Sendable {
    /// Entitlement updates, starting with the current value.
    func entitlementUpdates() -> AsyncStream<Entitlement>
}

/// A store action card the person tapped.
public struct StoreActionRequest: Sendable, Equatable {
    /// The card.
    public let card: StoreActionCard
    /// The id of the message that carries the card.
    public let messageId: String

    /// Creates a request, as the chat does when the person taps a store action card.
    @_spi(Fixtures) public init(card: StoreActionCard, messageId: String) {
        self.card = card
        self.messageId = messageId
    }
}

/// What changed in the App Store while Apple's sheet was open; the chat shows it as a receipt.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum StoreChange: Sendable, Equatable {
    /// A subscription in billing retry or grace is active again.
    case paymentUpdated
    /// A new subscription or purchase, with the product's display name.
    case subscribed(product: String)
    /// Another plan in the same subscription group.
    case planChanged(product: String)
    /// Auto-renew was turned off.
    case autoRenewOff
    /// Auto-renew was turned back on.
    case autoRenewOn
    /// Apple accepted a refund request for review.
    case refundRequested
    /// An offer code was redeemed, with the product's display name when known.
    case codeRedeemed(product: String?)
    /// Purchases were synced with the App Store.
    case purchasesRestored
}

/// What happened when a store action ran.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum StoreActionOutcome: Sendable, Equatable {
    /// Apple's sheet closed; `change` is what changed, if anything.
    case completed(StoreChange?)
    /// The person closed the sheet without doing anything.
    case cancelled
    /// The action can't run here (no window, no matching transaction).
    case unavailable
    /// The App Store returned an error.
    case failed
}

/// Opens Apple's App Store sheets for store action cards (the StoreKit module provides one).
@MainActor public protocol StoreActionHandling: AnyObject {
    /// Opens the sheet for `request` and returns once it closes.
    func perform(_ request: StoreActionRequest) async -> StoreActionOutcome
}

/// Shows the native review prompt.
@MainActor public protocol ReviewRequesting: AnyObject {
    /// Requests a review. Returns `false` if the prompt could not be shown.
    func requestReview() async -> Bool
}

/// Presents the full bug report flow (screenshot, markup).
@MainActor public protocol ReportPresenting: AnyObject {
    /// Presents the report flow.
    func presentReport(prefill: String?)
}

/// Adds the log tail and device state to bug reports.
public protocol ReportContextProviding: Sendable {
    /// Recent log lines (at most 64 KB) and state such as screen, battery, network.
    func reportContext() async -> ReportContext
}

/// Extra context attached to a bug report.
public struct ReportContext: Sendable, Equatable {
    /// Recent log lines.
    public var logTail: String?
    /// Device state, for example `["screen": "Settings", "battery": "45%"]`.
    public var state: [String: String]

    /// Creates a report context.
    public init(logTail: String? = nil, state: [String: String] = [:]) {
        self.logTail = logTail
        self.state = state
    }
}

/// An offer card the person tapped.
public struct OfferRequest: Sendable, Equatable {
    /// The store offer the card redeems (promotional, win-back, offer code), for hosts with their own
    /// paywall (RevenueCat, Superwall) to show the promo.
    public var storeOffer: StoreOffer? = nil
    /// The `OfferSlot.id` from the card.
    public let offerId: String
    /// The matching slot from `setOffers(_:)` or an offer source, if any.
    public let slot: OfferSlot?
    /// The card id.
    public let cardId: String
    /// The message id.
    public let messageId: String

    /// Creates a request, as the chat does when the person taps an offer card.
    ///
    /// Apps and adapters use it in tests.
    ///
    /// - Parameters:
    ///   - offerId: The `OfferSlot.id` the card names.
    ///   - slot: The matching slot, if the app or a module reported one.
    ///   - cardId: The card's id.
    ///   - messageId: The id of the message that carries the card.
    ///   - storeOffer: The store offer the card redeems, if any.
    @_spi(Fixtures) public init(offerId: String, slot: OfferSlot? = nil, cardId: String, messageId: String, storeOffer: StoreOffer? = nil) {
        self.offerId = offerId
        self.slot = slot
        self.cardId = cardId
        self.messageId = messageId
        self.storeOffer = storeOffer
    }
}

/// What happened when an offer was shown.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum OfferOutcome: Sendable, Equatable {
    /// The person bought it.
    case purchased
    /// The purchase waits for approval (Ask to Buy, Strong Customer Authentication). The entitlement
    /// arrives later through the store.
    case pending
    /// The person closed the offer.
    case cancelled
    /// The offer is not available.
    case unavailable
    /// Something failed.
    case failed(OfferError)
}

/// Why an offer could not be bought.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum OfferError: Error, Sendable, Equatable {
    /// The store could not verify the transaction.
    case notVerified
    /// No product matches the offer.
    case productNotFound
    /// Purchases are not allowed here (restrictions, storefront, parental controls).
    case notAllowed
    /// The store could not be reached.
    case network
    /// Any other store failure.
    case store
}

/// The registration surface handed to each module's `install` closure.
@MainActor public final class ModuleContext {
    /// The SDK.
    public let pingFront: PingFront

    init(pingFront: PingFront) {
        self.pingFront = pingFront
    }

    /// Sets the chat presenter (`PingFrontUI` does this).
    public func setChatPresenter(_ presenter: any ChatPresenting) { pingFront.registry.chatPresenter = presenter }

    /// Reports the host app's name, AccentColor and icon (inferred look, and `hostLook` for the dashboard).
    public func setHostApp(name: String, accent: PingFrontColor?, iconPNG: Data?) {
        pingFront.registry.host = HostAppInfo(appName: name, accent: accent, iconPNG: iconPNG, appVersion: DeviceInfo.appVersion)
    }

    /// Adds the host app icon once it is rendered (128 px PNG).
    ///
    /// The chat and the dashboard's `hostLook`
    /// pick it up.
    public func setHostIcon(_ png: Data) {
        pingFront.registry.host?.iconPNG = png
        pingFront.refreshLook()
        pingFront.engine?.hostLookChanged()
    }

    /// Sets the offer handler used when the app has not set `onOffer`.
    public func setOfferHandler(_ handler: any OfferHandling) { pingFront.registry.offerHandler = handler }

    /// Adds a source of offer slots.
    public func addOfferSource(_ source: any OfferSource) { pingFront.registry.offerSources.append(source) }

    /// Native store views for the chat (the StoreKit module's product views and paywall).
    ///
    /// Typed loosely so Core
    /// stays free of SwiftUI; the chat UI knows the protocol.
    package func setStoreSurfaces(_ surfaces: AnyObject) { pingFront.registry.storeSurfaces = surfaces }

    /// Opens Apple's App Store sheets for store action cards.
    public func setStoreActionHandler(_ handler: any StoreActionHandling) { pingFront.registry.storeActionHandler = handler }

    /// Runs `handler` whenever the SDK wipes the person's local data: `logout()`, `eraseMyData()` or a
    /// revoked session.
    ///
    /// Modules drop per-person state here (cached tokens, observers).
    public func onLocalDataWipe(_ handler: @escaping @MainActor () -> Void) { pingFront.onLocalDataWipe(handler) }

    /// Adds an entitlement source.
    ///
    /// Its updates are forwarded like `setEntitlement(_:)`.
    public func addEntitlementSource(_ source: any EntitlementSource) { pingFront.registry.entitlementSources.append(source) }

    /// Sets the native review prompt.
    public func setReviewRequester(_ requester: any ReviewRequesting) { pingFront.registry.reviewRequester = requester }

    /// Sets the full report flow.
    public func setReportPresenter(_ presenter: any ReportPresenting) { pingFront.registry.reportPresenter = presenter }

    /// Sets the report context provider (log tail, device state).
    public func setReportContextProvider(_ provider: any ReportContextProviding) { pingFront.registry.reportContext = provider }

    /// Reports a store detection.
    ///
    /// It is sent only when a live play listens to that store event, and only
    /// once a session exists or the event creates one (`reason: moment`).
    @discardableResult
    public func reportStoreEvent(_ event: StoreEventReport) async -> MomentResult {
        guard let engine = pingFront.engine else { return .failed(.notConfigured) }
        return await engine.storeEvent(event)
    }

    /// True when this install already has a session from an earlier launch (no network).
    ///
    /// Modules that scan state at launch use it to keep the promise that a new install sends nothing then.
    package func hasInstall() async -> Bool {
        guard let engine = pingFront.engine else { return false }
        return await engine.session.hasInstall()
    }

    /// Asks the server to sign an App Store promotional offer for this person (`POST /offers/signature`).
    public func signPromotionalOffer(productId: String, offerId: String) async throws(PingFrontError) -> PromotionalOfferSignature {
        guard let engine = pingFront.engine else { throw .notConfigured }
        return try await engine.client.send(Endpoints.signOffer(OfferSignatureRequest(productId: productId, offerId: offerId)))
    }

    /// Supplies store prices for offer cards (the regular price, and the offer price when there is one).
    public func setOfferPricing(_ pricing: any OfferPricing) { pingFront.registry.offerPricing = pricing }

    /// Lets the chat offer "Turn on notifications" after the person's first message.
    ///
    /// The push module sets it;
    /// it should ask permission the way the host app approved.
    public func setNotificationsRequest(_ request: @escaping @MainActor () async -> Bool) {
        pingFront.registry.notificationsRequest = request
    }

    /// Runs a long-lived operation owned by the SDK.
    ///
    /// It is cancelled on logout-free teardown (reconfigure).
    public func run(_ operation: @escaping @MainActor () async -> Void) {
        pingFront.registry.moduleTasks.append(Task { await operation() })
    }
}

/// What modules registered.
@MainActor final class ModuleRegistry {
    var chatPresenter: (any ChatPresenting)?
    var host: HostAppInfo?
    var offerHandler: (any OfferHandling)?
    var offerSources: [any OfferSource] = []
    var storeActionHandler: (any StoreActionHandling)?
    var storeSurfaces: AnyObject?
    var entitlementSources: [any EntitlementSource] = []
    var reviewRequester: (any ReviewRequesting)?
    var reportPresenter: (any ReportPresenting)?
    var reportContext: (any ReportContextProviding)?
    var moduleTasks: [Task<Void, Never>] = []
    var installed: [String] = []
    var notificationsRequest: (@MainActor () async -> Bool)?
    var offerPricing: (any OfferPricing)?

    func cancelAll() {
        moduleTasks.forEach { $0.cancel() }
        moduleTasks = []
    }

    /// Forgets everything modules registered (reconfigure installs them again, without duplicates).
    func reset() {
        chatPresenter = nil
        offerHandler = nil
        reviewRequester = nil
        reportPresenter = nil
        reportContext = nil
        offerSources = []
        storeActionHandler = nil
        storeSurfaces = nil
        entitlementSources = []
        installed = []
        notificationsRequest = nil
        offerPricing = nil
    }
}

/// The ids of the modules in this package (one naming scheme: `pingfront.<name>`).
package enum ModuleID {
    package static let chatUI = "pingfront.chat-ui"
    package static let push = "pingfront.push"
    package static let storeKit = "pingfront.storekit"
    package static let reports = "pingfront.reports"
}

/// Prices for offer cards, from the store.
public protocol OfferPricing: Sendable {
    /// The regular price and, for a store offer, its price, formatted for display.
    func price(productId: String, offer: StoreOffer?) async -> OfferPrice?
}

/// A product's price for an offer card.
public struct OfferPrice: Sendable, Equatable {
    /// The regular price ("€29.99").
    public var regular: String
    /// The offer price, shown with the regular price struck through.
    public var discounted: String?
    /// The product's display name in the store ("Ledgerly Plus Yearly").
    public var displayName: String?
    /// Set when the person subscribes to another plan in the same subscription group: the ISO-8601 period of
    /// this product (`P1Y`), so the card can say "Switch to yearly".
    ///
    /// The store handles the crossgrade.
    public var switchPeriod: String?

    /// Creates a price.
    public init(regular: String, discounted: String? = nil, displayName: String? = nil, switchPeriod: String? = nil) {
        self.regular = regular
        self.discounted = discounted
        self.displayName = displayName
        self.switchPeriod = switchPeriod
    }
}
