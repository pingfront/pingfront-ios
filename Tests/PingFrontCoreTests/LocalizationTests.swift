import Foundation
import Testing

/// The UI string catalog: every key in every shipped locale (`TranslationCatalogTests.languages`, the same 50 every
/// SDK ships), with the plural categories each language has and the English placeholders.
@Suite("Localization")
struct LocalizationTests {
    static let catalogURL = TestPaths.package.appending(path: "Sources/PingFrontUI/Resources/Localizable.xcstrings")

    /// CLDR plural categories for integers, per language.
    static let pluralCategories: [String: Set<String>] = {
        var map: [String: Set<String>] = [:]
        for tag in ["cs", "sk", "pl", "ru", "uk"] { map[tag] = ["one", "few", "many", "other"] }
        map["sl"] = ["one", "two", "few", "other"]
        for tag in ["hr", "ro"] { map[tag] = ["one", "few", "other"] }
        map["ar"] = ["zero", "one", "two", "few", "many", "other"]
        map["he"] = ["one", "two", "other"]
        for tag in ["fr", "fr-CA", "es", "es-419", "it", "pt-BR", "pt-PT", "ca"] { map[tag] = ["one", "many", "other"] }
        for tag in ["zh-Hans", "zh-Hant", "zh-HK", "ja", "ko", "th", "vi", "id", "ms"] { map[tag] = ["other"] }
        return map
    }()

    /// The tags in the shared locale table (its first column).
    static func documentedLocales() throws -> [String] {
        let doc = try String(contentsOf: try #require(TestPaths.localesDoc), encoding: .utf8)
        let section = try #require(doc.components(separatedBy: "## Locales").last?.components(separatedBy: "\n## ").first)
        return section.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count > 1, cells[0].hasPrefix("`"), cells[0].hasSuffix("`") else { return nil }
            return String(cells[0].dropFirst().dropLast())
        }
    }

