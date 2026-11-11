import Foundation
import PingFrontCore
import StoreKit
internal import os

#if os(iOS)
    import UIKit
#endif

/// Opens Apple's own App Store sheets for store action cards, over the chat: manage subscriptions, the
/// billing-issue message, refund requests, offer code redemption and restore.
///
/// When a sheet closes it
/// compares the App Store state before and after, so the chat can show what changed as a receipt.
@MainActor final class StoreKitActionHandler: StoreActionHandling {
    let billing: BillingMessages
    private weak var pingFront: PingFront?

    init(billing: BillingMessages, pingFront: PingFront) {
        self.billing = billing
        self.pingFront = pingFront
    }

    func perform(_ request: StoreActionRequest) async -> StoreActionOutcome {
        #if os(iOS)
            guard let scene = activeScene() else { return .unavailable }
            let card = request.card
            let groups = await StoreState.groups(for: card)
            let before = await StoreState.current(groups: groups)
            do {
                switch card.action {
                case .manageSubscriptions, .unknown:
                    try await Self.showManageSubscriptions(in: scene, group: card.subscriptionGroupId)
                case .billingIssue:
                    // Apple's own billing message when one is waiting; otherwise the manage sheet, where the
                    // payment method is one tap away.
                    if !billing.displayPending(in: scene) {
                        try await Self.showManageSubscriptions(in: scene, group: card.subscriptionGroupId)
                    }
                case .requestRefund:
                    guard let id = await StoreState.refundTransactionId(for: card) else { return .unavailable }
                    let status = try await Transaction.beginRefundRequest(for: id, in: scene)
                    return status == .success ? .completed(.refundRequested) : .cancelled
                case .redeemCode:
                    try await AppStore.presentOfferCodeRedeemSheet(in: scene)
                    let after = await StoreState.current(groups: await StoreState.groups(for: card))
                    switch await StoreState.change(from: before, to: after) {
                    case .subscribed(let product)?, .planChanged(let product)?: return .completed(.codeRedeemed(product: product))
                    default: return .completed(nil)
                    }
                case .restorePurchases:
                    try await AppStore.sync()
                    // Re-report the entitlement now, not at the next transaction update.
                    pingFront?.setEntitlement(await StoreKitEntitlements.current())
                    return .completed(.purchasesRestored)
                }
            } catch {
                Log.storekit(.error)?.error("Store action failed: \(String(describing: error), privacy: .private)")
                return .failed
            }
            let after = await StoreState.current(groups: groups)
            return .completed(await StoreState.change(from: before, to: after))
        #else
            return .unavailable
        #endif
    }

    #if os(iOS)
        private static func showManageSubscriptions(in scene: UIWindowScene, group: String?) async throws {
            if let group {
                try await AppStore.showManageSubscriptions(in: scene, subscriptionGroupID: group)
            } else {
                try await AppStore.showManageSubscriptions(in: scene)
            }
        }
    #endif
}

/// StoreKit's own in-app messages (billing issue, price-increase consent, win-back offers, generic).
///
/// Each is
/// reported as the `store_message` moment (`reason`), so plays can follow up. While the chat is open the message
/// waits and shows once the chat closes, so Apple's sheet never covers a conversation; a billing message can also
/// be shown right away from a billing card or the plan status line. Otherwise StoreKit shows it as usual.
@MainActor final class BillingMessages {
    private weak var pingFront: PingFront?
    #if os(iOS)
        private var deferred: [StoreKit.Message] = []
    #endif

    init(pingFront: PingFront) { self.pingFront = pingFront }

    /// Listens to `StoreKit.Message.messages` until the module is torn down.
    ///
    /// Reporting the moment and waiting for the chat to close run as child tasks (`async let`), cancelled with the
    /// module's own task. `hasInstall` keeps the promise that a new install sends nothing at launch, which is when
    /// StoreKit hands its messages over: only an install that already has a session reports them.
    func watch(hasInstall: @escaping @MainActor @Sendable () async -> Bool) async {
        #if os(iOS)
            let (reasons, report) = AsyncStream.makeStream(of: String.self)
            let (waits, wait) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            async let reported: Void = reportMoments(reasons, hasInstall: hasInstall)
            async let shown: Void = showDeferred(waits)
            for await message in StoreKit.Message.messages {
                report.yield(Self.reason(message))
                if pingFront?.isChatVisible == true {
                    deferred.append(message)
                    wait.yield()
                } else if let scene = activeScene() {
                    try? message.display(in: scene)
                }
            }
            report.finish()
            wait.finish()
            _ = await (reported, shown)
        #endif
    }

