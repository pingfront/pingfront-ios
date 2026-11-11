/// Text limits count Unicode code points on every platform (`codePoints()` in the protocol), never
/// grapheme clusters or UTF-16 units, so the composer, the SDK and the server agree.
package enum TextLimit {
    /// The length of `text` as the server counts it.
    package static func count(_ text: String) -> Int { text.unicodeScalars.count }

    /// Characters left before `limit` (negative when over).
    package static func remaining(_ text: String, limit: Int = Limits.textChars) -> Int { limit - count(text) }

    /// The composer shows a counter once fewer than this many characters are left.
    package static let counterThreshold = 200
}

/// Byte-bounded text, cut on a character boundary.
package enum UTF8Tail {
    /// The last `maxBytes` bytes of `text` as valid UTF-8: a code point cut in half at the start is
    /// dropped, never the whole text.
    package static func suffix(_ text: String, maxBytes: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return text }
        var tail = bytes.suffix(maxBytes)[...]
        // Continuation bytes are 0b10xxxxxx; skip them until a code point starts.
        while let first = tail.first, first & 0b1100_0000 == 0b1000_0000 { tail = tail.dropFirst() }
        return String(decoding: tail, as: UTF8.self)
    }
}
