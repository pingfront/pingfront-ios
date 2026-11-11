import Foundation

/// Supplies access tokens for `.bearer` endpoints.
///
/// Implemented by `SessionStore`.
package protocol Authenticator: Actor {
    /// A valid access token, creating or refreshing the session if needed.
    func token(reason: SessionReason) async throws(PingFrontError) -> String
    /// Drops `token` after a 401 so the next `token(reason:)` refreshes.
    func invalidate(token: String) async
}

/// `APIClient` plus bearer auth: gets the token, sends, and on a 401 `unauthorized` refreshes once and
/// retries once, for every bearer route.
///
/// Key-only routes pass straight through.
package struct AuthorizedClient: Sendable {
    package let api: APIClient
    package let authenticator: any Authenticator

    package init(api: APIClient, authenticator: any Authenticator) {
        self.api = api
        self.authenticator = authenticator
    }

    /// Sends `endpoint`. `reason` is reported if the request has to create the session.
    package func send<Response>(_ endpoint: Endpoint<Response>, reason: SessionReason = .chatOpened) async throws(PingFrontError)
        -> Response
    {
        guard endpoint.auth == .bearer else { return try await api.send(endpoint) }
        let token = try await authenticator.token(reason: reason)
        do {
            return try await api.send(endpoint, token: token)
        } catch  where error.code == .unauthorized {
            await authenticator.invalidate(token: token)
            return try await api.send(endpoint, token: try await authenticator.token(reason: reason))
        }
    }

    /// A conditional GET (`/config`), with the same auth rules.
    package func send<Response>(_ endpoint: Endpoint<Response>, ifNoneMatch etag: String?, reason: SessionReason = .chatOpened)
        async throws(PingFrontError) -> Conditional<Response>
    {
        guard endpoint.auth == .bearer else { return try await api.send(endpoint, ifNoneMatch: etag) }
        let token = try await authenticator.token(reason: reason)
        do {
            return try await api.send(endpoint, token: token, ifNoneMatch: etag)
        } catch  where error.code == .unauthorized {
            await authenticator.invalidate(token: token)
            return try await api.send(endpoint, token: try await authenticator.token(reason: reason), ifNoneMatch: etag)
        }
    }
}
