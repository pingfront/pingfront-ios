#if os(iOS)
    import Foundation
    import PingFrontCore
    import PingFrontUI
    import StoreKit
    import SwiftUI
    import UIKit

    /// StoreKit's own views in the chat: the product inside an offer card and, when the app asks for it, the
    /// subscription store for apps without a paywall of their own.
    ///
    /// Purchases from both carry the person's
    /// `appAccountToken` and the card's store offer, and are reported and finished like any offer-card purchase.
    @MainActor final class StoreKitSurfaces: StoreSurfaceProviding {
        let handler: StoreKitOfferHandler
        let offersSubscriptionStore: Bool
        private weak var presented: UIViewController?

        init(handler: StoreKitOfferHandler, offersSubscriptionStore: Bool) {
            self.handler = handler
            self.offersSubscriptionStore = offersSubscriptionStore
        }

        func productView(productId: String, offer: StoreOffer?, outcome: @escaping @MainActor (OfferOutcome) -> Void) -> AnyView? {
            // StoreKit's views can't apply a promotional offer (it needs the server's signature at purchase), so they
            // would show the full price under a card that promises the offer price: the card keeps its own price line
            // and button, which buy with the signed offer.
            guard offer?.kind != .promotional else { return nil }
            let handler = handler
            let options: (Product) async -> Set<Product.PurchaseOption> = { product in
                (try? await handler.purchaseOptions(for: offer, product: product)) ?? []
            }
            let completion: (Product, Result<Product.PurchaseResult, any Error>) async -> Void = { _, result in
                switch result {
                case .success(let purchase): outcome(await handler.finish(purchase))
                case .failure(let error): outcome(.failed(StoreKitSupport.offerError(error)))
                }
            }
            if #available(iOS 26, *), offer?.kind != .code {
                // A subscription offer with Apple's own price line (the offer price and what follows it).
                return AnyView(
                    SubscriptionOfferView(id: productId)
                        .subscriptionOfferViewStyle(.compact)
                        .modifier(PreferredOffer(offer: offer))
                        .inAppPurchaseOptions(options)
                        .onInAppPurchaseCompletion(perform: completion))
            }
            return AnyView(
                ProductView(id: productId)
                    .productViewStyle(.compact)
                    .modifier(PreferredOffer(offer: offer))
                    .inAppPurchaseOptions(options)
                    .onInAppPurchaseCompletion(perform: completion))
        }

        func presentSubscriptionStore(productId: String, look: ResolvedLook, outcome: @escaping @MainActor (OfferOutcome) -> Void) {
            guard presented == nil, let top = Presentation.topViewController() else { return }
            let handler = handler
            let accent = look.accent.dynamicColor
            Task { @MainActor [weak self] in
                guard let product = try? await Product.products(for: [productId]).first,
                    let group = product.subscription?.subscriptionGroupID
                else {
                    outcome(.unavailable)
                    return
                }
                let store = SubscriptionStoreView(groupID: group) {
                    // The app's own marketing header: its icon and name.
                    VStack(spacing: 10) {
                        AppIconView(look: look, size: 72)
                        Text(look.appName).font(.title2.weight(.bold))
                    }
                    .padding(.top, 24)
                }
                .subscriptionStoreControlStyle(.prominentPicker)
                .storeButton(.visible, for: .restorePurchases)
                .inAppPurchaseOptions { product in (try? await handler.purchaseOptions(for: nil, product: product)) ?? [] }
                .onInAppPurchaseCompletion { [weak self] _, result in
                    switch result {
                    case .success(let purchase):
                        let mapped = await handler.finish(purchase)
                        outcome(mapped)
                        if mapped == .purchased || mapped == .pending { self?.presented?.dismiss(animated: true) }
                    case .failure(let error): outcome(.failed(StoreKitSupport.offerError(error)))
                    }
                }
                .tint(accent)
                let host = UIHostingController(rootView: store)
                top.present(host, animated: true)
                self?.presented = host
            }
        }
    }

    /// Prefers the card's store offer (promotional, win-back or intro) in StoreKit's views (iOS 18+).
    private struct PreferredOffer: ViewModifier {
        let offer: StoreOffer?

        func body(content: Content) -> some View {
            if #available(iOS 18, *), let offer {
                content.preferredSubscriptionOffer { _, _, eligible in
                    switch offer.kind {
                    case .promotional: eligible.first { $0.type == .promotional && $0.id == offer.id }
                    case .winback: eligible.first { $0.type == .winBack && $0.id == offer.id }
                    case .intro: eligible.first { $0.type == .introductory }
                    case .code, .unknown: nil
                    }
                }
            } else {
                content
            }
        }
    }
#endif
