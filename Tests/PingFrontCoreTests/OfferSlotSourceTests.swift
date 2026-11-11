import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// A module source whose slots change while the app runs.
struct ChangingOffers: OfferSource {
    let stream: AsyncStream<[OfferSlot]>
    var slotSource: OfferSlot.Source { .revenuecat }
    func offers() async -> [OfferSlot] { [] }
    func offerUpdates() -> AsyncStream<[OfferSlot]> { stream }
}

@Suite("Offer slot sources")
struct OfferSlotSourceTests {
    let key = "pk_test_abcdefghijklmnopqrstuvvd"

    @MainActor
    func configured(_ modules: [PingFrontModule] = []) -> PingFront {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: StubServer()), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(TestClock()))
        for module in modules { configuration.use(module) }
        facade.start(appKey: key, configuration: configuration)
        // The engine holds its facade unowned; keep it for engine tasks that outlive the test.
        Retain.keep(facade)
        return facade
    }

    @Test("source is on the wire per the contract; unknown values decode to .unknown and are never sent")
    func wire() throws {
        let slot = OfferSlot(id: "pro", title: "Pro", products: [.init(id: "p", price: "$1")], source: .revenuecat)
        let json = String(decoding: try JSONEncoder().encode(slot), as: UTF8.self)
        #expect(json.contains(#""source":"revenuecat""#))
        #expect(
            Set(OfferSlot.Source.allCases.map(\.rawValue)) == ["revenuecat", "superwall", "adapty", "storekit", "play", "app", "unknown"])
        let future = try JSONDecoder().decode(
            OfferSlot.self, from: Data(#"{"id":"a","title":"A","kind":"standard","available":true,"source":"paddle"}"#.utf8))
        #expect(future.source == .unknown)
        #expect(!String(decoding: try JSONEncoder().encode(future), as: UTF8.self).contains("source"))
        let old = try JSONDecoder().decode(OfferSlot.self, from: Data(#"{"id":"a","title":"A","kind":"standard","available":true}"#.utf8))
        #expect(old.source == nil)
    }

    @Test("Merging: the app's slots first, then sources in order; the first id wins; at most 20")
    @MainActor func merge() {
        let app = [OfferSlot(id: "a", title: "App", source: .app), OfferSlot(id: "shared", title: "From app", source: .app)]
        let storekit = [
            OfferSlot(id: "shared", title: "From StoreKit", source: .storekit), OfferSlot(id: "s", title: "SK", source: .storekit),
        ]
        let revenuecat = (0..<3).map { OfferSlot(id: "rc\($0)", title: "RC", source: .revenuecat) }
        let merged = PingFront.mergedSlots([.storekit: storekit, .app: app, .revenuecat: revenuecat])
        #expect(merged.map(\.id) == ["a", "shared", "rc0", "rc1", "rc2", "s"])
        #expect(merged.first { $0.id == "shared" }?.title == "From app")
        let many = (0..<30).map { OfferSlot(id: "rc\($0)", title: "RC", source: .revenuecat) }
        #expect(PingFront.mergedSlots([.app: app, .revenuecat: many]).count == 20)
    }

    @Test("setOffers keeps module slots; a module's update replaces only its own")
    @MainActor func setOffersMerges() {
        let facade = configured()
        defer { facade.teardown() }
        facade.setOffers([OfferSlot(id: "sk", title: "StoreKit yearly")], from: .storekit)
        facade.setOffers([OfferSlot(id: "app", title: "My paywall")])
        #expect(facade.offerSlots.map(\.id) == ["app", "sk"])
        #expect(facade.offerSlots.map(\.source) == [.app, .storekit])
        facade.setOffers([OfferSlot(id: "sk2", title: "StoreKit monthly")], from: .storekit)
        #expect(facade.offerSlots.map(\.id) == ["app", "sk2"])
        // A vendor adapter publishing through setOffers(_:) with stamped slots leaves the app's slots alone.
        facade.setOffers([OfferSlot(id: "rc", title: "RevenueCat", source: .revenuecat)])
        #expect(facade.offerSlots.map(\.id) == ["app", "rc", "sk2"])
        facade.setOffers([])
        #expect(facade.offerSlots.map(\.id) == ["rc", "sk2"])
        facade.setOffers([], from: .revenuecat)
        facade.setOffers([], from: .storekit)
        #expect(facade.offerSlots.isEmpty)
    }

    @Test("Module offer sources update live, alongside the app's slots")
    @MainActor func liveSources() async throws {
        let (stream, continuation) = AsyncStream<[OfferSlot]>.makeStream()
        let facade = configured([PingFrontModule(id: "rc") { $0.addOfferSource(ChangingOffers(stream: stream)) }])
        defer { facade.teardown() }
        facade.setOffers([OfferSlot(id: "app", title: "Mine")])
        continuation.yield([OfferSlot(id: "rc_default", title: "Default")])
        try await waitUntil { facade.offerSlots.map(\.id) == ["app", "rc_default"] }
        continuation.yield([OfferSlot(id: "rc_sale", title: "Sale")])
        try await waitUntil { facade.offerSlots.map(\.id) == ["app", "rc_sale"] }
        #expect(facade.offerSlots.last?.source == .revenuecat)
    }

    @Test("OfferRequest has a public initializer for tests")
    func request() {
        let request = OfferRequest(offerId: "pro", cardId: "c1", messageId: "m1", storeOffer: StoreOffer(kind: .promotional, id: "o"))
        #expect(request.offerId == "pro" && request.slot == nil && request.storeOffer?.id == "o")
    }

    @Test("Modules can register a wipe handler that runs on logout")
    @MainActor func wipeHook() async throws {
        var wiped = 0
        let facade = configured([PingFrontModule(id: "adapter") { $0.onLocalDataWipe { wiped += 1 } }])
        defer { facade.teardown() }
        facade.runWipeHandlers()
        #expect(wiped == 1)
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
