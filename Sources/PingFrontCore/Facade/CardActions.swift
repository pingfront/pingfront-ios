package import Foundation
internal import os

/// What happens when the person acts on a card: the local result shows at once, the module or host
/// handles offers, reviews, links and reports, and the action is reported to the server.
@MainActor
package final class CardActions {
    private weak var facade: PingFront?
    private let client: AuthorizedClient
    private let time: TimeSource
    /// Every report is queued here and sent by the engine's loop, retried safely.
    private let reports: CardActionReports
    /// Wakes that loop.
    private let wake: WakeSignal
    private let tasks = TaskBag()
    /// Review cards whose native prompt was already requested.
    private var promptedReviews: Set<String> = []

    package init(facade: PingFront, client: AuthorizedClient, time: TimeSource, reports: CardActionReports, wake: WakeSignal) {
        self.facade = facade
        self.client = client
        self.time = time
        self.reports = reports
        self.wake = wake
    }

    /// How long a tap waits for the app's `onScreen` or `onLink` answer before it counts as `false` (Android's bound too).
    package static let handlerAnswerLimit: Duration = .seconds(10)

    package func act(card: Card, messageId: String, answer: CardAnswer?, offers: [OfferSlot]) {
        guard let facade else { return }
        let action: CardActionRequest.Action
        switch card {
        case .choices, .rating:
            action = card.isChoices ? .chosen : .rated
            setLocalResult(messageId: messageId, cardId: card.id, result: CardResult(at: .now, answer: answer))
        case .offer(let offer):
            action = .opened
            openOffer(offer, messageId: messageId, offers: offers, facade: facade)
        case .review(let review):
            action = .opened
            // First tap: Apple's native prompt (Apple may show nothing; it decides). A second tap goes to the
            // App Store's write-a-review page, in the App Store app.
            let firstTap = promptedReviews.insert(review.id).inserted
            let requester = review.mode == .nativePrompt && firstTap ? facade.reviewRequester : nil
            let fallback = review.storeURL.map(ReviewLink.writeReview) ?? facade.appStoreID.flatMap(ReviewLink.writeReview(appStoreID:))
            tasks.run { [weak facade] in
                if let requester, await requester.requestReview() { return }
                guard !Task.isCancelled else { return }
                if let fallback { facade?.openLink(fallback) }
            }
        case .link(let link):
            // One report per tap, once the outcome is known: opened, or failed with why (https://pingfront.sh/docs/offers#saved-links).
            facade.emit(.cardOpened(OpenedCard(kind: card.kind, cardId: card.id, messageId: messageId)))
            tasks.run { [weak self, weak facade] in
                guard let self, let facade else { return }
                let failure = await Self.open(link, facade: facade, time: self.time)
                // Logged out or erased while onLink or onScreen was deciding: the tap belongs to the previous person.
                guard !Task.isCancelled else { return }
                self.send(
                    cardId: card.id,
                    CardActionRequest(messageId: messageId, action: failure == nil ? .opened : .failed, failure: failure))
            }
            return
        case .report:
            action = .opened
            facade.openReport()
        case .storeAction(let card):
            action = .opened
            perform(card, messageId: messageId)
        case .unknown:
            return
        }
        facade.emit(.cardOpened(OpenedCard(kind: card.kind, cardId: card.id, messageId: messageId)))
        send(cardId: card.id, CardActionRequest(messageId: messageId, action: action, answer: answer))
    }

    /// Opens a link card's target and returns why it didn't open, or `nil` when it did.
    ///
    /// A screen this build registered goes to `onScreen` (`not_handled` when it returns false or there is none); an
    /// unregistered one falls back to the card's URL, or fails with `unknown_screen` without one. A URL the link card
    /// URL rule refuses is `cannot_open` at once; any other goes to `onLink` (awaited, as `onScreen` is), then Safari
    /// (web links) or the system (the app's own scheme), and is `cannot_open` when nothing opens it.
    package static func open(_ link: LinkCard, facade: PingFront, time: TimeSource) async -> LinkFailure? {
        if let screen = link.screen {
            if facade.screenRegistry.contains(screen.id) {
                guard let onScreen = facade.onScreen else { return .notHandled }
                return await answer(onScreen, screen, within: handlerAnswerLimit, time: time) ? nil : .notHandled
            }
            if link.url.isEmpty { return .unknownScreen }
        }
        // The link card URL rule comes first: a refused URL never reaches onLink or the system.
        let cleaned = LinkURLRule.clean(link.url)
        guard LinkURLRule.allows(cleaned), let url = URL(string: cleaned) else { return .cannotOpen }
        return await facade.openLinkReportingOutcome(url, time: time) ? nil : .cannotOpen
    }

    /// The app's answer to `handler` (`onScreen` or `onLink`) for `value`, or `false` when it doesn't come within
    /// `limit` on the injected clock.
    ///
    /// The first of the two to finish wins: the handler's answer, or the deadline. The deadline's task is cancelled as
    /// soon as the answer comes; a handler still running at the deadline is cancelled too, and its late answer is
    /// ignored (it may not stop at once: a bridge waiting for JavaScript or Dart finishes in its own time). A cancelled
    /// caller (logout) gets `false` at once and cancels both.
    package static func answer<Value: Sendable>(
        _ handler: @escaping @MainActor (Value) async -> Bool, _ value: Value, within limit: Duration, time: TimeSource
    ) async -> Bool {
        let (answers, first) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let handler = Task { @MainActor in first.yield(await handler(value)) }
        let deadline = Task { if await time.pause(limit) { first.yield(false) } }
        var iterator = answers.makeAsyncIterator()
        let result = await iterator.next() ?? false
        first.finish()
        deadline.cancel()
        handler.cancel()
        return result
    }

    /// Reports an opened card whose action ran in a native view (the StoreKit product view).
    package func report(card: Card, messageId: String) {
        facade?.emit(.cardOpened(OpenedCard(kind: card.kind, cardId: card.id, messageId: messageId)))
        send(cardId: card.id, CardActionRequest(messageId: messageId, action: .opened, answer: nil))
    }

    /// Opens Apple's sheet for a store action; a change after it closes becomes a local receipt.
    ///
    /// Without the
    /// StoreKit module, Apple's web page for the action.
    package func perform(_ card: StoreActionCard, messageId: String = "") {
        guard let facade else { return }
        if let handler = facade.storeActionHandler {
            tasks.run { [weak self] in
                let outcome = await handler.perform(StoreActionRequest(card: card, messageId: messageId))
                // Logged out or erased while Apple's sheet was open: the change belongs to the previous person.
                guard case .completed(let change?) = outcome, !Task.isCancelled, let self else { return }
                let localId = self.postLocalReceipt(change)
                await self.reportResult(change, card: card, messageId: messageId, localId: localId)
            }
        } else if let url = card.fallbackURL {
            facade.openLink(url)
        }
    }

    /// Queues the report with its own `clientId` and wakes the sender (`CardActionReports`).
    private func send(cardId: String, _ request: CardActionRequest) {
        let reports = reports
        let wake = wake
        tasks.run {
            await reports.enqueue(cardId: cardId, request)
            wake.notify()
        }
    }

    package func cancelAll() { tasks.cancelAll() }

    private func openOffer(_ offer: OfferCard, messageId: String, offers: [OfferSlot], facade: PingFront) {
        var request = OfferRequest(
            offerId: offer.offerId, slot: offers.first { $0.id == offer.offerId }, cardId: offer.id, messageId: messageId)
        request.storeOffer = offer.offer
        facade.emit(.offerRequested(request))
        if let onOffer = facade.onOffer {
            onOffer(request)
        } else if let handler = facade.offerHandler {
            tasks.run { [weak facade] in
                let outcome = await handler.handle(request)
                if outcome == .pending { facade?.markAwaitingApproval(cardId: request.cardId) }
                facade?.emit(.offerCompleted(request, outcome))
            }
        } else {
            Log.config(.error)?.error(
                "An offer card was tapped but no offer handler is set. Set PingFront.shared.onOffer or use a store module.")
        }
    }

    /// Reports a store action's result (`POST /store-actions`) so the team sees it in the thread.
    ///
    /// The server's receipt replaces the local line. Without a conversation (or when a store receipt already says it) the server
    /// writes none and the local line stays.
    private func reportResult(_ change: StoreChange, card: StoreActionCard, messageId: String, localId: String?) async {
        let request = StoreActionResultRequest(
            clientId: UUID().uuidString.lowercased(),
            action: card.action == .unknown ? StoreActionCard.Action.manageSubscriptions.rawValue : card.action.rawValue,
            result: change.wireResult, cardId: card.id.isEmpty ? nil : card.id, messageId: messageId.isEmpty ? nil : messageId,
            productName: change.productName)
        do throws(PingFrontError) {
            let response = try await client.send(Endpoints.reportStoreAction(request))
            guard let message = response.message, let conversation = facade?.conversation else { return }
            if let localId { conversation.messages.removeAll { $0.id == localId } }
            conversation.merge([message])
        } catch {
            Log.network(.info)?.info("Store action report failed: \(error.logDescription, privacy: .public)")
        }
    }

    /// Adds a receipt line after the newest message, on this device only, and returns its id.
    @discardableResult
    package func postLocalReceipt(_ change: StoreChange) -> String? {
        guard let facade else { return nil }
        let conversation = facade.conversation
        let receipt = Message(
            id: "local_receipt_\(UUID().uuidString)", seq: conversation.messages.last?.seq ?? 0, author: Author(kind: .system),
            parts: [
                .receipt(
                    ReceiptPart(action: change == .purchasesRestored ? .purchasesRestored : .custom, text: facade.storeChangeText(change)))
            ],
            createdAt: .now)
        conversation.merge([receipt])
        return receipt.id
    }

    private func setLocalResult(messageId: String, cardId: String, result: CardResult) {
        guard let conversation = facade?.conversation,
            let index = conversation.messages.firstIndex(where: { $0.id == messageId })
        else { return }
        var message = conversation.messages[index]
        message.parts = message.parts.map { part in
            guard case .card(var cardPart) = part, cardPart.card.id == cardId else { return part }
            cardPart.result = result
            return .card(cardPart)
        }
        conversation.messages[index] = message
    }
}

