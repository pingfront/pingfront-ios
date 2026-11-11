import Foundation
public import PingFrontCore
public import StoreKit
internal import os

#if os(iOS)
    import UIKit
#endif

extension PingFrontModule {
    /// StoreKit 2: reports the person's entitlement automatically, handles offer cards with a
    /// purchase sheet, opens Apple's App Store sheets for store action cards (manage subscriptions,
    /// billing issue, refund, offer code, restore), and shows the native review prompt for review cards.
    public static var storeKit: PingFrontModule { storeKit(products: []) }

    /// StoreKit 2 with the product ids the team can offer in offer cards.
    ///
    /// Each product becomes an `OfferSlot` whose id is the product id (characters outside
    /// `A-Z a-z 0-9 _ . -` become `_`).
    ///
    /// The module never finishes your transactions: it only reads `Transaction.currentEntitlements` and
    /// `Transaction.updates`, so your own transaction handling keeps working unchanged.
    ///
    /// Purchases from offer cards pass `PingFront.shared.storeAccountToken` as `appAccountToken`. Do the
    /// same in your own purchases so App Store notifications match the person.
    ///
    /// - Parameters:
    ///   - products: Product ids the team can offer.
    ///   - onPurchase: Receives every verified transaction from an offer card purchase (which the SDK
    ///     started). Unlock the content, then call `transaction.finish()`; you own finishing it. Without
    ///     this handler the SDK finishes the transaction itself after it is verified, and your app sees
    ///     the new entitlement through `Transaction.currentEntitlements`.
    ///   - subscriptionStore: Offer cards for subscriptions also offer StoreKit's subscription store
    ///     (`SubscriptionStoreView` with your app's icon and name, tinted with the chat's accent) for apps
    ///     without a paywall of their own. Off by default.
    ///   - shareAppTransaction: Sends the verified `AppTransaction` (the original app version and purchase date)
    ///     as person traits `original_app_version` and `original_purchase_date`, for the team. Off by default:
    ///     nothing is sent without it.
    /// - Returns: The module, for `config.use(_:)`.
    public static func storeKit(
        products: [String], onPurchase: (@MainActor @Sendable (Transaction) async -> Void)? = nil, subscriptionStore: Bool = false,
        shareAppTransaction: Bool = false
    ) -> PingFrontModule {
        PingFrontModule(id: ModuleID.storeKit) { context in
            context.addEntitlementSource(StoreKitEntitlements())
            if !products.isEmpty { context.addOfferSource(StoreKitOffers(productIds: products)) }
            let handler = StoreKitOfferHandler(context: context, productIds: products, onPurchase: onPurchase)
            context.setOfferHandler(handler)
            #if os(iOS)
                // StoreKit's own product view in offer cards, and the subscription store when asked for.
                context.setStoreSurfaces(StoreKitSurfaces(handler: handler, offersSubscriptionStore: subscriptionStore))
            #endif
            if shareAppTransaction { context.run { await AppTransactionTraits.send(to: context.pingFront) } }
            context.setReviewRequester(StoreKitReviewRequester())
            context.setOfferPricing(StoreKitOfferPricing())
            // Store action cards open Apple's own sheets; StoreKit's billing message waits for the card while
            // the chat is open.
            let billing = BillingMessages(pingFront: context.pingFront)
            context.setStoreActionHandler(StoreKitActionHandler(billing: billing, pingFront: context.pingFront))
            context.run { await billing.watch(hasInstall: { await context.hasInstall() }) }
            // Lapses (auto-renew off, expiry, billing problems, refunds), deduplicated and rate-limited.
            let lapses = StoreKitLapses(productIds: products)
            context.run { await lapses.watch(context) }
            // Store detections (read-only): reported only for store events a live play listens to.
            context.run {
                for await update in Transaction.updates {
                    guard let report = StoreKitSupport.report(update) else { continue }
                    await context.reportStoreEvent(report)
                }
            }
        }
    }
}

enum StoreKitSupport {

