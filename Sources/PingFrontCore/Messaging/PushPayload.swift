import Foundation

/// The `pingfront` object of an APNs payload (the protocol's `ApnsPayload`, `v: 1`).
///
/// Anything else is not ours.
package struct PushPayload: Sendable, Equatable {
    /// The top-level key that holds the pingfront data.
    package static let key = "pingfront"

    /// What the push is about.
    ///
    /// Kinds this version does not know are ignored.
    package enum Kind: String, Sendable {
        case message, ping, config
    }

    package var kind: Kind
    /// The person's unread count when the push was sent.
    package var unread: Int?

    /// The fields of the `pingfront` object.
    private enum Field: String {
        case version = "v"
        case kind, appId, unread
    }

    /// Parses `userInfo`; `nil` unless it is a version 1 pingfront payload of a known kind.
    package init?(userInfo: [AnyHashable: Any]) {
        guard let object = userInfo[Self.key] as? [String: Any] else { return nil }
        func value<T>(_ field: Field, as type: T.Type) -> T? { object[field.rawValue] as? T }
        guard value(.version, as: NSNumber.self)?.intValue == 1,
            let kind = value(.kind, as: String.self).flatMap(Kind.init(rawValue:)),
            value(.appId, as: String.self) != nil
        else { return nil }
        self.kind = kind
        unread = value(.unread, as: NSNumber.self).map(\.intValue).flatMap { $0 >= 0 ? $0 : nil }
    }

    /// True when `userInfo` carries a pingfront object at all (any version), so it is never shown as the host's.
    package static func isPingFront(_ userInfo: [AnyHashable: Any]) -> Bool { userInfo[key] != nil }
}