    #if os(iOS)
        /// Shows a waiting billing message, if any.
        ///
        /// Returns whether one was shown.
        func displayPending(in scene: UIWindowScene) -> Bool {
            guard let index = deferred.firstIndex(where: { Self.reason($0) == "billing_issue" }) else { return false }
            let message = deferred.remove(at: index)
            do {
                try message.display(in: scene)
                return true
            } catch {
                return false
            }
        }

        /// `store_message` for each message, one at a time, only from an install that already has a session.
        private func reportMoments(_ reasons: AsyncStream<String>, hasInstall: @MainActor @Sendable () async -> Bool) async {
            for await reason in reasons {
                guard let pingFront, await hasInstall() else { continue }
                _ = await pingFront.moment("store_message", props: ["reason": .string(reason)])
            }
        }

        /// Each time a message waits for the chat, shows what is waiting once the chat closes.
        private func showDeferred(_ waits: AsyncStream<Void>) async {
            for await _ in waits { await showWhenChatCloses() }
        }

        private func showWhenChatCloses() async {
            // Subscribed before the check, so a close in between is not missed.
            guard let events = pingFront?.events else { return }
            if pingFront?.isChatVisible == true {
                for await event in events where event == .chatClosed { break }
            }
            // Cancelled (teardown): show nothing.
            guard !Task.isCancelled else { return }
            while !deferred.isEmpty, let scene = activeScene() {
                try? deferred.removeFirst().display(in: scene)
            }
        }

        /// `billing_issue`, `price_increase`, `win_back_offer` or `generic`.
        static func reason(_ message: StoreKit.Message) -> String {
            if message.reason == .billingIssue { return "billing_issue" }
            if message.reason == .priceIncreaseConsent { return "price_increase" }
            if #available(iOS 18, *), message.reason == .winBackOffer { return "win_back_offer" }
            return "generic"
        }
    #endif
}

/// The App Store state a store action can change: active products, auto-renew and billing trouble per
/// subscription group.
struct StoreState: Equatable, Sendable {
    /// Active product ids.
    var active: Set<String> = []
    /// The active product per subscription group.
    var productByGroup: [String: String] = [:]
    /// Auto-renew per subscription group.
    var autoRenew: [String: Bool] = [:]
    /// Groups in billing retry or grace.
    var billingTrouble: Set<String> = []

    /// The subscription groups to look at: the card's, its product's, and every entitled subscription's.
    static func groups(for card: StoreActionCard) async -> Set<String> {
        var groups = Set<String>()
        if let group = card.subscriptionGroupId { groups.insert(group) }
        if let productId = card.productId, let product = try? await Product.products(for: [productId]).first,
            let group = product.subscription?.subscriptionGroupID
        {
            groups.insert(group)
        }
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, let group = transaction.subscriptionGroupID { groups.insert(group) }
        }
        return groups
    }

    static func current(groups: Set<String>) async -> StoreState {
        var state = StoreState()
        for await result in Transaction.currentEntitlements {
            // An upgraded transaction was replaced by the plan it upgraded to.
            guard case .verified(let transaction) = result, transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            state.active.insert(transaction.productID)
            if let group = transaction.subscriptionGroupID { state.productByGroup[group] = transaction.productID }
        }
        for group in groups {
            guard let statuses = try? await Product.SubscriptionInfo.status(for: group) else { continue }
            for status in statuses {
                if status.state == .inBillingRetryPeriod || status.state == .inGracePeriod { state.billingTrouble.insert(group) }
                if case .verified(let renewal) = status.renewalInfo { state.autoRenew[group] = renewal.willAutoRenew }
            }
        }
        return state
    }

    /// The one change worth a receipt, most important first.
    static func change(from before: StoreState, to after: StoreState) async -> StoreChange? {
        let fixed = before.billingTrouble.subtracting(after.billingTrouble).filter { after.productByGroup[$0] != nil }
        if !fixed.isEmpty { return .paymentUpdated }
        for (group, product) in after.productByGroup where before.productByGroup[group] != product {
            let name = await displayName(product)
            return before.productByGroup[group] == nil ? .subscribed(product: name) : .planChanged(product: name)
        }
        if let added = after.active.subtracting(before.active).first { return .subscribed(product: await displayName(added)) }
        for (group, renews) in after.autoRenew where before.autoRenew[group] != nil && before.autoRenew[group] != renews {
            return renews ? .autoRenewOn : .autoRenewOff
        }
        return nil
    }

    /// The transaction a refund request is for: the card's, or the latest for its product.
    static func refundTransactionId(for card: StoreActionCard) async -> UInt64? {
        if let id = card.transactionId.flatMap(UInt64.init) { return id }
        guard let productId = card.productId, case .verified(let transaction)? = await Transaction.latest(for: productId) else {
            return nil
        }
        return transaction.id
    }

    private static func displayName(_ productId: String) async -> String {
        (try? await Product.products(for: [productId]).first?.displayName) ?? productId
    }
}