    /// `OfferSlot.id` allows `[A-Za-z0-9_.-]{1,64}`.
    static func slotId(_ productId: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        let mapped = String(productId.map { allowed.contains($0) ? $0 : "_" }.prefix(64))
        return mapped.isEmpty ? "_" : mapped
    }

    /// The normalized store event for a verified transaction, with its signed JWS. `nil` for unverified
    /// transactions and for products that are not subscriptions.
    static func report(_ result: VerificationResult<Transaction>) -> StoreEventReport? {
        guard case .verified(let transaction) = result else { return nil }
        let name: String
        if transaction.revocationDate != nil {
            name = "refunded"
        } else if transaction.productType == .autoRenewable {
            if isFreeTrial(transaction) {
                name = "trial_started"
            } else {
                name = transaction.id == transaction.originalID ? "subscription_started" : "subscription_renewed"
            }
        } else {
            return nil
        }
        return StoreEventReport(
            name: name,
            productId: transaction.productID,
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID),
            price: transaction.price.map(decimalString),
            currency: transaction.currency?.identifier,
            signedTransaction: result.jwsRepresentation,
            occurredAt: transaction.purchaseDate
        )
    }

    private static func isFreeTrial(_ transaction: Transaction) -> Bool {
        if #available(iOS 17.2, macOS 14.2, *) {
            return transaction.offer?.type == .introductory && transaction.offer?.paymentMode == .freeTrial
        }
        return transaction.offerType == .introductory
    }

    /// `^\d+(\.\d{1,4})?$`, as `StoreMomentProps.price` requires.
    static func decimalString(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 4, .plain)
        let text = NSDecimalNumber(decimal: rounded).stringValue
        return text.hasPrefix("-") ? "0" : text
    }

    /// The promotional-offer purchase option: the compact JWS form, with the legacy signature for SDKs
    /// that cannot use it.
    static func promotionalOption(offerId: String, signature: PromotionalOfferSignature) -> [Product.PurchaseOption] {
        if #available(iOS 17.4, macOS 14.4, *) {
            return Product.PurchaseOption.promotionalOffer(offerId, compactJWS: signature.jws)
        }
        return [
            .promotionalOffer(
                offerID: offerId, keyID: signature.legacy.keyId, nonce: UUID(uuidString: signature.legacy.nonce) ?? UUID(),
                signature: Data(base64Encoded: signature.legacy.signature) ?? Data(), timestamp: Int(signature.legacy.timestamp))
        ]
    }

    /// True when StoreKit says the person may redeem this win-back offer.
    @available(iOS 18, macOS 15, *)
    static func isEligibleForWinBack(_ offerId: String, product: Product) async -> Bool {
        guard let statuses = try? await product.subscription?.status else { return false }
        for status in statuses {
            if case .verified(let renewal) = status.renewalInfo, renewal.eligibleWinBackOfferIDs.contains(offerId) { return true }
        }
        return false
    }

    /// Maps StoreKit failures to the SDK's typed offer errors.
    static func offerError(_ error: any Error) -> OfferError {
        if let error = error as? Product.PurchaseError {
            switch error {
            case .productUnavailable: return .productNotFound
            case .purchaseNotAllowed, .ineligibleForOffer: return .notAllowed
            default: return .store
            }
        }
        if let error = error as? StoreKitError {
            switch error {
            case .networkError: return .network
            case .notAvailableInStorefront, .notEntitled: return .notAllowed
            default: return .store
            }
        }
        return .store
    }

    /// ISO-8601 duration such as `P1M` or `P1Y`.
    static func iso(_ period: Product.SubscriptionPeriod) -> String {
        let unit =
            switch period.unit {
            case .day: "D"
            case .week: "W"
            case .month: "M"
            case .year: "Y"
            @unknown default: "D"
            }
        return "P\(period.value)\(unit)"
    }
}

