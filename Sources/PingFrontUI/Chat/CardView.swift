#if canImport(UIKit)
    import SwiftUI
    import PingFrontCore

    /// A card shaped like a Messages rich link preview: a media or icon header, a title and subtitle,
    /// and one full-width capsule button.
    ///
    /// Choices are quick-reply capsules; rating is a star row.
    struct CardView: View {
        let part: CardPart
        let message: Message
        let pingFront: PingFront
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        /// At accessibility sizes cards take the full row so labels wrap by word, not mid-word.
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        /// The store's price for an offer card (regular, and the offer price when there is one).
        @State private var storePrice: OfferPrice?

        var body: some View {
            switch part.card {
            case .choices(let card):
                ChoicesView(card: card, result: part.result, message: message, conversation: pingFront.conversation)
            case .unknown:
                EmptyView()
            case .rating(let card):
                RatingView(card: card, result: part.result, message: message, conversation: pingFront.conversation)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : BubbleMetrics.cardWidth, alignment: .leading)
                    .background(theme.teamBubble, in: RoundedRectangle(cornerRadius: theme.bubbleRadius, style: .continuous))
            default:
                preview
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : BubbleMetrics.cardWidth, alignment: .leading)
                    .background(theme.teamBubble)
                    .clipShape(RoundedRectangle(cornerRadius: theme.bubbleRadius, style: .continuous))
                    .accessibilityElement(children: .contain)
            }
        }

        @ViewBuilder
        private var preview: some View {
            let t = L10n(locale)
            let conversation = pingFront.conversation
            switch part.card {
            case .offer(let card) where conversation.supersededOfferCardIds.contains(card.id):
                Label(t("Replaced by a newer offer"), systemImage: "arrow.uturn.down")
                    .font(.footnote)
                    .foregroundStyle(theme.mutedOnTeamBubble)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            case .offer(let card):
                let productId =
                    card.offer?.productId ?? pingFront.offerSlots.first(where: { $0.id == card.offerId })?.products.first?.id
                let owned = pingFront.owns(
                    anyOf: [card.offerId] + (card.offer?.productId.map { [$0] } ?? [])
                        + (pingFront.offerSlots.first { $0.id == card.offerId }?.products.map(\.id) ?? []))
                let waiting = conversation.awaitingApproval.contains(card.id)
                // The app reports the offer as no longer available (`OfferSlot.isAvailable`): a card already in the
                // thread says so, muted, with no button to a paywall that is gone.
                let ended = pingFront.offerSlots.first { $0.id == card.offerId }?.isAvailable == false
                // Without onOffer or a store module the card says so instead of offering a dead button.
                let state: String? =
                    owned
                    ? t("Current plan")
                    : waiting
                        ? t("Waiting for approval")
                        : ended
                            ? t("This offer is no longer available.")
                            : (pingFront.canHandleOffers ? nil : t("Not available in this app"))
                // Another plan in the group the person already subscribes to: the store switches plans.
                let button = storePrice?.switchPeriod.map { switchLabel($0, t) } ?? card.button
                // StoreKit's own product view (real price, offer price, the system buy button) when the StoreKit
                // module is installed and the app has no paywall of its own.
                let native: AnyView? =
                    state == nil
                    ? productId.flatMap { id in
                        pingFront.nativeStore?.productView(productId: id, offer: card.offer) { outcome in
                            pingFront.recordCardOpened(part.card, messageId: message.id)
                            if outcome == .pending { pingFront.markAwaitingApproval(cardId: card.id) }
                        }
                    } : nil
                // With the native row, its buy button is the action; ours only opens the full subscription store.
                let mainButton = native == nil ? button : (pingFront.nativeStore?.offersSubscriptionStore == true ? t("See all plans") : "")
                layout(
                    // StoreKit's row names the product itself, so the card's title steps aside for it.
                    header: AppIconHeader(look: pingFront.look), title: native == nil ? card.title : "",
                    // An ended offer has no price to show.
                    subtitle: native == nil && storePrice?.discounted == nil && !ended
                        ? (storePrice?.regular ?? priceLine(card.offerId, t)) : nil,
                    detail: card.body, button: mainButton, state: state,
                    stateSymbol: owned ? "checkmark.circle.fill" : waiting ? "clock" : ended ? "clock.badge.xmark" : "info.circle",
                    struck: native == nil && !ended ? storePrice?.discounted.map { ($0, storePrice?.regular ?? "") } : nil,
                    native: native, muted: ended
                ) {
                    if let store = pingFront.nativeStore, store.offersSubscriptionStore, let productId {
                        pingFront.recordCardOpened(part.card, messageId: message.id)
                        store.presentSubscriptionStore(productId: productId, look: pingFront.look) { outcome in
                            if outcome == .pending { pingFront.markAwaitingApproval(cardId: card.id) }
                        }
                    } else {
                        conversation.open(part.card, in: message)
                    }
                }
                .task(id: card.id) {
                    guard let pricing = pingFront.offerPricing, let productId else { return }
                    storePrice = await pricing.price(productId: productId, offer: card.offer)
                }
            case .review(let card):
                layout(
                    header: AppIconHeader(look: pingFront.look), title: t("Enjoying %@?", pingFront.look.appName), subtitle: nil,
                    detail: t("Your review helps other people find %@.", pingFront.look.appName), button: card.button,
                    outbound: card.mode == .storePage ? t("Opens the App Store") : nil
                ) {
                    conversation.open(part.card, in: message)
                }
            case .link(let card):
                // A screen of this app (a saved link this build registered) stays in the app: no host, no "Opens in
                // Safari". As on Android.
                let inApp = card.screen.map { pingFront.screenRegistry.contains($0.id) } ?? false
                let host = inApp ? nil : URL(string: card.url)?.host()
                layout(
                    header: EmptyView(), title: card.title, subtitle: nil, detail: host, detailSymbol: "link", button: card.button,
                    outbound: inApp ? nil : t("Opens in Safari")
                ) {
                    conversation.open(part.card, in: message)
                }
            case .report(let card):
                layout(
                    header: EmptyView(), title: card.title, subtitle: nil,
                    detail: t("Includes a screenshot and recent logs."), detailSymbol: "ladybug", button: card.button
                ) {
                    conversation.open(part.card, in: message)
                }
            case .storeAction(let card):
                // Apple's own sheet opens over the chat, so the button stays in-app (no outbound arrow). Without
                // the StoreKit module it opens Apple's web page instead and says so.
                let text = StoreActionText(card.action, t)
                let inApp = pingFront.canHandleStoreActions
                let unavailable = !inApp && card.fallbackURL == nil
                layout(
                    header: EmptyView(), title: card.title ?? text.title, subtitle: nil,
                    detail: card.body ?? text.detail,
                    detailSymbol: card.body == nil ? text.detailSymbol : nil, button: card.button ?? text.button,
                    buttonSymbol: text.buttonSymbol,
                    state: unavailable ? t("Not available in this app") : nil, stateSymbol: "info.circle",
                    outbound: inApp ? nil : t("Opens in Safari")
                ) {
                    conversation.open(part.card, in: message)
                }
            case .choices, .rating, .unknown:
                EmptyView()
            }
        }

        private func layout(
            header: some View, title: String, subtitle: String?, detail: String?, detailSymbol: String? = nil, button: String,
            buttonSymbol: String? = nil, state: String? = nil, stateSymbol: String = "checkmark.circle.fill", outbound: String? = nil,
            struck: (now: String, was: String)? = nil, native: AnyView? = nil, muted: Bool = false,
            action: @escaping () -> Void
        ) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 2) {
                    if !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(theme.displayDesign)
                            .foregroundStyle(muted ? theme.mutedOnTeamBubble : theme.onTeamBubble)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let subtitle {
                        Text(subtitle).font(.footnote.weight(.semibold)).foregroundStyle(theme.accentText)
                    }
                    if let struck {
                        // The offer price, with the regular price struck through.
                        HStack(spacing: 6) {
                            Text(struck.now).font(.footnote.weight(.semibold)).foregroundStyle(theme.accentText)
                            Text(struck.was).font(.footnote).strikethrough().foregroundStyle(theme.mutedOnTeamBubble)
                                .accessibilityLabel(L10n(locale)("was %@", struck.was))
                        }
                    }
                    if let detail {
                        Group {
                            if let detailSymbol { Label(detail, systemImage: detailSymbol) } else { Text(detail) }
                        }
                        .font(.footnote).foregroundStyle(theme.mutedOnTeamBubble).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                if let native {
                    // StoreKit's product row, tinted with the chat's accent.
                    native
                        .tint(theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                if state != nil || !button.isEmpty {
                    Group {
                        if let state {
                            // A state, not a broken button: neutral fill, secondary text and a symbol, like iOS.
                            StateRow(text: state, symbol: stateSymbol)
                        } else if let outbound {
                            // Leaves the app: say where, with the outbound arrow.
                            Button(action: action) {
                                HStack(spacing: 6) {
                                    Text(button)
                                    Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityHint(outbound)
                        } else if let buttonSymbol {
                            Button(action: action) {
                                Label(button, systemImage: buttonSymbol)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        } else {
                            Button(button, action: action)
                                .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    .padding(12)
                } else {
                    Spacer().frame(height: 12)
                }
            }
        }

        /// "Switch to yearly" for another plan in the person's subscription group.
        private func switchLabel(_ period: String, _ t: L10n) -> String {
            switch period {
            case "P1Y": t("Switch to yearly")
            case "P1M": t("Switch to monthly")
            case "P1W": t("Switch to weekly")
            default: t("Switch plans")
            }
        }

        /// "€29.99 a year, first month free" from the reported offer slot, when the app reported one.
        private func priceLine(_ offerId: String, _ t: L10n) -> String? {
            guard let product = pingFront.offerSlots.first(where: { $0.id == offerId })?.products.first else { return nil }
            let price: String =
                switch product.period {
                case "P1Y": t("%@ a year", product.price)
                case "P1M": t("%@ a month", product.price)
                case "P1W": t("%@ a week", product.price)
                default: product.price
                }
            switch product.trial {
            case "P1M"?: return t("%@, first month free", price)
            case "P1W"?: return t("%@, first week free", price)
            default: return price
            }
        }
    }

    /// The SDK's own words and symbols for a store action card: the title is the short action or problem, the detail
    /// the sentence that explains it, and the button what happens (the same table on every SDK).
    struct StoreActionText {
        let title: String
        let detail: String
        let detailSymbol: String
        let button: String
        let buttonSymbol: String

        init(_ action: StoreActionCard.Action, _ t: L10n) {
            switch action {
            case .manageSubscriptions, .unknown:
                title = t("Your subscription")
                detail = t("Change your plan, payment method or renewal.")
                detailSymbol = "creditcard"
                button = t("Manage subscription")
                buttonSymbol = "gearshape"
            case .billingIssue:
                title = t("Payment didn't go through")
                detail = t("Update your payment method to keep your subscription.")
                detailSymbol = "exclamationmark.circle"
                button = t("Update payment method")
                buttonSymbol = "creditcard"
            case .requestRefund:
                title = t("Request a refund")
                detail = t("Apple reviews the request and emails you.")
                detailSymbol = "envelope"
                button = t("Request a refund")
                buttonSymbol = "arrow.uturn.backward"
            case .redeemCode:
                title = t("Redeem a code")
                detail = t("Enter an offer code from the App Store.")
                detailSymbol = "giftcard"
                button = t("Redeem code")
                buttonSymbol = "giftcard"
            case .restorePurchases:
                title = t("Restore purchases")
                detail = t("Brings back purchases made with your Apple Account.")
                detailSymbol = "person.crop.circle"
                button = t("Restore purchases")
                buttonSymbol = "arrow.clockwise"
            }
        }
    }

    /// A rich-preview header with the app icon.
    struct AppIconHeader: View {
        let look: ResolvedLook
        @Environment(\.chatTheme) private var theme

        var body: some View {
            AppIconView(look: look, size: 60)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .frame(maxWidth: .infinity, minHeight: 104)
                .background(theme.accentTint)
        }
    }

    /// Wrap-flow pills.
    ///
    /// The chosen one fills with the accent and gets a check; the others step back.
    struct ChoicesView: View {
        let card: ChoicesCard
        let result: CardResult?
        let message: Message
        let conversation: Conversation
        @State private var chosen: String?
        @Environment(\.locale) private var locale

        var body: some View {
            let t = L10n(locale)
            let selected = result?.choiceId ?? chosen
            FlowLayout(spacing: 8, balanced: true) {
                ForEach(card.options) { option in
                    let isSelected = option.id == selected
                    Button {
                        chosen = option.id
                        conversation.choose(option, on: card, in: message)
                    } label: {
                        HStack(spacing: 6) {
                            if isSelected { Image(systemName: "checkmark").font(.footnote.weight(.bold)) }
                            Text(option.label).multilineTextAlignment(.leading)
                        }
                    }
                    // Unchosen options stay fully legible (no fading); they are only disabled.
                    .buttonStyle(PillButtonStyle(selected: isSelected))
                    .disabled(selected != nil)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityValue(selected != nil && !isSelected ? Text(t("Not chosen")) : Text(""))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .sensoryFeedback(.selection, trigger: chosen)
        }
    }

    /// Five large stars (44 pt targets); a short thanks once rated.
    struct RatingView: View {
        let card: RatingCard
        let result: CardResult?
        let message: Message
        let conversation: Conversation
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @State private var rated: Int?

        var body: some View {
            let t = L10n(locale)
            let value = result?.rating ?? rated
            VStack(alignment: .leading, spacing: 6) {
                Text(card.question)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(theme.displayDesign)
                    .foregroundStyle(theme.onTeamBubble)
                HStack(spacing: 2) {
                    ForEach(1...card.stars, id: \.self) { star in
                        Button {
                            rated = star
                            conversation.rate(star, on: card, in: message)
                        } label: {
                            Image(systemName: star <= (value ?? 0) ? "star.fill" : "star")
                                .font(.title)
                                .foregroundStyle(star <= (value ?? 0) ? theme.rating : theme.muted)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .disabled(value != nil)
                        .accessibilityLabel(t("%1$lld of %2$lld stars", star, card.stars))
                        .accessibilityAddTraits(star == value ? .isSelected : [])
                    }
                }
                .padding(.leading, -8)
                if value != nil {
                    Text(t("Thanks for your rating."))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.mutedOnTeamBubble)
                }
            }
            .sensoryFeedback(.selection, trigger: rated)
        }
    }
#endif

#if canImport(UIKit)
    /// A neutral row that names a state on a card, such as "Current plan": `tertiarySystemFill`, secondary
    /// label text and a check.
    ///
    /// Not a button. Meets 4.5:1 (7:1 with Increase Contrast) on every look.
    struct StateRow: View {
        let text: String
        var symbol = "checkmark.circle.fill"
        @Environment(\.chatTheme) private var theme
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let mode = theme.mode
            Label(text, systemImage: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(rgb: theme.look.stateText(mode, increasedContrast: contrast == .increased)))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    Color(rgb: theme.look.stateFill(mode, increasedContrast: contrast == .increased)),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
        }
    }
#endif