    static func catalog() throws -> [String: [String: Any]] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        return try #require(json?["strings"] as? [String: [String: Any]])
    }

    static func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(@|lld|ld|d|f)")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { (text as NSString).substring(with: $0.range(at: 1)) }.sorted()
    }

    @Test(
        "The shared locale table lists the 50 locales iOS ships",
        .enabled(if: TestPaths.localesDoc != nil, "the shared locale table is not beside this package"))
    func documentedLocalesShip() throws {
        let locales = try Self.documentedLocales()
        #expect(locales.count == 50, "\(locales)")
        #expect(Set(locales).count == locales.count)
        #expect(Set(locales) == Set(TranslationCatalogTests.languages))
    }

    @Test("iOS ships each of the 50 locales")
    func everyLocale() throws {
        let locales = TranslationCatalogTests.languages
        #expect(locales.count == 50, "\(locales)")
        let catalog = try Self.catalog()
        var missing: [String] = []
        for (key, entry) in catalog {
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            // English is the catalog's source language: a key without an English entry is its own English.
            for locale in locales where locale != "en" && localizations[locale] == nil { missing.append("\(locale): \(key)") }
        }
        #expect(missing.isEmpty, "\(missing.count) missing, first: \(missing.sorted().prefix(10))")
    }

    /// The plural forms of a localization that varies by one of its arguments (an xcstrings substitution), each
    /// expanded into the whole sentence; `nil` for any other localization.
    static func substitutedPlurals(_ localization: [String: Any]) -> [String: String]? {
        guard let substitutions = localization["substitutions"] as? [String: [String: Any]], substitutions.count == 1,
            let (name, substitution) = substitutions.first,
            let format = (localization["stringUnit"] as? [String: Any])?["value"] as? String,
            let plural = (substitution["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]]
        else { return nil }
        let argument = "%\(substitution["argNum"] as? Int ?? 1)$\(substitution["formatSpecifier"] as? String ?? "@")"
        let token = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?#@\(name)@")
        return plural.compactMapValues { form in
            guard let text = (form["stringUnit"] as? [String: Any])?["value"] as? String else { return nil }
            let expanded = text.replacingOccurrences(of: "%arg", with: argument)
            return token.stringByReplacingMatches(
                in: format, range: NSRange(format.startIndex..., in: format),
                withTemplate: NSRegularExpression.escapedTemplate(for: expanded))
        }
    }

    @Test("Every translation keeps the English placeholders; counts give every plural category of the language")
    func placeholdersAndPlurals() throws {
        let catalog = try Self.catalog()
        var problems: [String] = []
        for (key, entry) in catalog {
            for (locale, value) in entry["localizations"] as? [String: [String: Any]] ?? [:] {
                let english = Self.placeholders(key)
                if let plurals = Self.substitutedPlurals(value) {
                    // A plural on one argument of several: each form is the whole sentence, with every placeholder.
                    let need = Self.pluralCategories[locale] ?? ["one", "other"]
                    if Set(plurals.keys) != need { problems.append("\(locale) \(key): categories \(plurals.keys.sorted())") }
                    for (category, text) in plurals where Self.placeholders(text) != english {
                        problems.append("\(locale) \(key) [\(category)]: \(text)")
                    }
                } else if let unit = value["stringUnit"] as? [String: Any], let text = unit["value"] as? String {
                    if text.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(locale) \(key): empty") }
                    if Self.placeholders(text) != english { problems.append("\(locale) \(key): \(text)") }
                } else if let plural = (value["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] {
                    let need = Self.pluralCategories[locale] ?? ["one", "other"]
                    if Set(plural.keys) != need { problems.append("\(locale) \(key): categories \(plural.keys.sorted())") }
                    for (category, form) in plural {
                        let text = (form["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                        let got = Self.placeholders(text)
                        // A form for an exact number may spell it out.
                        let exact = ["zero", "one", "two"].contains(category) && got == english.filter { $0 != "lld" }
                        if got != english, !exact { problems.append("\(locale) \(key) [\(category)]: \(text)") }
                    }
                } else {
                    problems.append("\(locale) \(key): no string")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) problems: \(problems.sorted().prefix(10))")
    }

    @Test("The star rating's label agrees with the number its noun counts, in every language")
    func starsPlural() throws {
        let key = "%1$lld of %2$lld stars"
        let localizations = try #require(try Self.catalog()[key]?["localizations"] as? [String: [String: Any]])
        #expect(Set(localizations.keys) == Set(TranslationCatalogTests.languages))
        for (locale, value) in localizations {
            let substitution = (value["substitutions"] as? [String: [String: Any]])?.values.first
            #expect(substitution?["argNum"] as? Int == (Self.nounOnRating.contains(locale) ? 1 : 2), "\(locale)")
            let forms = try #require(Self.substitutedPlurals(value), "\(locale) is not a plural")
            #expect(Set(forms.keys) == Self.pluralCategories[locale] ?? ["one", "other"], "\(locale)")
        }
    }

    /// The noun follows the rating in these ("1 étoile sur 5"); elsewhere it counts the total ("1 of 5 stars").
    static let nounOnRating: Set = ["fr", "fr-CA", "it", "bn", "gu", "hi", "kn", "ml", "mr", "or", "pa", "te"]

    @Test(
        "The star rating's label is worded as on Android, and counts the same number",
        .enabled(if: TestPaths.androidStrings != nil, "the Android SDK's strings are not beside this package"))
    func starsPluralMatchesAndroid() throws {
        let key = "%1$lld of %2$lld stars"
        let localizations = try #require(try Self.catalog()[key]?["localizations"] as? [String: [String: Any]])
        let (android, pluralOn) = try Self.androidStars()
        for (locale, value) in localizations {
            // Android picks the same number (`pf_stars_plural_on`, the total unless the language overrides it).
            #expect(pluralOn[locale] ?? pluralOn["en"] == (Self.nounOnRating.contains(locale) ? 1 : 2), "\(locale) on Android")
            let forms = try #require(Self.substitutedPlurals(value), "\(locale) is not a plural")
            #expect(forms == android[locale], "\(locale): \(forms) vs Android \(android[locale] ?? [:])")
        }
    }

    /// Android's `pf_stars` plural per locale, with its placeholders in Apple's format (`%1$d` to `%1$lld`), and
    /// `pf_stars_plural_on` where a locale sets it.
    static func androidStars() throws -> (forms: [String: [String: String]], pluralOn: [String: Int]) {
        let res = try #require(TestPaths.androidStrings)
        let qualifiers = [
            "iw": "he", "in": "id", "b+es+419": "es-419", "b+zh+Hans": "zh-Hans", "b+zh+Hant": "zh-Hant", "zh-rHK": "zh-HK",
            "fr-rCA": "fr-CA", "pt-rBR": "pt-BR", "pt-rPT": "pt-PT",
        ]
        let block = try NSRegularExpression(pattern: "<plurals name=\"pf_stars\">(.*?)</plurals>", options: .dotMatchesLineSeparators)
        let item = try NSRegularExpression(pattern: "<item quantity=\"(\\w+)\">(.*?)</item>")
        let integer = try NSRegularExpression(pattern: "<integer name=\"pf_stars_plural_on\">(\\d+)</integer>")
        var result: [String: [String: String]] = [:]
        var pluralOn: [String: Int] = [:]
        for folder in try FileManager.default.contentsOfDirectory(atPath: res.path) where folder.hasPrefix("values") {
            let qualifier = folder == "values" ? "en" : String(folder.dropFirst("values-".count))
            let locale = qualifiers[qualifier] ?? qualifier
            let stars = res.appendingPathComponent(folder).appendingPathComponent("pf_stars.xml")
            if let xml = try? String(contentsOf: stars, encoding: .utf8),
                let match = integer.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml))
            {
                pluralOn[locale] = Int((xml as NSString).substring(with: match.range(at: 1)))
            }
            let file = res.appendingPathComponent(folder).appendingPathComponent("pf_strings.xml")
            guard let xml = try? String(contentsOf: file, encoding: .utf8),
                let match = block.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
                let range = Range(match.range(at: 1), in: xml)
            else { continue }
            let body = String(xml[range])
            var forms: [String: String] = [:]
            for found in item.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                let text = (body as NSString).substring(with: found.range(at: 2))
                forms[(body as NSString).substring(with: found.range(at: 1))] = text.replacingOccurrences(of: "$d", with: "$lld")
            }
            result[locale] = forms
        }
        return (result, pluralOn)
    }

    @Test("A count in English reads one/other: the counter says 1 character, not 1 characters")
    func englishCounts() throws {
        let catalog = try Self.catalog()
        for key in ["%lld new messages", "%lld characters left", "%lld characters over the limit"] {
            let en = (catalog[key]?["localizations"] as? [String: [String: Any]])?["en"]
            let plural = (en?["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]]
            #expect(Set(plural?.keys.map { $0 } ?? []) == ["one", "other"], "\(key)")
        }
    }
}