/// Streams the entitlement from `Transaction.currentEntitlements`, re-read on every `Transaction.updates`.
///
/// Read-only: transactions belong to the host app, so they are never finished here.
struct StoreKitEntitlements: EntitlementSource {
    func entitlementUpdates() -> AsyncStream<Entitlement> {
        AsyncStream { continuation in
            // Owned by the stream: cancelled when the consumer stops iterating.
            let task = Task {
                var last = await Self.current()
                continuation.yield(last)
                // Re-read on every transaction update, and whenever the app becomes active again: purchases the
                // app makes itself come back from `purchase()`, not on `Transaction.updates`, and Apple's sheet
                // makes the app inactive while it shows.
                for await _ in Self.changes() {
                    let next = await Self.current()
                    if next != last {
                        last = next
                        continuation.yield(next)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Transaction updates and, on iOS, the app becoming active.
    static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let updates = Task {
                for await _ in Transaction.updates { continuation.yield() }
            }
            #if os(iOS)
                let active = Task { @MainActor in
                    for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                        continuation.yield()
                    }
                }
            #endif
            continuation.onTermination = { _ in
                updates.cancel()
                #if os(iOS)
                    active.cancel()
                #endif
            }
        }
    }

    /// The strongest current entitlement: lifetime, then subscriptions by state.
    static func current() async -> Entitlement {
        var best = Entitlement(state: .none, source: .storekit)
        for await result in Transaction.currentEntitlements {
            // An upgraded transaction was replaced by the plan it upgraded to.
            guard case .verified(let transaction) = result, !transaction.isUpgraded else { continue }
            let candidate: Entitlement
            switch transaction.productType {
            case .nonConsumable:
                guard transaction.revocationDate == nil else { continue }
                return Entitlement(state: .lifetime, productId: transaction.productID, source: .storekit)
            case .autoRenewable:
                // A renewal state StoreKit doesn't name grants nothing (StoreKit testing lists a declined Ask to
                // Buy request this way, with auto-renew off).
                guard let subscription = await subscription(transaction) else { continue }
                candidate = subscription
            case .nonRenewable:
                candidate = Entitlement(
                    state: transaction.revocationDate == nil ? .active : .cancelled, productId: transaction.productID,
                    renewsAt: transaction.expirationDate, source: .storekit)
            default:
                continue
            }
            if rank(candidate.state) > rank(best.state) { best = candidate }
        }
        // A subscription in billing retry is no longer in currentEntitlements, but the person can still fix the
        // payment: find it through the subscription groups the person has bought in.
        if rank(best.state) < rank(.billingRetry), let retry = await billingTrouble() { return retry }
        return best
    }

    /// A subscription group in billing retry or grace, from the groups of the person's past transactions.
    private static func billingTrouble() async -> Entitlement? {
        var groups = Set<String>()
        for await result in Transaction.all {
            if case .verified(let transaction) = result, let group = transaction.subscriptionGroupID { groups.insert(group) }
        }
        for group in groups {
            guard let statuses = try? await Product.SubscriptionInfo.status(for: group) else { continue }
            for status in statuses where status.state == .inBillingRetryPeriod || status.state == .inGracePeriod {
                guard case .verified(let transaction) = status.transaction else { continue }
                var graceEnd: Date?
                if case .verified(let renewal) = status.renewalInfo { graceEnd = renewal.gracePeriodExpirationDate }
                return Entitlement(
                    state: status.state == .inGracePeriod ? .grace : .billingRetry, productId: transaction.productID,
                    expiresAt: transaction.expirationDate, gracePeriodEndsAt: graceEnd, source: .storekit)
            }
        }
        return nil
    }

    /// A subscription with its dates: the renewal while it auto-renews, the end once cancelled, and the grace end
    /// while a payment is being retried (from the verified renewal info).
    private static func subscription(_ transaction: Transaction) async -> Entitlement? {
        let status = await transaction.subscriptionStatus
        guard
            let state = subscriptionState(
                renewal: status?.state, revoked: transaction.revocationDate != nil, introductory: isIntroductory(transaction))
        else { return nil }
        var willRenew = true
        var graceEnd: Date?
        if let status, case .verified(let renewal) = status.renewalInfo {
            willRenew = renewal.willAutoRenew
            graceEnd = renewal.gracePeriodExpirationDate
        }
        let current = state == .active || state == .trial
        let renewing = willRenew && current
        // Auto-renew off: still usable until the period ends, then gone (the server calls this cancelled too).
        return Entitlement(
            state: current && !willRenew ? .cancelled : state, productId: transaction.productID,
            renewsAt: renewing ? transaction.expirationDate : nil, expiresAt: transaction.expirationDate,
            gracePeriodEndsAt: state == .grace || state == .billingRetry ? graceEnd : nil, source: .storekit)
    }

    /// The state of a subscription transaction from its renewal state; `nil` when StoreKit reports a renewal
    /// state it doesn't name, which grants nothing.
    static func subscriptionState(renewal: Product.SubscriptionInfo.RenewalState?, revoked: Bool, introductory: Bool)
        -> Entitlement.State?
    {
        if revoked { return .cancelled }
        guard let renewal else { return introductory ? .trial : .active }
        switch renewal {
        case .subscribed: return introductory ? .trial : .active
        case .inGracePeriod: return .grace
        case .inBillingRetryPeriod: return .billingRetry
        case .expired: return .expired
        case .revoked: return .cancelled
        default: return nil
        }
    }

    private static func isIntroductory(_ transaction: Transaction) -> Bool {
        if #available(iOS 17.2, macOS 14.2, *) {
            return transaction.offer?.type == .introductory
        }
        return transaction.offerType == .introductory
    }

    private static func rank(_ state: Entitlement.State) -> Int {
        switch state {
        case .lifetime: 7
        case .active: 6
        case .trial: 5
        case .grace: 4
        case .billingRetry: 3
        case .cancelled: 2
        case .expired: 1
        case .none, .unknown: 0
        }
    }
}

/// Builds offer slots from StoreKit products.
struct StoreKitOffers: OfferSource {
    let productIds: [String]

