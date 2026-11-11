import Foundation
import StoreKit
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontStoreKit

/// Links, the photo viewer, superseded offers, typing and StoreKit lapses.
@Suite("Links, photos, offers, typing and lapses")
struct ParityTests {
    @Test("Links are detected in text; a link-only message gets a preview")
    func links() {
        let found = LinkDetection.links(in: "Docs at https://pingfront.sh/docs and http://x.test, not ftp://a.b")
        #expect(found.map(\.url.absoluteString) == ["https://pingfront.sh/docs", "http://x.test"])
        #expect(LinkDetection.soleLink(in: "  https://pingfront.sh/pricing \n")?.absoluteString == "https://pingfront.sh/pricing")
        #expect(LinkDetection.soleLink(in: "see https://pingfront.sh") == nil)
        #expect(LinkDetection.soleLink(in: "no links") == nil)
    }

    @Test("The host's onLink handles links first; otherwise the presenter opens them")
    @MainActor func onLink() async {
        final class Presenter: ChatPresenting {
            var opened: [URL] = []
            func presentChat(topic: ChatTopic?) {}
            func dismissChat() {}
            func open(_ url: URL) { opened.append(url) }
            func presentSimpleReport() {}
        }
        let facade = PingFront()
        let presenter = Presenter()
        facade.registry.chatPresenter = presenter
        let deepLink = URL(string: "clockwise://alarms")!
        let web = URL(string: "https://pingfront.sh")!
        facade.onLink = { $0.scheme == "clockwise" }
        facade.openLink(deepLink)
        await facade.chatLinkTask?.value
        facade.openLink(web)
        await facade.chatLinkTask?.value
        #expect(presenter.opened == [web])
        // Without a handler the presenter opens it at once.
        facade.onLink = nil
        facade.openLink(deepLink)
        #expect(facade.chatLinkTask == nil && presenter.opened == [web, deepLink])
    }

    @Test("Photo viewer: zoom is clamped; swipe down closes only when not zoomed")
    func photoViewer() {
        #expect(PhotoZoom.clamped(0.4) == 1)
        #expect(PhotoZoom.clamped(9) == 5)
        #expect(PhotoZoom.dismisses(scale: 1, translation: 150, predicted: 160))
        #expect(PhotoZoom.dismisses(scale: 1, translation: 40, predicted: 500))
        #expect(!PhotoZoom.dismisses(scale: 2, translation: 300, predicted: 900))
        #expect(!PhotoZoom.dismisses(scale: 1, translation: 40, predicted: 80))
    }

    @Test("A newer offer supersedes older offer cards; owning the product shows Current plan")
    @MainActor func supersededOffers() {
        func offer(_ id: String, seq: Int) -> PingFrontCore.Message {
            makeMessage(
                "m\(seq)", seq: seq,
                parts: [
                    .card(CardPart(card: .offer(OfferCard(id: id, offerId: "pro_yearly", title: "Pro", button: "See offer")), result: nil))
                ])
        }
        let conversation = Conversation()
        conversation.merge([offer("o1", seq: 1), offer("o2", seq: 2), offer("o3", seq: 3)])
        #expect(conversation.supersededOfferCardIds == ["o1", "o2"])

        let facade = PingFront()
        #expect(!facade.owns(anyOf: ["pro_yearly"]))
        facade.currentEntitlement = Entitlement(state: .active, productId: "pro_yearly", source: .storekit)
        #expect(facade.owns(anyOf: ["pro_yearly"]))
        facade.currentEntitlement = Entitlement(state: .expired, productId: "pro_yearly", source: .storekit)
        #expect(!facade.owns(anyOf: ["pro_yearly"]))
    }

    @Test("StoreKit lapses map to store events")
    func lapseEvents() {
        #expect(StoreKitLapses.event(state: .subscribed, willAutoRenew: true, isTrial: false) == nil)
        #expect(StoreKitLapses.event(state: .subscribed, willAutoRenew: false, isTrial: true) == "trial_cancelled")
        #expect(StoreKitLapses.event(state: .subscribed, willAutoRenew: false, isTrial: false) == "subscription_cancelled")
        #expect(StoreKitLapses.event(state: .expired, willAutoRenew: false, isTrial: true) == "trial_expired")
        #expect(StoreKitLapses.event(state: .expired, willAutoRenew: false, isTrial: false) == "subscription_expired")
        #expect(StoreKitLapses.event(state: .inBillingRetryPeriod, willAutoRenew: true, isTrial: false) == "billing_issue")
        #expect(StoreKitLapses.event(state: .inGracePeriod, willAutoRenew: true, isTrial: false) == "billing_issue")
        #expect(StoreKitLapses.event(state: .revoked, willAutoRenew: false, isTrial: false) == "refunded")
    }

    @Test("A subscription's renewal state maps to its entitlement; a state StoreKit doesn't name grants nothing")
    func subscriptionStates() {
        typealias State = Product.SubscriptionInfo.RenewalState
        let map = { (renewal: State?, revoked: Bool, intro: Bool) in
            StoreKitEntitlements.subscriptionState(renewal: renewal, revoked: revoked, introductory: intro)
        }
        #expect(map(.subscribed, false, false) == .active)
        #expect(map(.subscribed, false, true) == .trial)
        #expect(map(.inGracePeriod, false, false) == .grace)
        #expect(map(.inBillingRetryPeriod, false, false) == .billingRetry)
        #expect(map(.expired, false, false) == .expired)
        #expect(map(.revoked, false, false) == .cancelled)
        #expect(map(.subscribed, true, false) == .cancelled)
        #expect(map(nil, false, false) == .active)
        // StoreKit testing reports a declined Ask to Buy request in currentEntitlements with renewal state 0 and
        // auto-renew off. Read as active it became "cancelled, owned until next year": Current plan on the card.
        #expect(map(State(rawValue: 0), false, false) == nil)
        #expect(map(State(rawValue: 99), false, true) == nil)
    }

    @Test("Foreground lapse sweeps run at most once every 60 seconds")
    func lapseSweepInterval() async {
        let lapses = StoreKitLapses()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(await lapses.admitSweep(now: now))
        #expect(await !lapses.admitSweep(now: now.addingTimeInterval(1)))
        #expect(await !lapses.admitSweep(now: now.addingTimeInterval(59.9)))
        #expect(await lapses.admitSweep(now: now.addingTimeInterval(60)))
        #expect(await !lapses.admitSweep(now: now.addingTimeInterval(100)))
    }

    @Test("StoreKit lapses are deduplicated per period and rate-limited")
    func lapseLimits() async {
        let lapses = StoreKitLapses()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(await lapses.admit("subscription_cancelled/1/100", now: now))
        #expect(await !lapses.admit("subscription_cancelled/1/100", now: now.addingTimeInterval(3600)))
        #expect(await lapses.admit("subscription_cancelled/1/100", now: now.addingTimeInterval(90_000)))
        for index in 0..<20 { _ = await lapses.admit("billing_issue/\(index)/1", now: now.addingTimeInterval(90_000)) }
        #expect(await !lapses.admit("billing_issue/99/1", now: now.addingTimeInterval(90_001)), "more than 10 an hour")
        let first = StoreEventReport(name: "subscription_cancelled", productId: "p", transactionId: "9", occurredAt: now, dedupeKey: "k")
        let again = StoreEventReport(name: "subscription_cancelled", productId: "p", transactionId: "10", occurredAt: now, dedupeKey: "k")
        #expect(first.clientId == again.clientId, "the server must see one report per lapse")
    }
}
