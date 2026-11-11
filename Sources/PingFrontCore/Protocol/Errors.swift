public import Foundation

/// A server error code: the `ErrorCode` the API returns (https://pingfront.sh/docs/errors).
///
/// Unknown codes are kept verbatim.
public struct ErrorCode: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The code as sent by the server.
    public let rawValue: String
    /// Wraps a raw code string.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// The raw code.
    public var description: String { rawValue }

    /// 401: the server does not know this app key.
    public static let invalidAppKey = ErrorCode(rawValue: "invalid_app_key")
    /// 403: the app is paused in the dashboard.
    public static let appPaused = ErrorCode(rawValue: "app_paused")
    /// 401: the access token is missing or expired.
    public static let unauthorized = ErrorCode(rawValue: "unauthorized")
    /// 401: the install secret was revoked; local state must be wiped.
    public static let sessionRevoked = ErrorCode(rawValue: "session_revoked")
    /// 409: the identity token belongs to a different user.
    public static let identityUserMismatch = ErrorCode(rawValue: "identity_user_mismatch")
    /// 403: the person is blocked.
    public static let blocked = ErrorCode(rawValue: "blocked")
    /// 403: the app accepts messages only from verified people (`identify(token:)` first).
    public static let verificationRequired = ErrorCode(rawValue: "verification_required")
    /// 404.
    public static let notFound = ErrorCode(rawValue: "not_found")
    /// 409: a conflicting state (for example a promotional offer for an app without an In-App Purchase key).
    public static let conflict = ErrorCode(rawValue: "conflict")
    /// 409: the thread was reset; reload it.
    public static let threadReset = ErrorCode(rawValue: "thread_reset")
    /// 422: the request did not match the schema.
    public static let invalidRequest = ErrorCode(rawValue: "invalid_request")
    /// 413.
    public static let tooLarge = ErrorCode(rawValue: "too_large")
    /// 409: an upload was referenced before it finished.
    public static let uploadIncomplete = ErrorCode(rawValue: "upload_incomplete")
    /// 429: see `scope` and `retryAfter`.
    public static let rateLimited = ErrorCode(rawValue: "rate_limited")
    /// 503.
    public static let unavailable = ErrorCode(rawValue: "unavailable")
}

/// The part of the API a rate limit applies to.
///
/// Only that scope pauses.
///
/// A struct, not an enum: the server may add scopes in a minor version, and existing code keeps compiling.
public struct RateScope: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The scope as sent by the server.
    public let rawValue: String
    /// Wraps a raw scope.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// The raw scope.
    public var description: String { rawValue }

    /// Sending messages.
    public static let messages = RateScope(rawValue: Known.messages.rawValue)
    /// Photo and screenshot uploads.
    public static let uploads = RateScope(rawValue: Known.uploads.rawValue)
    /// Creating or refreshing sessions.
    public static let sessions = RateScope(rawValue: Known.sessions.rawValue)
    /// Reporting moments.
    public static let moments = RateScope(rawValue: Known.moments.rawValue)
    /// The live socket.
    public static let live = RateScope(rawValue: Known.live.rawValue)
    /// The protocol's `RateScope` names.
    private enum Known: String { case messages, uploads, sessions, moments, live, offers, exports }
    /// Promotional offer signatures.
    public static let offers = RateScope(rawValue: Known.offers.rawValue)
    /// The person's data export (`exportMyData()`): 5 an hour per install.
    public static let exports = RateScope(rawValue: Known.exports.rawValue)
    /// The scopes this SDK version knows.
    public static let known: [RateScope] = [.messages, .uploads, .sessions, .moments, .live, .offers, .exports]
}

/// An error returned by the pingfront API.
public struct ServerError: Sendable, Equatable {
    /// HTTP status.
    public let status: Int
    /// Machine-readable code.
    public let code: ErrorCode
    /// Human-readable explanation from the server.
    public let message: String
    /// The docs page that explains the fix.
    public let docs: URL?
    /// How long to wait before retrying, when the server says.
    public let retryAfter: Duration?
    /// For 429s: which part of the API is paused.
    public let scope: RateScope?
    /// For 422s: the fields that failed, as dotted paths ("identity.email").
    public var fields: [String] = []

    /// Creates a server error (fixtures and tests; apps receive these from the SDK).
    @_spi(Fixtures) public init(
        status: Int, code: ErrorCode, message: String, docs: URL? = nil, retryAfter: Duration? = nil, scope: RateScope? = nil,
        fields: [String] = []
    ) {
        self.status = status
        self.code = code
        self.message = message
        self.docs = docs
        self.retryAfter = retryAfter
        self.scope = scope
        self.fields = fields
    }
}

