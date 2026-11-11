import Foundation

/// Reads the claims of an HS256 identity token.
///
/// The signature is verified by the server, never here.
package enum IdentityToken {
    package struct Claims: Decodable, Sendable {
        package var sub: String
        package var name: String?
        package var email: String?
    }

    package static func claims(_ token: String) -> Claims? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var base64 = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(Claims.self, from: data)
    }
}

/// Client-side checks that keep one bad value from failing a whole PATCH.
package enum ProfileValidation {
    package static func isEmail(_ value: String) -> Bool {
        guard value.count <= Limits.emailChars, let at = value.firstIndex(of: "@") else { return false }
        let domain = value[value.index(after: at)...]
        return at != value.startIndex && domain.contains(".") && !value.contains(" ")
    }

    /// Drops traits over the limits and returns the problems found.
    package static func clean(_ traits: [String: String]) -> (traits: [String: String], problems: [String]) {
        var result: [String: String] = [:]
        var problems: [String] = []
        for (key, value) in traits.sorted(by: { $0.key < $1.key }) {
            if key.isEmpty || key.count > Limits.traitKeyChars {
                problems.append("Trait key \"\(key.prefix(20))\" must be 1–64 characters.")
                continue
            }
            if value.count > Limits.traitValueChars {
                problems.append("Trait \"\(key)\" is longer than 512 characters.")
                continue
            }
            result[key] = value
        }
        return (result, problems)
    }
}
