package import Foundation
internal import os

/// SDK version reported in `Device.sdk` and the `PF-SDK` header.
public enum PingFrontVersion {
    /// The SDK version.
    public static let current = "1.0.0"
    /// The SDK name sent to the server.
    public static let name = "pingfront-ios"
    /// The wire protocol this SDK speaks (`PF-Protocol`).
    public static let protocolVersion = "1.0.0"
}

/// The thread revision (`thread.rev` from `ThreadResponse`, `hello` or a response's `PF-Thread-Rev`), sent as `PF-Thread-Rev` on `/thread*` calls.
package actor ThreadRevision {
    package private(set) var value: Int?
    package init() {}
    package func set(_ revision: Int?) { value = revision }
}

/// Sends typed `Endpoint`s over the transport: `PF-App-Key`, `PF-SDK`, `PF-Protocol`, `PF-Thread-Rev`,
/// scoped cooldowns, one resend of idempotent requests after a dropped connection, and the error envelope.
///
/// It holds no token: `AuthorizedClient` adds bearer auth and the 401 refresh on top. Stateless apart
/// from the shared actors, so it is a Sendable value.
package struct APIClient: Sendable {
    package let baseURL: URL
    package let appKey: String
    package let transport: any Transport
    package let cooldowns: CooldownBook
    /// `thread.rev`, echoed as `PF-Thread-Rev` on `/thread*` calls.
    package let threadRevision: ThreadRevision
    /// Logs every request path and status (`config.logLevel = .debug`).
    ///
    /// Never logs bodies or tokens.
    package let verbose: Bool
    /// `PF-Wrapper`, when a React Native or Flutter bridge configured the SDK.
    package let wrapper: String?

    package init(
        baseURL: URL,
        appKey: String,
        transport: any Transport,
        cooldowns: CooldownBook,
        verbose: Bool = false,
        threadRevision: ThreadRevision = ThreadRevision(),
        wrapper: PingFrontWrapper? = nil
    ) {
        self.wrapper = wrapper?.headerValue
        self.baseURL = baseURL
        self.appKey = appKey
        self.transport = transport
        self.cooldowns = cooldowns
        self.verbose = verbose
        self.threadRevision = threadRevision
    }

    /// Sends an endpoint and decodes its response.
    ///
    /// Bearer endpoints need `token` (use `AuthorizedClient`).
    ///
    /// `@concurrent`: encoding, the request and decoding never run on the caller's actor (often main).
    @concurrent package func send<Response>(_ endpoint: Endpoint<Response>, token: String? = nil) async throws(PingFrontError) -> Response {
        let reply = try await exchange(endpoint, token: token, etag: nil)
        return try decode(endpoint, reply.data)
    }

    /// A conditional GET for routes that support ETags (`/config`).
    @concurrent package func send<Response>(
        _ endpoint: Endpoint<Response>,
        token: String? = nil,
        ifNoneMatch etag: String?
    ) async throws(PingFrontError) -> Conditional<Response> {
        let reply = try await exchange(endpoint, token: token, etag: endpoint.acceptsNotModified ? etag : nil)
        if reply.status == 304 { return .notModified }
        return .fresh(try decode(endpoint, reply.data), body: reply.data, etag: reply.etag)
    }

    /// `PUT` raw bytes to a presigned target with the server's headers, exactly (no pingfront headers).
    @concurrent package func upload(_ data: Data, to target: UploadTarget) async throws(PingFrontError) {
        var request = URLRequest(url: target.url)
        request.httpMethod = Endpoint<NoContent>.Method.put.rawValue
        for (key, value) in target.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = data
        let (body, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw .server(ErrorEnvelope.serverError(status: response.statusCode, data: body, retryAfterHeader: nil))
        }
    }

    /// The live socket endpoint: `liveUrl` from config, or the base URL with a ws scheme.
    package func liveEndpoint(override: URL?) -> LiveEndpoint {
        Endpoints.live(baseURL: baseURL, override: override)
    }

    /// Opens the live socket with the bearer subprotocol.
    package func openLive(_ endpoint: LiveEndpoint, token: String) async throws -> any WebSocketConnection {
        try await transport.webSocket(url: endpoint.url, protocols: endpoint.protocols(token: token))
    }

    // MARK: Internals

    private struct Reply: Sendable {
        let status: Int
        let data: Data
        let etag: String?
    }

    private func decode<Response>(_ endpoint: Endpoint<Response>, _ data: Data) throws(PingFrontError) -> Response {
        if let empty = NoContent() as? Response { return empty }
        // Raw-body routes (`GET /me/export`): the bytes are the result.
        if Response.self == Data.self, let raw = data as? Response { return raw }
        do {
            return try WireJSON.decode(Response.self, from: data)
        } catch {
            Log.network(.error)?.error("Could not decode \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .private)")
            throw .invalidResponse("Unexpected response from the server")
        }
    }

    /// Cooldown check, then the request; an idempotent request is sent once more after a dropped connection.
    private func exchange<Response>(_ endpoint: Endpoint<Response>, token: String?, etag: String?) async throws(PingFrontError) -> Reply {
        if let scope = endpoint.rateScope, let remaining = await cooldowns.remaining(scope) {
            throw .coolingDown(scope: scope, remaining: remaining)
        }
        guard endpoint.auth == .appKeyOnly || token != nil else {
            throw .invalidInput("A bearer endpoint was sent without a token.")
        }
        do {
            return try await attempt(endpoint, token: token, etag: etag)
        } catch  where endpoint.idempotent && Self.droppedConnection(error) {
            return try await attempt(endpoint, token: token, etag: etag)
        }
    }

    private static func droppedConnection(_ error: PingFrontError) -> Bool {
        if case .network(let code) = error { return code == .networkConnectionLost }
        return false
    }

    private func attempt<Response>(_ endpoint: Endpoint<Response>, token: String?, etag: String?) async throws(PingFrontError) -> Reply {
        let request = try await makeRequest(endpoint, token: token, etag: etag)
        let (data, response) = try await perform(request)
        let status = response.statusCode
        if verbose {
            Log.network(.debug)?.debug(
                "\(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .private) -> \(status, privacy: .public)")
        }
        if (200..<300).contains(status) || (status == 304 && endpoint.acceptsNotModified) {
            return Reply(status: status, data: data, etag: response.value(forHTTPHeaderField: HTTPHeader.eTag))
        }
        let error = ErrorEnvelope.serverError(
            status: status, data: data, retryAfterHeader: response.value(forHTTPHeaderField: HTTPHeader.retryAfter))
        if status == 429 {
            await cooldowns.record(scope: error.scope ?? endpoint.rateScope ?? .messages, retryAfter: error.retryAfter)
        }
        Log.network(.info)?.info(
            "\(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .private) failed: \(PingFrontError.server(error).logDescription, privacy: .public)"
        )
        throw .server(error)
    }

    package func makeRequest<Response>(_ endpoint: Endpoint<Response>, token: String?, etag: String? = nil) async throws(PingFrontError)
        -> URLRequest
    {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw .invalidInput("The base URL is not valid.")
        }
        let basePath =
            components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/" + endpoint.path
        if !endpoint.query.isEmpty { components.queryItems = endpoint.query }
        guard let url = components.url else { throw .invalidInput("The request URL is not valid.") }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue(appKey, forHTTPHeaderField: HTTPHeader.appKey)
        request.setValue("\(PingFrontVersion.name)/\(PingFrontVersion.current)", forHTTPHeaderField: HTTPHeader.sdk)
        request.setValue(PingFrontVersion.protocolVersion, forHTTPHeaderField: HTTPHeader.protocolVersion)
        if let wrapper { request.setValue(wrapper, forHTTPHeaderField: HTTPHeader.wrapper) }
        request.setValue("\(PingFrontVersion.name)/\(PingFrontVersion.current)", forHTTPHeaderField: HTTPHeader.userAgent)
        request.setValue(HTTPHeader.json, forHTTPHeaderField: HTTPHeader.accept)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: HTTPHeader.authorization) }
        if endpoint.isThreadRoute, let revision = await threadRevision.value {
            request.setValue(String(revision), forHTTPHeaderField: HTTPHeader.threadRevision)
        }
        if let etag { request.setValue(etag, forHTTPHeaderField: HTTPHeader.ifNoneMatch) }
        if let body = endpoint.body {
            request.setValue(HTTPHeader.json, forHTTPHeaderField: HTTPHeader.contentType)
            do { request.httpBody = try WireJSON.encode(body) } catch { throw .invalidInput("Could not encode the request.") }
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws(PingFrontError) -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.data(for: request)
            // The first send creates the thread; its revision arrives only in this header.
            if let header = response.value(forHTTPHeaderField: HTTPHeader.threadRevision), let revision = Int(header) {
                await threadRevision.set(revision)
            }
            return (data, response)
        } catch is CancellationError {
            throw .cancelled
        } catch let error as URLError {
            throw error.code == .cancelled ? .cancelled : .network(error.code)
        } catch {
            throw .network(.unknown)
        }
    }
}
