import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore

/// The chat's string catalog (`PingFrontUI/Resources/Localizable.xcstrings`): every key in every shipped
/// language, with the same placeholders as English, and plural forms that keep their number.
@Suite("Translation catalog")
struct TranslationCatalogTests {
    static let languages = [
        "ar", "bg", "bn", "ca", "cs", "da", "de", "el", "en", "es", "es-419", "fa", "fi", "fr", "fr-CA", "gu", "he", "hi", "hr",
        "hu", "id", "it", "ja", "kn", "ko", "ml", "mr", "ms", "nb", "nl", "or", "pa", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk",
        "sl", "sv", "ta", "te", "th", "tr", "uk", "ur", "vi", "zh-Hans", "zh-Hant", "zh-HK",
    ]
    static let rightToLeft: Set<String> = ["ar", "fa", "he", "ur"]

    static var catalogURL: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/PingFrontUI/Resources/Localizable.xcstrings")
    }

    /// Every form of a localization: one string, or each plural category (for a plural on one argument, the whole sentence).
    static func forms(_ localization: [String: Any]) -> [String: String] {
        if let plurals = LocalizationTests.substitutedPlurals(localization) { return plurals }
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String { return ["": value] }
        let plural = ((localization["variations"] as? [String: Any])?["plural"] as? [String: Any]) ?? [:]
        var result: [String: String] = [:]
        for (category, form) in plural {
            if let unit = (form as? [String: Any])?["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
                result[category] = value
            }
        }
        return result
    }

    /// Placeholders, without positions (translations may reorder them).
    static func placeholders(_ text: String) -> [String] {
        let regex = /%(?:\d+\$)?(lld|ld|d|@|s|f)/
        return text.matches(of: regex).map { String($0.output.1) }.sorted()
    }

    func catalog() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: Self.catalogURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: [String: Any]])
    }

    @Test("Every key is translated into every shipped language")
    func complete() throws {
        var missing: [String] = []
        for (key, entry) in try catalog() {
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in Self.languages where language != "en" && localizations[language] == nil {
                missing.append("\(language): \(key)")
            }
        }
        #expect(missing.isEmpty, "\(missing.prefix(20))")
    }

    @Test("Translations keep English's placeholders, in every plural form")
    func placeholdersMatch() throws {
        var wrong: [String] = []
        for (key, entry) in try catalog() {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            let english = localizations["en"].map(Self.forms) ?? ["": key]
            let reference = Self.placeholders(english["other"] ?? english[""] ?? key)
            for (language, localization) in localizations {
                for (category, text) in Self.forms(localization) {
                    let found = Self.placeholders(text)
                    // A form that covers exactly one number may spell it out: "zero" anywhere ("No new
                    // messages"), and Arabic's "one" and "two" (in Slavic languages "one" also covers 21, 31…).
                    let exact = category == "zero" || (language == "ar" && (category == "one" || category == "two"))
                    if found != reference, !(exact && found.isEmpty) {
                        wrong.append("\(language)[\(category)] \(key): \(text)")
                    }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(20))")
    }

    @Test("Right-to-left languages are detected as such", arguments: languages)
    func direction(language: String) {
        let rtl = Locale.Language(identifier: language).characterDirection == .rightToLeft
        #expect(rtl == Self.rightToLeft.contains(language))
    }

    @Test("Each shipped language resolves to its own translation folder", arguments: languages)
    func resolves(language: String) {
        #expect(LanguageOverride.candidates(for: Locale(identifier: language)).contains(language))
    }
}
