package import Foundation
internal import os

/// The language the host chose in its own picker (`PingFront.shared.language`), read synchronously by
/// device facts and `LocalizedText` lookups. `nil` follows the system.
package enum LanguageOverride {
    // A lock, not an actor: read synchronously while building device facts, where awaiting an actor isn't possible.
    private static let state = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The override tag, if any.
    package static var tag: String? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    /// A BCP 47 tag the SDK accepts: ASCII letters, digits and hyphens (underscores become hyphens),
    /// starting with a letter, at most 20 characters.
    package static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let tag = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        guard !tag.isEmpty, tag.count <= 20, tag.first?.isLetter == true,
            tag.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" })
        else { return nil }
        return tag
    }

    /// The person's language: the override, else the first preferred language.
    package static var effectiveTag: String { tag ?? Locale.preferredLanguages.first ?? "en" }

    /// The locale for formatting: the override's, else the current locale.
    package static var effectiveLocale: Locale { tag.map { Locale(identifier: $0) } ?? .current }

    /// Latin American and Caribbean regions that read `es-419` rather than Spain's Spanish.
    private static let latinAmerica: Set<String> = [
        "419", "AR", "BO", "BR", "BZ", "CL", "CO", "CR", "CU", "DO", "EC", "GT", "HN", "MX", "NI", "PA", "PE", "PR", "PY", "SV",
        "US", "UY", "VE",
    ]
    /// Regions that write European Portuguese (`pt-PT`); any other Portuguese reads `pt-BR`.
    private static let europeanPortuguese: Set<String> = ["PT", "AO", "MZ", "CV", "GW", "ST", "TL", "MO"]
    /// Regions that write Chinese in Traditional script when the tag names no script.
    private static let traditionalChinese: Set<String> = ["TW", "HK", "MO"]

    /// Regions whose Traditional Chinese reads Hong Kong's (`zh-HK`) before Taiwan's (`zh-Hant`), as CLDR's
    /// parent locales have it.
    private static let hongKongChinese: Set<String> = ["HK", "MO"]

    /// The translation folders (`.lproj` names) to try, most specific first: the full tag, `zh-HK` for Traditional
    /// Chinese in Hong Kong and Macau, language plus script, language plus region (with `es-419` for Latin America,
    /// `pt-PT` for Portugal and the countries that write European Portuguese, `pt-BR` for any other Portuguese, and
    /// `nb` for any Norwegian), the language, then English.
    package static func candidates(for locale: Locale) -> [String] {
        let language = locale.language.languageCode?.identifier ?? "en"
        let region = locale.language.region?.identifier
        var script = locale.language.script?.identifier
        if language == "zh", script == nil { script = region.map { traditionalChinese.contains($0) } == true ? "Hant" : "Hans" }
        var result = [locale.identifier(.bcp47)]
        if language == "zh", script == "Hant", let region, hongKongChinese.contains(region) { result.append("zh-HK") }
        if let script { result.append("\(language)-\(script)") }
        if let region { result.append("\(language)-\(region)") }
        if language == "es", let region, latinAmerica.contains(region) { result.append("es-419") }
        if language == "pt" { result.append(region.map { europeanPortuguese.contains($0) } == true ? "pt-PT" : "pt-BR") }
        if language == "no" || language == "nn" { result.append("nb") }
        result += [language, "en"]
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}
