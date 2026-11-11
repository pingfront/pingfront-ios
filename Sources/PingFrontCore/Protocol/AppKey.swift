import Foundation

/// Why an app key was rejected offline.
///
/// Mirrors the key problems of the protocol's shared `keys.json` cases.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum KeyProblem: String, Error, Sendable, Equatable, CaseIterable {
    /// The key is an empty string.
    case empty
    /// The key has leading or trailing whitespace or line breaks.
    case whitespace
    /// The key does not start with `pk_live_` or `pk_test_`.
    case wrongPrefix = "wrong_prefix"
    /// The key is longer or shorter than a public key.
    case wrongLength = "wrong_length"
    /// The key contains characters outside base62.
    case badCharacters = "bad_characters"
    /// The two check characters do not match the rest of the key (a typo).
    case checksumMismatch = "checksum_mismatch"

    /// The exact, actionable explanation shown in debug banners and logs.
    public var message: String {
        switch self {
        case .empty: "The app key is empty. Copy it from Dashboard > App > Connect."
        case .whitespace: "The app key has spaces or line breaks around it. Remove them."
        case .wrongPrefix: "This is not a public app key. Public keys start with pk_live_ or pk_test_."
        case .wrongLength: "The app key has the wrong length. It was probably cut off when copying."
        case .badCharacters: "The app key contains characters that never appear in keys."
        case .checksumMismatch: "The app key has a typo: its check characters do not match."
        }
    }
}

/// A public app key that passed the offline checksum.
public struct AppKey: Sendable, Equatable, CustomStringConvertible {
    /// Whether the key belongs to the live or the test environment.
    public enum Mode: String, Sendable { case live, test }

    /// The full key string, for example `pk_live_…`.
    public let rawValue: String
    /// `live` or `test`.
    public let mode: Mode

    /// The key with its body masked, safe to show in logs and banners.
    public var description: String { "pk_\(mode.rawValue)_…\(rawValue.suffix(4))" }

    /// Validates `key` offline with the CRC-32 check characters.
    ///
    /// No network.
    public static func parse(_ key: String) -> Result<AppKey, KeyCheckError> {
        switch KeyCheck.check(key) {
        case .success(let mode): .success(AppKey(rawValue: key, mode: mode))
        case .failure(let problem): .failure(KeyCheckError(problem: problem))
        }
    }
}

/// An offline key check failure.
public struct KeyCheckError: Error, Sendable, Equatable {
    /// What is wrong with the key.
    public let problem: KeyProblem
}

/// The checksum algorithm of the protocol's shared `keys.json` cases, mirrored exactly:
/// `n = crc32(prefix + body) mod 3844`, check = `BASE62[n / 62] + BASE62[n % 62]`.
package enum KeyCheck {
    package static let base62 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    package static let bodyLength = 22

    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320) of the UTF-8 bytes.
    package static func crc32(_ input: String) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in input.utf8 { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    package static func checkChars(_ prefixAndBody: String) -> String {
        let n = Int(crc32(prefixAndBody) % 3844)
        return String(decoding: [base62[n / 62], base62[n % 62]], as: UTF8.self)
    }

    package static func check(_ key: String, expectedKind: String = "pk") -> Result<AppKey.Mode, KeyProblem> {
        if key.isEmpty { return .failure(.empty) }
        if key.trimmingCharacters(in: .whitespacesAndNewlines) != key { return .failure(.whitespace) }
        // ^([a-z]+)_(live|test)_(.*)$
        let pieces = key.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3,
            !pieces[0].isEmpty, pieces[0].utf8.allSatisfy({ (97...122).contains($0) }),
            let mode = AppKey.Mode(rawValue: String(pieces[1])),
            pieces[0] == expectedKind
        else { return .failure(.wrongPrefix) }
        let rest = pieces[2]
        guard rest.utf8.count == bodyLength + 2 else { return .failure(.wrongLength) }
        guard rest.utf8.allSatisfy({ base62.contains($0) }) else { return .failure(.badCharacters) }
        let body = rest.prefix(bodyLength)
        let head = "\(expectedKind)_\(mode.rawValue)_\(body)"
        guard checkChars(head) == String(rest.suffix(2)) else { return .failure(.checksumMismatch) }
        return .success(mode)
    }
}
