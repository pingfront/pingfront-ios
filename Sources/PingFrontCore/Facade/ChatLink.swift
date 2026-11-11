package import Foundation

/// A chat link: a URL whose query asks the SDK to open the chat or the bug report (https://pingfront.sh/docs/chat-links).
///
/// The rules are the same in every SDK: at most 2,048 characters, absolute and hierarchical (`scheme://…`), not a
/// `javascript`, `data`, `vbscript`, `file`, `blob`, `about`, `content` or `intent` URL, and exactly one
/// `pingfront` query parameter whose value is `chat` or `report`. `topic` is kept only for `chat` and only when it
/// appears once; whether it names one of the chat's topics is checked when the link is applied. Every other
/// parameter, and anything outside the query, is ignored.
package enum ChatLink: Equatable, Sendable {
    /// Open the chat, on a topic when the link named one.
    case chat(topic: String?)
    /// Open the bug report flow.
    case report

    /// Why a URL is not a link the SDK acts on.
    package enum Refusal: String, Error, Equatable, Sendable {
        /// No `pingfront` parameter: the app's own link.
        case notALink = "not_a_link"
        /// Longer than 2,048 characters.
        case tooLong = "too_long"
        /// Not an absolute `scheme://` URL, or a scheme that never carries a chat link.
        case scheme
        /// More than one `pingfront` parameter.
        case repeated
        /// A `pingfront` value other than `chat` or `report`.
        case unknownValue = "unknown_value"
    }

    /// The longest URL the SDK reads, in characters.
    package static let maxLength = 2048

    /// The longest topic id (`[a-z0-9_-]{1,32}`); a longer `topic` can't name a topic.
    static let maxTopicLength = 32

    /// Schemes that never carry a chat link, whatever their query says.
    static let refusedSchemes = LinkURLRule.refusedSchemes

    /// Reads a URL the app received.
    package static func parse(_ url: URL) -> Result<ChatLink, Refusal> { parse(url.absoluteString) }

    /// Reads a URL string, without Foundation's normalization, so every SDK sees the same characters.
    package static func parse(_ string: String) -> Result<ChatLink, Refusal> {
        guard string.utf16.count <= maxLength else { return .failure(.tooLong) }
        guard let schemeEnd = string.range(of: "://"), isScheme(string[..<schemeEnd.lowerBound]) else { return .failure(.scheme) }
        guard !refusedSchemes.contains(string[..<schemeEnd.lowerBound].lowercased()) else { return .failure(.scheme) }

        // Only the query counts: from the first "?" up to the fragment. The authority can't hold either.
        let rest = string[schemeEnd.upperBound...]
        let beforeFragment = rest.prefix { $0 != "#" }
        guard let question = beforeFragment.firstIndex(of: "?") else { return .failure(.notALink) }
        let query = beforeFragment[beforeFragment.index(after: question)...]

        var actions: [String] = []
        var topics: [String] = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decoded(parts[0])
            let value = parts.count > 1 ? decoded(parts[1]) : ""
            if name == "pingfront" { actions.append(value) } else if name == "topic" { topics.append(value) }
        }
        guard !actions.isEmpty else { return .failure(.notALink) }
        guard actions.count == 1 else { return .failure(.repeated) }
        switch actions[0] {
        case "chat":
            let topic = topics.count == 1 && (1...maxTopicLength).contains(topics[0].utf16.count) ? topics[0] : nil
            return .success(.chat(topic: topic))
        case "report": return .success(.report)
        default: return .failure(.unknownValue)
        }
    }

    /// RFC 3986: a letter, then letters, digits, `+`, `-` or `.`.
    private static func isScheme(_ scheme: Substring) -> Bool {
        guard let first = scheme.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return scheme.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0))
        }
    }

    /// Percent-decoded; a malformed escape keeps the raw text (it then matches nothing).
    private static func decoded(_ text: Substring) -> String { String(text).removingPercentEncoding ?? String(text) }
}
