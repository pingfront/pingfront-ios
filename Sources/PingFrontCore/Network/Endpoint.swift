package import Foundation

/// One HTTP route of the pingfront API, typed by its response.
///
/// Built only by `Endpoints`; sent only by
/// `APIClient.send(_:)`, which applies headers, auth, cooldowns, the 401 refresh and decoding.
package struct Endpoint<Response: Decodable & Sendable>: Sendable {
    /// HTTP methods the API uses.
    package enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case put = "PUT"
        case delete = "DELETE"
    }

    /// How a request authenticates.
    package enum Auth: Sendable, Equatable {
        /// `PF-App-Key` only (sessions, logout and erase carry the install secret in the body).
        case appKeyOnly
        /// `PF-App-Key` plus `Authorization: Bearer`; a 401 `unauthorized` refreshes and retries once.
        case bearer
    }

    package let method: Method
    /// The path below the base URL.
    ///
    /// Path parameters are percent-encoded by the factory.
    package let path: String
    package let query: [URLQueryItem]
    package let body: (any Encodable & Sendable)?
    package let auth: Auth
    /// Safe to send again after a lost response (the server deduplicates or the call has no effect).
    package let idempotent: Bool
    /// The cooldown that applies; a 429 pauses only this scope.
    package let rateScope: RateScope?
    /// The route answers 304 to `If-None-Match` (`/config`).
    package let acceptsNotModified: Bool

    package init(
        _ method: Method,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        auth: Auth,
        idempotent: Bool,
        rateScope: RateScope? = nil,
        acceptsNotModified: Bool = false
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.auth = auth
        self.idempotent = idempotent
        self.rateScope = rateScope
        self.acceptsNotModified = acceptsNotModified
    }

    /// `/thread*` routes carry `PF-Thread-Rev` once a thread exists.
    package var isThreadRoute: Bool { path == "thread" || path.hasPrefix("thread/") }
}

/// The response type of routes that answer 204.
package struct NoContent: Decodable, Sendable, Equatable {
    package init() {}
}

/// The result of a conditional GET (`If-None-Match`).
package enum Conditional<Response: Sendable>: Sendable {
    /// 304: the cached copy is current.
    case notModified
    /// 200 with the decoded body, its raw bytes (for the disk cache) and the new ETag.
    case fresh(Response, body: Data, etag: String?)
}

/// A presigned upload target from `POST /uploads`: `PUT` the bytes with exactly these headers.
package struct UploadTarget: Sendable, Equatable {
    package let url: URL
    package let headers: [String: String]

    package init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    package init(_ response: CreateUploadResponse) {
        self.init(url: response.putUrl, headers: response.headers)
    }
}

/// The live WebSocket (`GET /live`): subprotocols `pingfront.v1` and `bearer.<token>`.
package struct LiveEndpoint: Sendable, Equatable {
    package let url: URL

    package init(url: URL) { self.url = url }

    /// The subprotocols that authenticate the socket.
    package func protocols(token: String) -> [String] { [LiveProtocol.subprotocol, "bearer.\(token)"] }
}