/// Every error the SDK surfaces.
///
/// The SDK's APIs throw only this type (typed throws). It may gain cases in a minor release: switch over it with
/// `@unknown default`.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum PingFrontError: Error, Sendable, Equatable {
    /// `PingFront.configure` was not called yet.
    case notConfigured
    /// The app key failed the offline check.
    case invalidKey(KeyProblem)
    /// The server answered with an error envelope.
    case server(ServerError)
    /// The request did not reach the server.
    case network(URLError.Code)
    /// A rate limit is active for `scope`; try again after `remaining`.
    case coolingDown(scope: RateScope, remaining: Duration)
    /// The server answered with something the SDK could not read. The associated text describes the
    /// decoding failure for debugging; it is never shown to people.
    case invalidResponse(String)
    /// The device has not been unlocked since it restarted, so the Keychain and protected files are
    /// unreadable. The SDK tries again once protected data becomes available.
    case protectedDataUnavailable
    /// The input was rejected before sending (for example an empty message).
    case invalidInput(String)
    /// The operation was cancelled.
    case cancelled

    /// The server error code, when there is one.
    public var code: ErrorCode? {
        if case .server(let error) = self { return error.code }
        return nil
    }

    /// True for failures that a later retry can fix without changing the request: no answer, a rate limit, a 408 or
    /// a 5xx.
    ///
    /// A 401 is not: the client already refreshed the session once and retried, so a second 401 is final. Nor is a 409
    /// `thread_reset`, which reloads the thread and retries once, not with a backoff.
    public var isTransient: Bool {
        switch self {
        case .network, .coolingDown: true
        case .server(let error): error.status >= 500 || error.status == 408 || error.code == .rateLimited
        default: false
        }
    }

    /// A description that is safe to log publicly by construction: the case, the HTTP status, the error
    /// code, the rate scope and the docs anchor.
    ///
    /// Never the server message, URLs, ids or user input.
    public var logDescription: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .invalidKey(let problem): return "invalid_key(\(problem.rawValue))"
        case .protectedDataUnavailable: return "protected_data_unavailable"
        case .server(let error):
            var parts = ["server", String(error.status), Self.token(error.code.rawValue)]
            if let scope = error.scope { parts.append("scope=\(scope.rawValue)") }
            if let anchor = error.docs?.fragment { parts.append("docs=#\(Self.token(anchor))") }
            if !error.fields.isEmpty { parts.append("fields=\(error.fields.count)") }
            return parts.joined(separator: " ")
        case .network(let code): return "network \(code.rawValue)"
        case .coolingDown(let scope, let remaining): return "cooling_down \(scope.rawValue) \(remaining.components.seconds)s"
        case .invalidResponse: return "invalid_response"
        case .invalidInput: return "invalid_input"
        case .cancelled: return "cancelled"
        }
    }

    /// Keeps only `[a-z0-9_]`, at most 40 characters: server-sent codes stay recognizable but can carry nothing else.
    private static func token(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        let kept = String(raw.lowercased().filter { allowed.contains($0) }.prefix(40))
        return kept.isEmpty ? "unknown" : kept
    }

    /// True when the device has a network but could not reach the service: the host could not be found or would not
    /// accept the connection (the service is down, a firewall, a captive portal).
    ///
    /// No network at all (`notConnectedToInternet`, data or roaming off) is offline, not this; a timeout or a dropped
    /// connection says nothing about which. Part of `isOffline`.
    public var isServerUnreachable: Bool {
        guard case .network(let code) = self else { return false }
        return [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(code)
    }

    /// True when the device appears to be offline.
    public var isOffline: Bool {
        guard case .network(let code) = self else { return false }
        return [
            .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .timedOut,
        ].contains(code)
    }
}

/// The wire envelope: `{ "error": { code, message, docs, retryAfter?, scope? } }`.
package struct ErrorEnvelope: Decodable, Sendable {
    package struct Body: Decodable, Sendable {
        package let code: ErrorCode
        package let message: String
        package let docs: String?
        package let retryAfter: Double?
        package let scope: String?
        package let fields: [Field]?
        package struct Field: Decodable, Sendable { package let path: String }
    }
    package let error: Body

    /// Builds a `ServerError` from a response body, falling back to the HTTP status when the body is not an envelope.
    package static func serverError(status: Int, data: Data, retryAfterHeader: String?) -> ServerError {
        let header = retryAfterHeader.flatMap(Double.init).map { Duration.milliseconds(Int64($0 * 1000)) }
        if let envelope = try? WireJSON.decode(ErrorEnvelope.self, from: data) {
            let body = envelope.error
            return ServerError(
                status: status,
                code: body.code,
                message: body.message,
                docs: body.docs.flatMap(URL.init(string:)),
                retryAfter: body.retryAfter.map { Duration.milliseconds(Int64($0 * 1000)) } ?? header,
                scope: body.scope.flatMap(RateScope.init(rawValue:)),
                fields: body.fields?.map(\.path) ?? []
            )
        }
        let code: ErrorCode =
            switch status {
            case 401: .unauthorized
            case 404: .notFound
            case 413: .tooLarge
            case 429: .rateLimited
            case 500...: .unavailable
            default: .invalidRequest
            }
        return ServerError(
            status: status, code: code, message: HTTPURLResponse.localizedString(forStatusCode: status), docs: nil, retryAfter: header,
            scope: nil)
    }
}

extension PingFrontError: LocalizedError {
    /// A developer-facing sentence (English).
    ///
    /// Show your own copy to people.
    public var errorDescription: String? {
        switch self {
        case .notConfigured: "pingfront is not configured. Call PingFront.configure first."
        case .invalidKey(let problem): "The pingfront app key is not valid (\(problem.rawValue))."
        case .server(let error): "The pingfront API answered \(error.status) \(error.code.rawValue)."
        case .network(let code): "The request did not reach pingfront (URLError \(code.rawValue))."
        case .coolingDown(let scope, let remaining): "pingfront paused \(scope.rawValue) for \(remaining.components.seconds) s."
        case .invalidResponse: "pingfront answered with something this SDK version cannot read."
        case .invalidInput(let reason): reason
        case .protectedDataUnavailable: "The device is locked; pingfront tries again after it is unlocked."
        case .cancelled: "The pingfront operation was cancelled."
        }
    }

    /// The server's explanation, when there is one.
    public var failureReason: String? {
        if case .server(let error) = self { return error.message }
        return nil
    }

    /// Where to read about the fix.
    public var recoverySuggestion: String? {
        if case .server(let error) = self, let docs = error.docs { return "See \(docs.absoluteString)" }
        return nil
    }
}
