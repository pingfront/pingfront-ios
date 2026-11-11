package import Foundation
internal import os

/// JSON coders configured for the wire protocol (ISO-8601 dates with offsets).
///
/// One encoder and one decoder for the whole SDK: they are immutable after setup and safe to share.
package enum WireJSON {
    private static let sharedDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ISODate.parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO-8601 date")
            }
            return date
        }
        return decoder
    }()

    private static let sharedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISODate.format(date))
        }
        return encoder
    }()

    package static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try sharedDecoder.decode(type, from: data)
    }

    package static func encode(_ value: some Encodable) throws -> Data {
        try sharedEncoder.encode(value)
    }
}

/// ISO-8601 parsing that accepts `Z` or `±hh:mm` offsets, with or without fractional seconds.
package enum ISODate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    package static func parse(_ string: String) -> Date? {
        if let date = try? fractional.parse(string) { return date }
        if let date = try? whole.parse(string) { return date }
        return nil
    }

    package static func format(_ date: Date) -> String { date.formatted(fractional) }
}

/// Decodes an array, dropping elements that fail to decode instead of failing the whole array.
///
/// Old SDKs keep working when the server adds shapes they do not know.
package struct LossyArray<Element: Decodable>: Decodable {
    package var elements: [Element]

    package init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            do {
                result.append(try container.decode(Element.self))
            } catch {
                _ = try? container.decode(Skip.self)
                #if DEBUG
                    Log.decoding(.debug)?.debug(
                        "Dropped one \(String(describing: Element.self), privacy: .public) element this SDK cannot read")
                #endif
            }
        }
        elements = result
    }

    private struct Skip: Decodable {}
}

extension KeyedDecodingContainer {
    package func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        try decodeIfPresent(LossyArray<T>.self, forKey: key)?.elements ?? []
    }

    /// One optional field, decoded on its own: a bad value drops only this field (logged in debug builds),
    /// never its siblings or the enclosing object.
    package func tolerant<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            #if DEBUG
                Log.decoding(.debug)?.debug("Ignored the unreadable field \(key.stringValue, privacy: .public)")
            #endif
            return nil
        }
    }
}

/// A string-backed wire enum that decodes values it does not know into `fallback`
/// instead of failing, so new server values never break old SDKs.
package protocol TolerantStringEnum: RawRepresentable, Codable where RawValue == String {
    /// The case used for values this SDK version does not know.
    static var fallback: Self { get }
}

extension TolerantStringEnum {
    /// Decodes the raw value, or `fallback` when it is unknown (logged in debug builds).
    package static func tolerant(from decoder: any Decoder) throws -> Self {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = Self(rawValue: raw) { return value }
        #if DEBUG
            Log.decoding(.debug)?.debug("Unknown \(String(describing: Self.self), privacy: .public) value; using the fallback")
        #endif
        return Self.fallback
    }

    /// Decodes the raw value, or `fallback` when it is unknown.
    package init(from decoder: any Decoder) throws { self = try Self.tolerant(from: decoder) }
}
