import CryptoKit
import Foundation

/// Deterministic UUIDs (RFC 9562 version 8) from a seed, for idempotency keys that must survive restarts.
package enum StableID {
    /// The same seed always gives the same lowercase UUID string.
    package static func uuid(from seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80  // version 8
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 9562 variant
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let groups = [
            hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20),
        ]
        return groups.joined(separator: "-")
    }
}
