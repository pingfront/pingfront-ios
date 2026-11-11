import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore

@Suite("Test purchases")
struct TestPurchaseTests {
    @Test("Any environment other than production is a test purchase; absent is not")
    func environments() throws {
        func decode(_ environment: String?) throws -> Entitlement {
            let field = environment.map { #","environment":"\#($0)""# } ?? ""
            return try JSONDecoder().decode(Entitlement.self, from: Data(#"{"state":"active"\#(field)}"#.utf8))
        }
        #expect(try decode(nil).isTestPurchase == false)
        #expect(try decode("production").isTestPurchase == false)
        #expect(try decode("Production").isTestPurchase == false)
        #expect(try decode("sandbox").isTestPurchase)
        #expect(try decode("Sandbox").isTestPurchase)
        #expect(try decode("xcode").isTestPurchase)
        #expect(try decode("something_new").isTestPurchase)
        #expect(try decode("sandbox").environment == "sandbox")
    }
}
