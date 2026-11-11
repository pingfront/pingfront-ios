import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore

/// Public API the React Native and Flutter bridges read, matching Android.
@Suite("Bridge parity")
struct BridgeParityTests {
    @Test("A translation keeps the language it was translated from (Message fixture)")
    func translationFrom() throws {
        let url = ConformanceTests.root.appending(path: "sdk/Message.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let valid = json?["valid"] as? [[String: Any]] ?? []
        let item = try #require(valid.first { ($0["name"] as? String)?.hasPrefix("a team reply sent in the person's language") == true })
        let message = try WireJSON.decode(Message.self, from: JSONSerialization.data(withJSONObject: try #require(item["value"])))
        #expect(message.translation?.language == "es")
        #expect(message.translation?.from == "en")
        // Older servers send no `from`.
        let older = try WireJSON.decode(Translation.self, from: Data(#"{"language":"es","parts":[]}"#.utf8))
        #expect(older.from == nil)
    }

    @Test("A send policy reason has a stable string code")
    func reasonCodes() {
        #expect(SendPolicy.Reason.appPaused.code == "app_paused")
        #expect(SendPolicy.Reason.verificationRequired.code == "verification_required")
        #expect(SendPolicy.Reason.blocked.code == "blocked")
    }

    @Test("A held message says why")
    func heldFor() {
        var message = PendingMessage(clientId: "c", text: "Hi")
        #expect(!message.isHeld)
        message.heldFor = .verificationRequired
        #expect(message.isHeld)
        #expect(message.heldFor?.code == "verification_required")
    }
}