extension Card {
    fileprivate var isChoices: Bool {
        if case .choices = self { return true }
        return false
    }
}

extension StoreChange {
    /// `StoreActionResult` on the wire.
    package var wireResult: String {
        switch self {
        case .paymentUpdated: "payment_updated"
        case .subscribed: "subscribed"
        case .planChanged: "plan_changed"
        case .autoRenewOff: "auto_renew_off"
        case .autoRenewOn: "auto_renew_on"
        case .refundRequested: "refund_requested"
        case .codeRedeemed: "code_redeemed"
        case .purchasesRestored: "purchases_restored"
        }
    }

    /// The product's display name, for the server's "Subscribed to …" line.
    package var productName: String? {
        switch self {
        case .subscribed(let product), .planChanged(let product): product.isEmpty ? nil : product
        case .codeRedeemed(let product): product.flatMap { $0.isEmpty ? nil : $0 }
        default: nil
        }
    }

    /// The receipt line in English (the chat UI shows its own translations).
    package static func englishText(_ change: StoreChange) -> String {
        switch change {
        case .paymentUpdated: "Payment method updated"
        case .subscribed(let product): "Subscribed to \(product)"
        case .planChanged(let product): "Plan changed to \(product)"
        case .autoRenewOff: "Auto-renew turned off"
        case .autoRenewOn: "Auto-renew turned back on"
        case .refundRequested: "Refund requested"
        case .codeRedeemed(let product?): "Code redeemed: \(product)"
        case .codeRedeemed(nil): "Code redeemed"
        case .purchasesRestored: "Purchases restored"
        }
    }
}

/// App Store review links.
package enum ReviewLink {
    /// `apps.apple.com` and `itunes.apple.com` links become `itms-apps://…?action=write-review`, which opens the
    /// App Store app on its review page instead of a web view.
    ///
    /// Other links are kept.
    package static func writeReview(_ url: URL) -> URL {
        guard let host = url.host()?.lowercased(), host == "apps.apple.com" || host == "itunes.apple.com",
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "itms-apps"
        var items = (components.queryItems ?? []).filter { $0.name != "action" }
        items.append(URLQueryItem(name: "action", value: "write-review"))
        components.queryItems = items
        return components.url ?? url
    }

    /// The App Store's write-a-review page for an app id (`AppConfig.appStoreId`), in the App Store app.
    package static func writeReview(appStoreID: String) -> URL? {
        guard !appStoreID.isEmpty, appStoreID.allSatisfy(\.isASCII), appStoreID.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "itms-apps://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }
}
