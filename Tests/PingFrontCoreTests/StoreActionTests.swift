import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// Stands in for the StoreKit module: records requests and reports a fixed outcome.
@MainActor final class FakeStoreActions: StoreActionHandling {
    var requests: [StoreActionRequest] = []
    let outcome: StoreActionOutcome
    init(_ outcome: StoreActionOutcome) { self.outcome = outcome }
    func perform(_ request: StoreActionRequest) async -> StoreActionOutcome {
        requests.append(request)
        return outcome
    }
}

@Suite("Store action cards")
struct StoreActionTests {
    let key = "pk_test_abcdefghijklmnopqrstuvvd"

    @MainActor
    func configured(_ modules: [PingFrontModule] = [], server: StubServer = StubServer()) -> PingFront {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(TestClock()))
        for module in modules { configuration.use(module) }
        facade.start(appKey: key, configuration: configuration)
        // The engine holds its facade unowned; keep it for engine tasks that outlive the test.
        Retain.keep(facade)
        return facade
    }

    static let billingCard = StoreActionCard(
        id: "sa1", action: .billingIssue, productId: "plus_yearly", subscriptionGroupId: "21000001", transactionId: "2000000123")

    @MainActor
    func thread(_ card: StoreActionCard) -> Message {
        Message(
            id: "m1", seq: 3, author: Author(kind: .team, id: "m_ana", name: "Ana"),
            parts: [.text("Your payment didn't go through."), .card(CardPart(card: .storeAction(card)))], createdAt: .now)
    }

    @Test("store_action decodes every action, keeps the ids, and round-trips; unknown actions are tolerated")
    func wire() throws {
        let json =
            #"{"kind":"store_action","id":"sa1","action":"billing_issue","productId":"plus_yearly","subscriptionGroupId":"21000001","transactionId":"2000000123"}"#
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        #expect(card == .storeAction(Self.billingCard))
        let again = try JSONDecoder().decode(Card.self, from: try JSONEncoder().encode(card))
        #expect(again == card)
        for (raw, action) in [
            ("manage_subscriptions", StoreActionCard.Action.manageSubscriptions), ("billing_issue", .billingIssue),
            ("request_refund", .requestRefund), ("redeem_code", .redeemCode), ("restore_purchases", .restorePurchases),
            ("change_plan_somehow", .unknown),
        ] {
            let decoded = try JSONDecoder().decode(Card.self, from: Data(#"{"kind":"store_action","id":"x","action":"\#(raw)"}"#.utf8))
            #expect(decoded == .storeAction(StoreActionCard(id: "x", action: action)))
        }
    }

    @Test("title, body, button and the store hint decode; an unknown store is tolerated")
    func textFields() throws {
        let json =
            #"{"kind":"store_action","id":"s","action":"manage_subscriptions","title":"Your plan","body":"Switch or cancel any time.","button":"Open","store":"app_store"}"#
        guard case .storeAction(let card) = try JSONDecoder().decode(Card.self, from: Data(json.utf8)) else {
            Issue.record("Not a store action")
            return
        }
        #expect(card.title == "Your plan" && card.body == "Switch or cancel any time." && card.button == "Open" && card.store == .appStore)
        let other = try JSONDecoder().decode(
            Card.self, from: Data(#"{"kind":"store_action","id":"s","action":"redeem_code","store":"galaxy"}"#.utf8))
        guard case .storeAction(let tolerant) = other else {
            Issue.record("Not a store action")
            return
        }
        #expect(tolerant.store == .unknown)
    }

    @Test("Without the StoreKit module each action falls back to Apple's web page (restore has none)")
    func fallbacks() {
        #expect(
            StoreActionCard(id: "a", action: .manageSubscriptions).fallbackURL?.absoluteString
                == "https://apps.apple.com/account/subscriptions")
        #expect(
            StoreActionCard(id: "a", action: .billingIssue).fallbackURL?.absoluteString == "https://apps.apple.com/account/subscriptions")
        #expect(StoreActionCard(id: "a", action: .unknown).fallbackURL?.absoluteString == "https://apps.apple.com/account/subscriptions")
        #expect(StoreActionCard(id: "a", action: .requestRefund).fallbackURL?.host() == "reportaproblem.apple.com")
        #expect(StoreActionCard(id: "a", action: .redeemCode).fallbackURL?.absoluteString == "https://apps.apple.com/redeem")
        #expect(StoreActionCard(id: "a", action: .restorePurchases).fallbackURL == nil)
    }

    @Test("A tap goes to the module; a change after the sheet closes becomes a local receipt")
    @MainActor func moduleAndReceipt() async throws {
        let handler = FakeStoreActions(.completed(.paymentUpdated))
        let facade = configured([PingFrontModule(id: "store") { $0.setStoreActionHandler(handler) }])
        defer { facade.teardown() }
        var opened: [URL] = []
        facade.onLink = {
            opened.append($0)
            return true
        }
        let message = thread(Self.billingCard)
        facade.conversation.merge([message])
        #expect(facade.canHandleStoreActions)
        facade.conversation.open(.storeAction(Self.billingCard), in: message)
        try await waitUntil { facade.conversation.messages.count == 2 }
        #expect(handler.requests == [StoreActionRequest(card: Self.billingCard, messageId: "m1")])
        guard case .receipt(let receipt)? = facade.conversation.messages.last?.parts.first else {
            Issue.record("No receipt")
            return
        }
        #expect(receipt.text == "Payment method updated")
        #expect(facade.conversation.messages.last?.author.kind == .system)
        #expect(opened.isEmpty)
    }

    @Test("The result is reported to the server, whose receipt replaces the local line")
    @MainActor func reportsResult() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on(
            "POST store-actions",
            .ok(
                #"{"message":{"id":"msg_r","seq":4,"author":{"kind":"system"},"parts":[{"type":"receipt","action":"plan_changed","text":"Plan changed to Plus, yearly"}],"createdAt":"2026-10-30T18:00:00Z"}}"#
            ))
        let handler = FakeStoreActions(.completed(.planChanged(product: "Plus, yearly")))
        let facade = configured([PingFrontModule(id: "store") { $0.setStoreActionHandler(handler) }], server: server)
        defer { facade.teardown() }
        let message = thread(Self.billingCard)
        facade.conversation.merge([message])
        facade.conversation.open(.storeAction(Self.billingCard), in: message)
        try await waitUntil { facade.conversation.messages.last?.id == "msg_r" }
        #expect(facade.conversation.messages.map(\.id) == ["m1", "msg_r"])
        let sent = try #require(await server.requests("POST store-actions").first?.json)
        #expect(sent["action"] as? String == "billing_issue")
        #expect(sent["result"] as? String == "plan_changed")
        #expect(sent["productName"] as? String == "Plus, yearly")
        #expect(sent["cardId"] as? String == "sa1")
        #expect(sent["messageId"] as? String == "m1")
        #expect((sent["clientId"] as? String)?.count == 36)
    }

    @Test("Without a server receipt (no conversation yet) the local line stays")
    @MainActor func localLineStays() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST store-actions", .ok(#"{"message":null}"#))
        let handler = FakeStoreActions(.completed(.refundRequested))
        let facade = configured([PingFrontModule(id: "store") { $0.setStoreActionHandler(handler) }], server: server)
        defer { facade.teardown() }
        let message = thread(Self.billingCard)
        facade.conversation.merge([message])
        facade.conversation.open(.storeAction(Self.billingCard), in: message)
        #expect(await eventually { await !server.requests("POST store-actions").isEmpty })
        try await Task.sleep(for: .milliseconds(50))
        #expect(facade.conversation.messages.count == 2)
        #expect(facade.conversation.messages.last?.id.hasPrefix("local_receipt_") == true)
    }

    @Test("No change, or a cancelled sheet, adds nothing")
    @MainActor func noReceipt() async throws {
        for outcome in [StoreActionOutcome.completed(nil), .cancelled, .failed] {
            let handler = FakeStoreActions(outcome)
            let facade = configured([PingFrontModule(id: "store") { $0.setStoreActionHandler(handler) }])
            let message = thread(Self.billingCard)
            facade.conversation.merge([message])
            facade.conversation.open(.storeAction(Self.billingCard), in: message)
            try await waitUntil { handler.requests.count == 1 }
            try await Task.sleep(for: .milliseconds(50))
            #expect(facade.conversation.messages.count == 1)
            facade.teardown()
        }
    }

    @Test("Without a module the card opens Apple's page through the link path")
    @MainActor func fallbackLink() async throws {
        let facade = configured()
        defer { facade.teardown() }
        var opened: [URL] = []
        facade.onLink = {
            opened.append($0)
            return true
        }
        let message = thread(Self.billingCard)
        facade.conversation.merge([message])
        #expect(!facade.canHandleStoreActions)
        facade.conversation.open(.storeAction(Self.billingCard), in: message)
        await facade.chatLinkTask?.value
        #expect(opened.map(\.absoluteString) == ["https://apps.apple.com/account/subscriptions"])
    }

    @Test("Receipt lines name the change")
    func receiptText() {
        #expect(StoreChange.englishText(.subscribed(product: "Ledgerly Plus")) == "Subscribed to Ledgerly Plus")
        #expect(StoreChange.englishText(.planChanged(product: "Pro yearly")) == "Plan changed to Pro yearly")
        #expect(StoreChange.englishText(.autoRenewOff) == "Auto-renew turned off")
        #expect(StoreChange.englishText(.codeRedeemed(product: nil)) == "Code redeemed")
        #expect(StoreChange.englishText(.purchasesRestored) == "Purchases restored")
    }

    @MainActor
    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition not met")
    }
}
