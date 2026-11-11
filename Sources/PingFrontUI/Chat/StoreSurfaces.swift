#if canImport(UIKit)
    package import SwiftUI
    @_spi(Fixtures) package import PingFrontCore

    /// Native store views the StoreKit module puts in the chat: the product inside an offer card (StoreKit's
    /// own product view, with the real price, the offer price and the system buy button), and an in-chat
    /// subscription store for apps without their own paywall.
    ///
    /// The chat falls back to its own card without them.
    @MainActor package protocol StoreSurfaceProviding: AnyObject {
        /// StoreKit's product view for an offer card, or `nil` to keep the chat's own card.
        ///
        /// - Parameters:
        ///   - productId: The store product.
        ///   - offer: The card's store offer, preferred in the view.
        ///   - outcome: Called when a purchase from the view ends (purchased, pending approval, cancelled).
        /// - Returns: The view, or `nil` to keep the chat's own card.
        func productView(productId: String, offer: StoreOffer?, outcome: @escaping @MainActor (OfferOutcome) -> Void) -> AnyView?
        /// Whether offer cards for subscriptions can open StoreKit's subscription store.
        var offersSubscriptionStore: Bool { get }
        /// Opens StoreKit's subscription store for the product's group over the chat.
        func presentSubscriptionStore(productId: String, look: ResolvedLook, outcome: @escaping @MainActor (OfferOutcome) -> Void)
    }

    extension PingFront {
        /// The StoreKit module's native views, unless the app shows its own paywall (`onOffer`).
        package var nativeStore: (any StoreSurfaceProviding)? {
            guard onOffer == nil else { return nil }
            return storeSurfaces as? any StoreSurfaceProviding
        }
    }

    /// The plan as one centered line at the end of the thread: "Ledgerly Plus renews 12 Nov".
    ///
    /// A payment issue
    /// is red and carries the in-app "Update payment method" button.
    struct PlanStatusLine: View {
        let pingFront: PingFront
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @Environment(\.timeZone) private var timeZone
        @State private var productName: String?

        var body: some View {
            if let entitlement = pingFront.planEntitlement, let status = PlanStatus(entitlement) {
                let t = L10n(locale)
                let name = productName ?? planName(entitlement)
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: status.needsPaymentFix ? "exclamationmark.circle.fill" : symbol(status))
                            .foregroundStyle(status.needsPaymentFix ? theme.stop : theme.muted)
                            .accessibilityHidden(true)
                        Text(text(status, name: name, t))
                            .foregroundStyle(status.needsPaymentFix ? theme.stop : theme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .font(.footnote.weight(.semibold))
                    .accessibilityElement(children: .combine)
                    if entitlement.isTestPurchase {
                        Text(t("Test purchase"))
                            .font(.caption)
                            .foregroundStyle(theme.muted)
                    }
                    if status.needsPaymentFix {
                        Button {
                            pingFront.performStoreAction(StoreActionCard(id: "plan_status", action: .billingIssue))
                        } label: {
                            Label(t("Update payment method"), systemImage: "creditcard")
                        }
                        .buttonStyle(PillButtonStyle(selected: false))
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .task(id: entitlement.productId) {
                    guard let id = entitlement.productId, let pricing = pingFront.offerPricing else { return }
                    productName = await pricing.price(productId: id, offer: nil)?.displayName
                }
            }
        }

        private func planName(_ entitlement: Entitlement) -> String {
            if let id = entitlement.productId, let slot = pingFront.offerSlots.first(where: { $0.products.contains { $0.id == id } }) {
                return slot.title
            }
            return L10n(locale)("Your plan")
        }

        private func symbol(_ status: PlanStatus) -> String {
            switch status {
            case .renews: "arrow.triangle.2.circlepath"
            case .ends, .ended: "calendar"
            case .lifetime: "checkmark.seal"
            case .paymentIssue: "exclamationmark.circle.fill"
            }
        }

        private func text(_ status: PlanStatus, name: String, _ t: L10n) -> String {
            switch status {
            case .renews(let date): t("%1$@ renews %2$@", name, day(date))
            case .ends(let date): t("%1$@ ends %2$@", name, day(date))
            case .ended(let date): t("%1$@ ended %2$@", name, day(date))
            case .lifetime: t("%@ is yours for good", name)
            case .paymentIssue(let date?): t("Payment issue: update by %@", day(date))
            case .paymentIssue(nil): t("Payment issue: update your payment method")
            }
        }

        private func day(_ date: Date) -> String {
            var style = Date.FormatStyle(date: .omitted, time: .omitted).day().month(.abbreviated)
            // A yearly plan renews on today's date next year: name the year whenever it isn't this one.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            if calendar.component(.year, from: date) != calendar.component(.year, from: .now) { style = style.year() }
            style.locale = locale
            style.timeZone = timeZone
            return date.formatted(style)
        }
    }
#endif
