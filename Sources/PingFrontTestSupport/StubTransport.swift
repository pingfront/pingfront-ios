package import Foundation
package import PingFrontCore

/// A recorded HTTP request.
struct RecordedRequest: Sendable {
    let method: String
    /// Path relative to the base URL, for example `sessions/refresh`.
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data?

    /// The JSON body as a dictionary.
    var json: [String: Any]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    var bodyString: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
}

/// A scripted reply.
enum StubReply: Sendable {
    case json(Int, String, headers: [String: String] = [:])
    case failure(URLError.Code)
    case delayed(Duration, StubReplyBox)

    static func ok(_ body: String) -> StubReply { .json(200, body) }
    static var noContent: StubReply { .json(204, "") }
}

/// Indirection so `StubReply` can nest.
final class StubReplyBox: Sendable {
    let reply: StubReply
    init(_ reply: StubReply) { self.reply = reply }
}

/// Scripted routes and a request log.
actor StubServer {
    private var routes: [String: [StubReply]] = [:]
    private(set) var requests: [RecordedRequest] = []

    /// Queues replies for `"METHOD path"`.
    ///
    /// The last reply repeats when the queue runs out.
    func on(_ route: String, _ replies: StubReply...) {
        routes[route, default: []].append(contentsOf: replies)
    }

    func requests(_ route: String) -> [RecordedRequest] {
        requests.filter { "\($0.method) \($0.path)" == route }
    }

    fileprivate func record(_ request: RecordedRequest) -> StubReply {
        requests.append(request)
        let key = "\(request.method) \(request.path)"
        guard var queue = routes[key], !queue.isEmpty else {
            return .json(404, #"{"error":{"code":"not_found","message":"No stub for \#(key)","docs":"x"}}"#)
        }
        let reply = queue.count > 1 ? queue.removeFirst() : queue[0]
        routes[key] = queue
        return reply
    }
}

/// A `Transport` backed by a `StubServer`.
///
/// No network.
struct StubTransport: Transport {
    static let base: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.test"
        components.path = "/v1"
        return components.url ?? URL(filePath: "/")
    }()
    let server: StubServer

    init(server: StubServer = StubServer()) { self.server = server }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let basePath = Self.base.path()
        var path = url.path()
        if path.hasPrefix(basePath) { path.removeFirst(basePath.count) }
        if path.hasPrefix("/") { path.removeFirst() }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET", path: path, query: query, headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody)
        var reply = await server.record(recorded)
        while true {
            switch reply {
            case .delayed(let delay, let box):
                try await Task.sleep(for: delay)
                reply = box.reply
            case .json(let status, let body, let headers):
                var all = headers
                all["Content-Type"] = "application/json"
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: all) else {
                    throw URLError(.badServerResponse)
                }
                return (Data(body.utf8), response)
            case .failure(let code):
                throw URLError(code)
            }
        }
    }

    func webSocket(url: URL, protocols: [String]) async throws -> any WebSocketConnection {
        throw URLError(.unsupportedURL)
    }
}

/// Builders for common wire JSON.
enum Wire {
    static func session(
        token: String = "tok_1", secret: String = "sec_1", testDevice: Bool = false, installId: String? = nil,
        expiresIn: Int? = nil, expiresAt: String = "2099-01-01T00:00:00Z", storeAccountToken: String? = nil
    ) -> String {
        var extra = ""
        if let installId { extra += #","installId":"\#(installId)""# }
        if let expiresIn { extra += #","accessExpiresIn":\#(expiresIn)"# }
        if let storeAccountToken { extra += #","storeAccountToken":"\#(storeAccountToken)""# }
        return
            #"{"accessToken":"\#(token)","accessExpiresAt":"\#(expiresAt)","installSecret":"\#(secret)","person":{"id":"per_1","level":"guest"},"testDevice":\#(testDevice)\#(extra)}"#
    }

    static func refresh(token: String = "tok_r", testDevice: Bool = false, expiresIn: Int? = nil) -> String {
        let extra = expiresIn.map { #","accessExpiresIn":\#($0)"# } ?? ""
        return
            #"{"accessToken":"\#(token)","accessExpiresAt":"2099-01-01T00:00:00Z","person":{"id":"per_1","level":"named","name":"Ada"},"testDevice":\#(testDevice)\#(extra)}"#
    }

    static func error(_ code: String, retryAfter: Double? = nil, scope: String? = nil) -> String {
        var fields = [#""code":"\#(code)""#, #""message":"\#(code) happened""#, #""docs":"https://pingfront.sh/docs/errors#\#(code)""#]
        if let retryAfter { fields.append(#""retryAfter":\#(retryAfter)"#) }
        if let scope { fields.append(#""scope":"\#(scope)""#) }
        return #"{"error":{\#(fields.joined(separator: ","))}}"#
    }

    static func message(id: String = "msg_1", seq: Int = 1, clientId: String? = nil, text: String = "Hi") -> String {
        let client = clientId.map { #","clientId":"\#($0)""# } ?? ""
        return
            #"{"message":{"id":"\#(id)","seq":\#(seq)\#(client),"author":{"kind":"person"},"parts":[{"type":"text","text":"\#(text)"}],"createdAt":"2026-10-30T18:00:00Z"},"threadId":"thr_1"}"#
    }
}

/// An authenticator that hands out a fixed token (or a sequence) and records invalidations.
actor FixedToken: Authenticator {
    private var tokens: [String]
    private(set) var invalidated: [String] = []
    private(set) var reasons: [SessionReason] = []

    nonisolated let api: APIClient
    /// The client that authenticates with this token source.
    nonisolated var client: AuthorizedClient { AuthorizedClient(api: api, authenticator: self) }

    init(_ api: APIClient, token: String = "tok", then more: [String] = []) {
        tokens = [token] + more
        self.api = api
    }

    func token(reason: SessionReason) async throws(PingFrontError) -> String {
        reasons.append(reason)
        return tokens[0]
    }

    func invalidate(token: String) async {
        invalidated.append(token)
        if tokens.count > 1, tokens[0] == token { tokens.removeFirst() }
    }
}
