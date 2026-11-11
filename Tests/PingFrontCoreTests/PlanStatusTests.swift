import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontStoreKit
@testable import PingFrontTestSupport

@Suite("Plan status and native store")
struct PlanStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var later: Date { now.addingTimeInterval(86_400 * 12) }
    var earlier: Date { now.addingTimeInterval(-86_400 * 3) }

    @Test("Each state reads as one line; nothing for none, unknown or a missing date")
    func lines() {
        #expect(PlanStatus(Entitlement(state: .active, renewsAt: later), now: now) == .renews(later))
        #expect(PlanStatus(Entitlement(state: .trial, renewsAt: later), now: now) == .renews(later))
        #expect(PlanStatus(Entitlement(state: .active, expiresAt: later), now: now) == .ends(later))
        #expect(PlanStatus(Entitlement(state: .cancelled, expiresAt: later), now: now) == .ends(later))
        #expect(PlanStatus(Entitlement(state: .cancelled, expiresAt: earlier), now: now) == .ended(earlier))
        #expect(PlanStatus(Entitlement(state: .expired, expiresAt: earlier), now: now) == .ended(earlier))
        #expect(PlanStatus(Entitlement(state: .grace, gracePeriodEndsAt: later), now: now) == .paymentIssue(until: later))
        #expect(PlanStatus(Entitlement(state: .billingRetry), now: now) == .paymentIssue(until: nil))
        #expect(PlanStatus(Entitlement(state: .billingRetry, gracePeriodEndsAt: earlier), now: now) == .paymentIssue(until: nil))
        #expect(PlanStatus(Entitlement(state: .lifetime), now: now) == .lifetime)
        #expect(PlanStatus(Entitlement(state: .none), now: now) == nil)
        #expect(PlanStatus(Entitlement(state: .unknown), now: now) == nil)
        #expect(PlanStatus(Entitlement(state: .active), now: now) == nil)
        #expect(PlanStatus(Entitlement(state: .grace), now: now)?.needsPaymentFix == true)
    }

    @Test("PersonSummary.entitlement decodes with its dates; an unknown state is tolerated")
    func wire() throws {
        let json =
            #"{"id":"per_2","level":"verified","name":"Ada","entitlement":{"state":"grace","productId":"pro.monthly","expiresAt":"2026-10-30T09:00:00.000Z","gracePeriodEndsAt":"2026-11-03T09:00:00.000Z","source":"revenuecat"}}"#
        let person = try WireJSON.decode(PersonSummary.self, from: Data(json.utf8))
        #expect(person.entitlement?.state == .grace)
        #expect(person.entitlement?.gracePeriodEndsAt != nil && person.entitlement?.expiresAt != nil)
        #expect(person.entitlement?.source == .revenuecat)
        let odd = try WireJSON.decode(Entitlement.self, from: Data(#"{"state":"paused"}"#.utf8))
        #expect(odd.state == .unknown)
    }

    @Test("The server's plan wins; the device's StoreKit plan is the fallback; other local sources are not shown")
    @MainActor func source() {
        let facade = PingFront()
        Retain.keep(facade)
        facade.currentEntitlement = Entitlement(state: .active, productId: "a", renewsAt: later, source: .storekit)
        #expect(facade.planEntitlement?.productId == "a")
        facade.person = PersonSummary(id: "p", level: .guest, entitlement: Entitlement(state: .grace, productId: "b", source: .revenuecat))
        #expect(facade.planEntitlement?.productId == "b")
        facade.person = PersonSummary(id: "p", level: .guest)
        facade.currentEntitlement = Entitlement(state: .active, productId: "c", source: .app)
        #expect(facade.planEntitlement == nil)
    }

    @Test("A cancelled plan still counts as owned until it ends")
    @MainActor func ownsCancelled() {
        let facade = PingFront()
        Retain.keep(facade)
        facade.currentEntitlement = Entitlement(state: .cancelled, productId: "x", expiresAt: .now.addingTimeInterval(3_600))
        #expect(facade.owns(anyOf: ["x"]))
        facade.currentEntitlement = Entitlement(state: .cancelled, productId: "x", expiresAt: .now.addingTimeInterval(-3_600))
        #expect(!facade.owns(anyOf: ["x"]))
    }

    @Test("A pending offer purchase shows Waiting for approval; logout clears it")
    @MainActor func awaitingApproval() {
        let facade = PingFront()
        Retain.keep(facade)
        facade.markAwaitingApproval(cardId: "card_1")
        #expect(facade.conversation.awaitingApproval == ["card_1"])
        facade.conversation.clear()
        #expect(facade.conversation.awaitingApproval.isEmpty)
    }

    @Test("App transaction traits are the original version and an ISO date")
    func appTransactionTraits() {
        let traits = AppTransactionTraits.traits(originalVersion: "1.4", originalPurchaseDate: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(traits == ["original_app_version": "1.4", "original_purchase_date": "2023-11-14T22:13:20Z"])
    }
}

@Suite("Composer")
struct ComposerTests {
    @Test("A topic's starter fills an empty field and never replaces typed text")
    func insertion() {
        #expect(Conversation.inserting("About billing: ", into: "") == "About billing: ")
        #expect(Conversation.inserting("About billing:", into: "  \n") == "About billing:")
        #expect(Conversation.inserting("About billing:", into: "I was charged twice") == "About billing:\nI was charged twice")
        #expect(
            Conversation.inserting("About billing:", into: "About billing:\nI was charged twice") == "About billing:\nI was charged twice")
    }

    @Test("The limit counts code points: the counter shows near it and sending stops over it")
    func limit() {
        #expect(TextLimit.remaining(String(repeating: "a", count: 10)) == Limits.textChars - 10)
        let emoji = String(repeating: "👍🏽", count: 3)
        #expect(TextLimit.remaining(emoji) == Limits.textChars - emoji.unicodeScalars.count)
        #expect(TextLimit.remaining(String(repeating: "a", count: Limits.textChars + 1)) == -1)
    }
}