    var slotSource: OfferSlot.Source { .storekit }

    /// The products now, and again whenever the App Store storefront changes (prices and availability follow it).
    func offerUpdates() -> AsyncStream<[OfferSlot]> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(await offers())
                for await _ in Storefront.updates {
                    if Task.isCancelled { break }
                    continuation.yield(await offers())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func offers() async -> [OfferSlot] {
        do {
            let products = try await Product.products(for: productIds)
            return products.map { product in
                OfferSlot(
                    id: StoreKitSupport.slotId(product.id), title: String(product.displayName.prefix(60)), kind: .standard,
                    isAvailable: true,
                    products: [Self.slotProduct(product)], source: .storekit)
            }
        } catch {
            Log.storekit(.error)?.error("Could not load products: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    static func slotProduct(_ product: Product) -> OfferSlot.Product {
        let subscription = product.subscription
        var trial: String?
        if let intro = subscription?.introductoryOffer, intro.paymentMode == .freeTrial {
            trial = StoreKitSupport.iso(intro.period)
        }
        return OfferSlot.Product(
            id: product.id, price: String(product.displayPrice.prefix(40)),
            period: subscription.map { StoreKitSupport.iso($0.subscriptionPeriod) }, trial: trial)
    }
}

/// Shows the purchase sheet for offer cards.
@MainActor final class StoreKitOfferHandler: OfferHandling {
    let context: ModuleContext
    let productIds: [String]
    let onPurchase: (@MainActor @Sendable (Transaction) async -> Void)?

    init(context: ModuleContext, productIds: [String], onPurchase: (@MainActor @Sendable (Transaction) async -> Void)?) {
        self.context = context
        self.productIds = productIds
        self.onPurchase = onPurchase
    }

    func handle(_ request: OfferRequest) async -> OfferOutcome {
        // An offer code opens Apple's redemption sheet; nothing is bought here.
        if request.storeOffer?.kind == .code { return await redeemCode() }
        var ids = Set(productIds)
        ids.insert(request.offerId)
        if let productId = request.storeOffer?.productId { ids.insert(productId) }
        for product in request.slot?.products ?? [] { ids.insert(product.id) }
        do {
            let products = try await Product.products(for: ids)
            let product =
                products.first { $0.id == request.storeOffer?.productId }
                ?? products.first { StoreKitSupport.slotId($0.id) == request.offerId }
                ?? products.first { $0.id == request.slot?.products.first?.id }
            guard let product else {
                Log.storekit(.error)?.error("No StoreKit product matches offer \(request.offerId, privacy: .public).")
                return .unavailable
            }
            let options = try await purchaseOptions(for: request.storeOffer, product: product)
            let result: Product.PurchaseResult
            #if os(iOS)
                if let scene = activeScene() {
                    result = try await product.purchase(confirmIn: scene, options: options)
                } else {
                    result = try await product.purchase(options: options)
                }
            #else
                result = try await product.purchase(options: options)
            #endif
            return await finish(result)
        } catch {
            Log.storekit(.error)?.error("Purchase failed: \(String(describing: error), privacy: .private)")
            return .failed(StoreKitSupport.offerError(error))
        }
    }

    /// The purchase options for a store offer: a server-signed promotional offer, or an eligible win-back
    /// offer (iOS 18+).
    ///
    /// Intro offers apply by themselves; an unknown kind buys at the regular price.
    /// The store offer's purchase option, and whether it already carries an account token.
    private func offerOptions(_ offer: StoreOffer?, product: Product) async throws -> (Set<Product.PurchaseOption>, Bool) {
        guard let offer else { return ([], false) }
        switch offer.kind {
        case .promotional:
            // 404: the offer was not sent to this person; 409: the app has no In-App Purchase key. Either
            // way the person still gets the paywall at the regular price.
            let signature: PromotionalOfferSignature
            do { signature = try await context.signPromotionalOffer(productId: product.id, offerId: offer.id) } catch {
                if error.code == .notFound || error.code == .conflict { return ([], false) }
                throw error
            }
            var options = Set(StoreKitSupport.promotionalOption(offerId: offer.id, signature: signature))
            // The JWS carries no account token: pass the one the server signed for.
            guard let token = UUID(uuidString: signature.appAccountToken) else { return (options, false) }
            options.insert(.appAccountToken(token))
            return (options, true)
        case .winback:
            if #available(iOS 18, macOS 15, *),
                let winBack = product.subscription?.winBackOffers.first(where: { $0.id == offer.id }),
                await StoreKitSupport.isEligibleForWinBack(offer.id, product: product)
            {
                return ([.winBackOffer(winBack)], false)
            }
            return ([], false)
        case .code, .intro, .unknown:
            return ([], false)
        }
    }

    private func redeemCode() async -> OfferOutcome {
        #if os(iOS)
            guard let scene = activeScene() else { return .unavailable }
            do {
                try await AppStore.presentOfferCodeRedeemSheet(in: scene)
                return .pending
            } catch {
                return .failed(StoreKitSupport.offerError(error))
            }
        #else
            return .unavailable
        #endif
    }

    /// Buys with the person's `storeAccountToken` as `appAccountToken`, so App Store Server Notifications
    /// match this person on the server.
    ///
    /// Everything a purchase from the chat passes to StoreKit: the store offer's option and the per-person
    /// `appAccountToken` (a promotional signature carries the token the server signed for).
    func purchaseOptions(for offer: StoreOffer?, product: Product) async throws -> Set<Product.PurchaseOption> {
        let (options, hasToken) = try await offerOptions(offer, product: product)
        guard !hasToken, let token = context.pingFront.storeAccountToken else { return options }
        return options.union([.appAccountToken(token)])
    }

    /// Reports and finishes a purchase the SDK started, and maps it to an outcome.
    func finish(_ result: Product.PurchaseResult) async -> OfferOutcome {
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return .failed(.notVerified) }
            // Purchases do not arrive on Transaction.updates: report this one here.
            if let report = StoreKitSupport.report(verification) { await context.reportStoreEvent(report) }
            // The SDK started this purchase. The host unlocks and finishes it when it asked to; otherwise the
            // SDK finishes it (StoreKit requires every transaction to be finished).
            if let onPurchase { await onPurchase(transaction) } else { await transaction.finish() }
            // A purchase made here doesn't arrive on Transaction.updates: report the new entitlement now.
            context.pingFront.setEntitlement(await StoreKitEntitlements.current())
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }
}

/// The verified app transaction as person traits (opt-in through `shareAppTransaction`).
enum AppTransactionTraits {
    @MainActor static func send(to pingFront: PingFront) async {
        guard case .verified(let app)? = try? await AppTransaction.shared else { return }
        pingFront.setTraits(traits(originalVersion: app.originalAppVersion, originalPurchaseDate: app.originalPurchaseDate))
    }

    /// `original_app_version` and `original_purchase_date` (ISO 8601, UTC).
    static func traits(originalVersion: String, originalPurchaseDate: Date) -> [String: String] {
        [
            "original_app_version": String(originalVersion.prefix(512)),
            "original_purchase_date": originalPurchaseDate.formatted(.iso8601),
        ]
    }
}

/// Store prices for offer cards: the regular price and the promotional, win-back or intro price.
struct StoreKitOfferPricing: OfferPricing {
    func price(productId: String, offer: StoreOffer?) async -> OfferPrice? {
        guard let product = try? await Product.products(for: [productId]).first else { return nil }
        let subscription = product.subscription
        var discounted: String?
        switch offer?.kind {
        case .promotional?: discounted = subscription?.promotionalOffers.first { $0.id == offer?.id }?.displayPrice
        case .winback?:
            if #available(iOS 18, macOS 15, *) { discounted = subscription?.winBackOffers.first { $0.id == offer?.id }?.displayPrice }
        case .intro?: discounted = subscription?.introductoryOffer?.displayPrice
        default: break
        }
        return OfferPrice(
            regular: product.displayPrice, discounted: discounted == product.displayPrice ? nil : discounted,
            displayName: product.displayName, switchPeriod: await Self.switchPeriod(to: product))
    }

    /// The product's period when the person subscribes to another plan in its group (a crossgrade).
    static func switchPeriod(to product: Product) async -> String? {
        guard let subscription = product.subscription else { return nil }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil, !transaction.isUpgraded,
                transaction.subscriptionGroupID == subscription.subscriptionGroupID, transaction.productID != product.id
            else { continue }
            return StoreKitSupport.iso(subscription.subscriptionPeriod)
        }
        return nil
    }
}

/// Shows the native App Store review prompt.
@MainActor final class StoreKitReviewRequester: ReviewRequesting {
    func requestReview() async -> Bool {
        #if os(iOS)
            guard let scene = activeScene() else { return false }
            AppStore.requestReview(in: scene)
            return true
        #else
            return false
        #endif
    }
}

#if os(iOS)
    @MainActor func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
#endif

/// Lapses StoreKit reports through subscription status: auto-renew turned off, expiry, billing
/// problems and refunds. Read-only; reported as store moments.
///
/// Provider webhooks stay canonical: every report carries the signed transaction and a clientId derived
/// from the subscription and the period, so the server stores each lapse once and can match it against
/// App Store Server Notifications. Reports are also rate-limited on the device.
actor StoreKitLapses {
    /// The app's products: their latest transactions are read too, because an expired subscription is no
    /// longer among the current entitlements.
    private let productIds: [String]
    private var reported: [String: Date] = [:]

    init(productIds: [String] = []) { self.productIds = productIds }

    private var recent: [Date] = []
    /// One report per lapse key per day, at most this many reports an hour.
    static let perHour = 10

    /// The store event for a subscription state, or `nil` when nothing lapsed.
    static func event(state: Product.SubscriptionInfo.RenewalState, willAutoRenew: Bool, isTrial: Bool) -> String? {
        switch state {
        case .subscribed: willAutoRenew ? nil : (isTrial ? "trial_cancelled" : "subscription_cancelled")
        case .expired: isTrial ? "trial_expired" : "subscription_expired"
        case .inBillingRetryPeriod, .inGracePeriod: "billing_issue"
        case .revoked: "refunded"
        default: nil
        }
    }

    /// True when `key` may be reported now (and records it).
    func admit(_ key: String, now: Date) -> Bool {
        recent.removeAll { now.timeIntervalSince($0) > 3600 }
        if let last = reported[key], now.timeIntervalSince(last) < 86_400 { return false }
        guard recent.count < Self.perHour else { return false }
        reported[key] = now
        recent.append(now)
        return true
    }

    /// Reports lapses for the person's current subscriptions, then for every status change.
    ///
    /// The launch sweep runs only for an install that already has a session: a new install sends nothing at
    /// launch, and its lapses are reported when they change while the app runs.
    func watch(_ context: ModuleContext) async {
        if await context.hasInstall(), admitSweep(now: .now) { await sweep(context) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await status in Product.SubscriptionInfo.Status.updates {
                    await self.report(status, context: context)
                }
            }
            // Coming back to the foreground re-reads the subscriptions, at most once a minute; each report
            // still goes through `admit` and is sent only when a live play listens to the event.
            group.addTask {
                for await event in AppLifecycle.events() {
                    guard case .foreground = event, await context.hasInstall(), await self.admitSweep(now: .now) else { continue }
                    await self.sweep(context)
                }
            }
        }
    }

