import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

@Suite("Language override and translation lookup", .serialized)
@MainActor
struct LanguageTests {
    @Test(
        "Translation folders: script, region, es-419 for Latin America, pt-PT or pt-BR for Portuguese, nb for Norwegian",
        arguments: [
            ("es-MX", "es-419"), ("es-AR", "es-419"), ("zh-TW", "zh-Hant"), ("zh-HK", "zh-HK"), ("zh-CN", "zh-Hans"),
            ("zh-Hant", "zh-Hant"), ("zh-Hant-HK", "zh-HK"), ("zh-MO", "zh-HK"), ("pt-PT", "pt-PT"), ("pt-AO", "pt-PT"),
            ("pt-MZ", "pt-PT"), ("pt", "pt-BR"), ("pt-BR", "pt-BR"), ("he-IL", "he"), ("de-AT", "de"), ("nb-NO", "nb"),
            ("no", "nb"), ("nn", "nb"), ("fa-IR", "fa"), ("fr-CA", "fr-CA"), ("mr-IN", "mr"), ("pa-Guru-IN", "pa"),
        ])
    func candidates(tag: String, expected: String) {
        let candidates = LanguageOverride.candidates(for: Locale(identifier: tag))
        #expect(candidates.contains(expected), "\(tag): \(candidates)")
        #expect(candidates.last == "en")
        #expect(candidates.firstIndex(of: expected)! < candidates.firstIndex(of: "en")!)
    }

    @Test("Spain's Spanish never picks es-419")
    func spain() {
        #expect(!LanguageOverride.candidates(for: Locale(identifier: "es-ES")).contains("es-419"))
    }

    @Test("Hong Kong's Chinese tries zh-HK before zh-Hant; Taiwan's and Simplified Chinese never pick zh-HK")
    func hongKong() {
        for tag in ["zh-HK", "zh-Hant-HK", "zh-MO"] {
            let candidates = LanguageOverride.candidates(for: Locale(identifier: tag))
            #expect(candidates.firstIndex(of: "zh-HK")! < candidates.firstIndex(of: "zh-Hant")!, "\(tag): \(candidates)")
        }
        #expect(!LanguageOverride.candidates(for: Locale(identifier: "zh-TW")).contains("zh-HK"))
        let simplified = LanguageOverride.candidates(for: Locale(identifier: "zh-Hans-HK"))
        #expect(simplified.firstIndex(of: "zh-Hans")! < (simplified.firstIndex(of: "zh-HK") ?? simplified.endIndex), "\(simplified)")
    }

    @Test("Canadian French tries fr-CA before French; France's never picks fr-CA")
    func canadianFrench() {
        let candidates = LanguageOverride.candidates(for: Locale(identifier: "fr-CA"))
        #expect(candidates.firstIndex(of: "fr-CA")! < candidates.firstIndex(of: "fr")!)
        #expect(!LanguageOverride.candidates(for: Locale(identifier: "fr-FR")).contains("fr-CA"))
    }

    @Test("Brazil's Portuguese never picks pt-PT, and Portugal's never pt-BR")
    func portuguese() {
        #expect(!LanguageOverride.candidates(for: Locale(identifier: "pt-BR")).contains("pt-PT"))
        #expect(!LanguageOverride.candidates(for: Locale(identifier: "pt-PT")).contains("pt-BR"))
    }

    @Test("Only BCP 47-shaped tags are accepted", arguments: [("pt_BR", "pt-BR"), (" de ", "de"), ("zh-Hant", "zh-Hant")])
    func normalized(raw: String, expected: String) {
        #expect(LanguageOverride.normalized(raw) == expected)
    }

    @Test("Invalid tags are rejected", arguments: ["", "1de", "de;DROP", "äö", String(repeating: "a", count: 21)])
    func rejected(raw: String) {
        #expect(LanguageOverride.normalized(raw) == nil)
    }

    @Test("language follows the override into device facts and back to the system; an invalid value is ignored")
    func override() {
        let facade = PingFront()
        defer {
            facade.language = nil
        }
        facade.language = "pt_BR"
        #expect(facade.language == "pt-BR")
        #expect(DeviceInfo.current(installId: "i").language == "pt-BR")
        #expect(DeviceInfo.languageTag == "pt-BR")
        facade.language = "not a tag"
        #expect(facade.language == "pt-BR")
        facade.language = nil
        #expect(LanguageOverride.tag == nil)
        #expect(DeviceInfo.current(installId: "i").language == (Locale.preferredLanguages.first ?? "en"))
    }

    @Test("A language change after the session started goes out as a device PATCH")
    func patchesDevice() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("PATCH me", .ok(#"{"person":{"id":"p_1","level":"guest"}}"#))
        let facade = PingFront()
        let clock = TestClock()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(clock))
        facade.start(appKey: "pk_test_abcdefghijklmnopqrstuvvd", configuration: configuration)
        Retain.keep(facade)
        defer {
            facade.language = nil
            facade.teardown()
        }
        try await facade.prepare()
        facade.language = "ko"
        var patched = false
        for _ in 0..<200 where !patched {
            clock.advance(by: Timing.patchWindow)
            await settle()
            patched = await server.requests("PATCH me").contains { $0.bodyString.contains(#""language":"ko""#) }
        }
        #expect(patched)
    }
}
