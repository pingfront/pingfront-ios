package import Foundation

/// The link card URL rule, the same on the server and in every SDK, checked against the protocol's shared
/// `link-urls.json` cases.
///
/// ASCII tab, line feed and carriage return are removed anywhere and whitespace and control characters are trimmed
/// from both ends, as a browser reads a URL; then the scheme is compared ignoring case. `https`, `http` and the app's
/// own scheme pass. The refused schemes, and a URL without a scheme, never do: a link card with one reports
/// `cannot_open` before the app's `onLink` sees it.
package enum LinkURLRule {
    /// Schemes a link card never carries, whatever the card says (the server refuses them too; defence in depth).
    package static let refusedSchemes: Set<String> = ["javascript", "data", "vbscript", "file", "blob", "about", "content", "intent"]

    /// Schemes the browser opens.
    package static let webSchemes: Set<String> = ["http", "https"]

    private static let edges = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

    /// The URL as the rule reads it.
    package static func clean(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView(raw.unicodeScalars.filter { !["\t", "\n", "\r"].contains($0) })
        while let first = scalars.first, edges.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, edges.contains(last) { scalars.removeLast() }
        return String(scalars)
    }

    /// The scheme in lowercase (a letter, then letters, digits, `+`, `-` or `.`, up to the first `:`), or `nil`.
    package static func scheme(_ raw: String) -> String? {
        let cleaned = clean(raw)
        guard let colon = cleaned.firstIndex(of: ":") else { return nil }
        let scheme = cleaned[..<colon]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-."))
        guard let first = scheme.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first),
            scheme.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
        else { return nil }
        return scheme.lowercased()
    }

    /// Whether a link card may carry the URL.
    package static func allows(_ raw: String) -> Bool {
        guard let scheme = scheme(raw) else { return false }
        return !refusedSchemes.contains(scheme)
    }

    /// The app's own schemes, from its Info.plist (`CFBundleURLTypes`, each type's `CFBundleURLSchemes`), lowercased.
    ///
    /// https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app
    package static func appSchemes(in bundle: Bundle = .main) -> Set<String> {
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return Set(types.flatMap { ($0["CFBundleURLSchemes"] as? [String] ?? []).map { $0.lowercased() } })
    }
}