    private var lastSweep: Date?
    /// The shortest time between two sweeps.
    static let sweepInterval: TimeInterval = 60

    /// True when a sweep may run now (and records it): at most one per ``sweepInterval``.
    func admitSweep(now: Date) -> Bool {
        if let lastSweep, now.timeIntervalSince(lastSweep) < Self.sweepInterval { return false }
        lastSweep = now
        return true
    }

    private func sweep(_ context: ModuleContext) async {
        for report in await sweepReports() { await context.reportStoreEvent(report) }
    }

    /// The lapse reports for the person's subscriptions now: current entitlements plus the latest transaction
    /// of each of the app's products, deduplicated and rate-limited by ``admit(_:now:)``.
    func sweepReports() async -> [StoreEventReport] {
        var reports: [StoreEventReport] = []
        var seen = Set<UInt64>()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productType == .autoRenewable,
                seen.insert(transaction.originalID).inserted, let status = await transaction.subscriptionStatus,
                let report = report(for: status)
            else { continue }
            reports.append(report)
        }
        for productId in productIds {
            guard case .verified(let transaction)? = await Transaction.latest(for: productId), transaction.productType == .autoRenewable,
                seen.insert(transaction.originalID).inserted, let status = await transaction.subscriptionStatus,
                let report = report(for: status)
            else { continue }
            reports.append(report)
        }
        return reports
    }

