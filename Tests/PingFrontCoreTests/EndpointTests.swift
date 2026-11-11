import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore

/// The typed endpoint layer, checked against the protocol's endpoint table (the SDK routes).
@Suite("Endpoints")
struct EndpointTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let method: String
        let path: String
        let query: [String: String]
        let auth: Endpoint<NoContent>.Auth
        let idempotent: Bool
        let scope: RateScope?
        var testDescription: String { "\(method) /\(path) (\(name))" }
    }

    static let credentials = InstallCredentials(installId: "00000000-0000-4000-8000-000000000000", installSecret: "s")
    static let send = SendMessageRequest(clientId: "c", text: "hi", attachmentIds: nil, replyToCard: nil)

    /// One row per SDK route of the protocol.
    ///
    /// A drifted path, method or auth fails here.
    static let table: [(Row, AnyEndpoint)] = [
        (
            Row(
                name: "createSession", method: "POST", path: "sessions", query: [:], auth: .appKeyOnly, idempotent: false, scope: .sessions),
            AnyEndpoint(Endpoints.createSession(CreateSessionRequest(device: DeviceInfo.current(installId: "i"), reason: .prepare)))
        ),
        (
            Row(
                name: "refreshSession", method: "POST", path: "sessions/refresh", query: [:], auth: .appKeyOnly, idempotent: true,
                scope: .sessions),
            AnyEndpoint(Endpoints.refreshSession(RefreshSessionRequest(installId: "i", installSecret: "s")))
        ),
        (
            Row(name: "updateMe", method: "PATCH", path: "me", query: [:], auth: .bearer, idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.updateMe(UpdateMeRequest()))
        ),
        (
            Row(name: "logout", method: "POST", path: "me/logout", query: [:], auth: .appKeyOnly, idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.logout(credentials))
        ),
        (
            Row(name: "eraseMe", method: "DELETE", path: "me", query: [:], auth: .appKeyOnly, idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.eraseMe(credentials))
        ),
        (
            Row(name: "exportMe", method: "GET", path: "me/export", query: [:], auth: .bearer, idempotent: true, scope: .exports),
            AnyEndpoint(Endpoints.exportMe())
        ),
        (
            Row(name: "config", method: "GET", path: "config", query: [:], auth: .appKeyOnly, idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.config(draft: false))
        ),
        (
            Row(name: "config draft", method: "GET", path: "config", query: ["draft": "1"], auth: .bearer, idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.config(draft: true))
        ),
        (
            Row(name: "thread", method: "GET", path: "thread", query: [:], auth: .bearer, idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.thread())
        ),
        (
            Row(
                name: "messages", method: "GET", path: "thread/messages", query: ["before": "9"], auth: .bearer,
                idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.messages(before: 9, limit: 50))
        ),
        (
            Row(
                name: "messages after", method: "GET", path: "thread/messages", query: ["after": "3", "limit": "200"], auth: .bearer,
                idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.messages(after: 3, limit: 200))
        ),
        (
            Row(
                name: "sendMessage", method: "POST", path: "thread/messages", query: [:], auth: .bearer, idempotent: true, scope: .messages),
            AnyEndpoint(Endpoints.sendMessage(send))
        ),
        (
            Row(name: "read", method: "POST", path: "thread/read", query: [:], auth: .bearer, idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.read(upTo: 4))
        ),
        (
            Row(
                name: "cardAction", method: "POST", path: "thread/cards/crd_1/act", query: [:], auth: .bearer, idempotent: false, scope: nil
            ),
            AnyEndpoint(
                Endpoints.cardAction(cardId: "crd_1", CardActionRequest(messageId: "m", action: .opened)))
        ),
        (
            Row(name: "unread", method: "GET", path: "unread", query: [:], auth: .bearer, idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.unread())
        ),
        (
            Row(name: "createUpload", method: "POST", path: "uploads", query: [:], auth: .bearer, idempotent: true, scope: .uploads),
            AnyEndpoint(
                Endpoints.createUpload(
                    CreateUploadRequest(requestId: "r", contentType: "image/jpeg", bytes: 1, width: 1, height: 1, sha256: "x")))
        ),
        (
            Row(name: "attachment", method: "GET", path: "attachments/att_1", query: [:], auth: .bearer, idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.attachment(id: "att_1"))
        ),
        (
            Row(name: "report", method: "POST", path: "reports", query: [:], auth: .bearer, idempotent: true, scope: .messages),
            AnyEndpoint(Endpoints.report(CreateReportRequest(clientId: "c", text: "t", screenshotIds: [], logTail: nil, state: nil)))
        ),
        (
            Row(
                name: "listenedMoments", method: "GET", path: "moments/listened", query: [:], auth: .appKeyOnly, idempotent: true,
                scope: .moments),
            AnyEndpoint(Endpoints.listenedMoments())
        ),
        (
            Row(name: "signOffer", method: "POST", path: "offers/signature", query: [:], auth: .bearer, idempotent: true, scope: .offers),
            AnyEndpoint(Endpoints.signOffer(OfferSignatureRequest(productId: "p", offerId: "o")))
        ),
        (
            Row(name: "moment", method: "POST", path: "moments", query: [:], auth: .bearer, idempotent: true, scope: .moments),
            AnyEndpoint(Endpoints.moment(MomentRequest(name: "x", clientId: "c")))
        ),
        (
            Row(name: "teamActions", method: "GET", path: "team-actions", query: [:], auth: .bearer, idempotent: true, scope: nil),
            AnyEndpoint(Endpoints.teamActions())
        ),
        (
            Row(
                name: "ackTeamAction", method: "POST", path: "team-actions/att_1/ack", query: [:], auth: .bearer, idempotent: true,
                scope: nil),
            AnyEndpoint(Endpoints.ackTeamAction(id: "att_1", TeamActionAck(ok: true)))
        ),
        (
            Row(
                name: "reportStoreAction", method: "POST", path: "store-actions", query: [:], auth: .bearer, idempotent: true,
                scope: .messages),
            AnyEndpoint(
                Endpoints.reportStoreAction(StoreActionResultRequest(clientId: "c", action: "request_refund", result: "refund_requested")))
        ),
    ]

    @Test("Every factory matches the protocol's endpoint table", arguments: table.map(\.0.name))
    func matchesProtocolTable(name: String) async throws {
        let (row, endpoint) = try #require(Self.table.first { $0.0.name == name })
        #expect(endpoint.method == row.method)
        #expect(endpoint.path == row.path)
        #expect(endpoint.query == row.query)
        #expect(endpoint.auth == row.auth)
        #expect(endpoint.idempotent == row.idempotent)
        #expect(endpoint.scope == row.scope)
    }

    @Test(
        "Every route in the protocol's endpoint table has a factory",
        .enabled(if: TestPaths.protocolDoc != nil, "the endpoint table is not beside this package"))
    func coversProtocol() throws {
        let doc = try String(contentsOf: try #require(TestPaths.protocolDoc), encoding: .utf8)
        // Only the SDK table: from its heading to the next heading.
        let lines = doc.split(separator: "\n", omittingEmptySubsequences: false)
        let start = try #require(lines.firstIndex { $0.hasPrefix("### SDK") })
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.endIndex
        let routes = lines[start..<end].compactMap { line -> String? in
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3, ["GET", "POST", "PATCH", "PUT", "DELETE"].contains(cells[0]), cells[1].hasPrefix("`/") else {
                return nil
            }
            var path = String(cells[1].dropFirst(2).prefix { $0 != "`" && $0 != "?" })
            path = path.replacingOccurrences(of: "{cardId}", with: "crd_1").replacingOccurrences(of: "{id}", with: "att_1")
            return "\(cells[0]) \(path)"
        }
        // Not factories: the socket (LiveEndpoint), the attachment bytes (a signed URL from GET /attachments/{id}) and
        // teammate photos (TeamMember.avatarURL, loaded as images).
        let elsewhere: Set = ["GET live", "GET attachments/att_1/blob", "GET avatars/att_1"]
        #expect(routes.count >= 17)
        let covered = Set(Self.table.map { "\($0.1.method) \($0.1.path)" }).union(elsewhere)
        for route in routes { #expect(covered.contains(route), "No Endpoints factory for \(route)") }
    }

    @Test("Path parameters are percent-encoded inside the factories")
    func pathEncoding() {
        #expect(Endpoints.attachment(id: "a/b?c").path == "attachments/a%2Fb%3Fc")
        #expect(
            Endpoints.cardAction(cardId: "x y", CardActionRequest(messageId: "m", action: .opened)).path
                == "thread/cards/x%20y/act")
    }

    @Test("No source file outside Network/ spells a request path or calls a raw send")
    func noRawPathsOutsideNetwork() throws {
        let sources = TestPaths.package.appending(path: "Sources")
        let pathLiteral = try Regex(#""(sessions|me|thread|uploads|reports|moments|config|unread|attachments)(/[^"]*)?""#)
        let rawSend = try Regex(#"api\.send(Raw)?\("(GET|POST|PATCH|PUT|DELETE)""#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" && !file.path.contains("/PingFrontCore/Network/") {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() where line.contains(pathLiteral) || line.contains(rawSend) {
                offenders.append("\(file.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "Paths belong in Network/Endpoints.swift:\n\(offenders.joined(separator: "\n"))")
    }
}

/// Type-erased view of an endpoint for the table.
struct AnyEndpoint: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let auth: Endpoint<NoContent>.Auth
    let idempotent: Bool
    let scope: RateScope?

    init<R>(_ endpoint: Endpoint<R>) {
        method = endpoint.method.rawValue
        path = endpoint.path
        query = Dictionary(endpoint.query.map { ($0.name, $0.value ?? "") }) { $1 }
        auth = endpoint.auth == .bearer ? .bearer : .appKeyOnly
        idempotent = endpoint.idempotent
        scope = endpoint.rateScope
    }
}

@Suite("Log privacy")
struct LogPrivacyTests {
    @Test("logDescription keeps code, status, scope and docs anchor, never the message or URLs")
    func safeByConstruction() {
        let secret = "Email ada@example.com is taken, see https://evil.test/?token=abc"
        let error = PingFrontError.server(
            ServerError(
                status: 429, code: .rateLimited, message: secret, docs: URL(string: "https://pingfront.sh/docs/errors#rate_limited"),
                retryAfter: .seconds(3), scope: .uploads, fields: ["identity.email"]))
        let text = error.logDescription
        #expect(text == "server 429 rate_limited scope=uploads docs=#rate_limited fields=1")
        #expect(!text.contains("ada@") && !text.contains("http") && !text.contains("token"))

        let hostile = PingFrontError.server(
            ServerError(
                status: 400, code: ErrorCode(rawValue: "https://x.test/?q=Ada Lovelace"), message: secret,
                docs: URL(string: "https://x.test/#a%20b/c"),
                retryAfter: nil, scope: nil))
        #expect(!hostile.logDescription.contains("://") && !hostile.logDescription.contains(" Ada"))
        #expect(PingFrontError.invalidInput(secret).logDescription == "invalid_input")
        #expect(PingFrontError.invalidResponse(secret).logDescription == "invalid_response")
        #expect(PingFrontError.protectedDataUnavailable.logDescription == "protected_data_unavailable")
        #expect(PingFrontError.network(.timedOut).logDescription == "network -1001")
    }
}