    private func report(_ status: Product.SubscriptionInfo.Status, context: ModuleContext) async {
        if let report = report(for: status) { await context.reportStoreEvent(report) }
    }

    /// The lapse report for a status, or `nil` when nothing lapsed or it was already reported.
    func report(for status: Product.SubscriptionInfo.Status) -> StoreEventReport? {
        guard case .verified(let transaction) = status.transaction else { return nil }
        let willAutoRenew: Bool
        if case .verified(let renewal) = status.renewalInfo { willAutoRenew = renewal.willAutoRenew } else { willAutoRenew = true }
        let isTrial: Bool
        if #available(iOS 17.2, macOS 14.2, *) {
            isTrial = transaction.offer?.paymentMode == .freeTrial
        } else {
            isTrial = transaction.offerType == .introductory
        }
        guard let name = Self.event(state: status.state, willAutoRenew: willAutoRenew, isTrial: isTrial) else { return nil }
        let period = transaction.expirationDate.map { String(Int($0.timeIntervalSince1970)) } ?? String(transaction.id)
        let key = "\(name)/\(transaction.originalID)/\(period)"
        guard admit(key, now: .now) else { return nil }
        return StoreEventReport(
            name: name, productId: transaction.productID, transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID), signedTransaction: status.transaction.jwsRepresentation,
            occurredAt: .now, dedupeKey: key)
    }
}
