package import Foundation

/// Every SDK route of the protocol, one factory each, named after the route.
///
/// The only place paths are spelled.
package enum Endpoints {
    /// `POST /sessions`.
    package static func createSession(_ request: CreateSessionRequest) -> Endpoint<CreateSessionResponse> {
        Endpoint(.post, "sessions", body: request, auth: .appKeyOnly, idempotent: false, rateScope: .sessions)
    }

    /// `POST /sessions/refresh`.
    package static func refreshSession(_ request: RefreshSessionRequest) -> Endpoint<RefreshSessionResponse> {
        Endpoint(.post, "sessions/refresh", body: request, auth: .appKeyOnly, idempotent: true, rateScope: .sessions)
    }

    /// `PATCH /me`: sets only the fields present, so a replay has the same effect.
    package static func updateMe(_ request: UpdateMeRequest) -> Endpoint<UpdateMeResponse> {
        Endpoint(.patch, "me", body: request, auth: .bearer, idempotent: true)
    }

    /// `POST /me/logout`: 204, also when the install already logged out.
    package static func logout(_ credentials: InstallCredentials) -> Endpoint<NoContent> {
        Endpoint(.post, "me/logout", body: credentials, auth: .appKeyOnly, idempotent: true)
    }

    /// `DELETE /me`: 204, also when the install was already erased.
    package static func eraseMe(_ credentials: InstallCredentials) -> Endpoint<NoContent> {
        Endpoint(.delete, "me", body: credentials, auth: .appKeyOnly, idempotent: true)
    }

    /// `GET /me/export`: the person's `PersonExport`, as the raw JSON bytes (handed to the host app unchanged).
    package static func exportMe() -> Endpoint<Data> {
        Endpoint(.get, "me/export", auth: .bearer, idempotent: true, rateScope: .exports)
    }

    /// `GET /config`.
    ///
    /// Test devices ask for the draft with their bearer token; everyone else uses the key only.
    package static func config(draft: Bool) -> Endpoint<AppConfig> {
        Endpoint(
            .get, "config",
            query: draft ? [URLQueryItem(name: "draft", value: "1")] : [],
            auth: draft ? .bearer : .appKeyOnly,
            idempotent: true,
            acceptsNotModified: !draft
        )
    }

    /// `GET /thread`.
    package static func thread() -> Endpoint<ThreadResponse> {
        Endpoint(.get, "thread", auth: .bearer, idempotent: true)
    }

    /// `GET /thread/messages?before=&after=&limit=`.
    package static func messages(before: Int? = nil, after: Int? = nil, limit: Int) -> Endpoint<MessagesPage> {
        var query: [URLQueryItem] = []
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        // The server's default page is 50: only another size is named, so a page reads `?before=12`.
        if limit != 50 { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return Endpoint(.get, "thread/messages", query: query, auth: .bearer, idempotent: true)
    }

    /// `POST /thread/messages`: idempotent on `clientId`.
    package static func sendMessage(_ request: SendMessageRequest) -> Endpoint<SendMessageResponse> {
        Endpoint(.post, "thread/messages", body: request, auth: .bearer, idempotent: true, rateScope: .messages)
    }

    /// `POST /thread/read`.
    package static func read(upTo seq: Int) -> Endpoint<ReadResponse> {
        Endpoint(.post, "thread/read", body: ReadRequest(upToSeq: seq), auth: .bearer, idempotent: true)
    }

    /// `POST /thread/cards/:cardId/act`.
    package static func cardAction(cardId: String, _ request: CardActionRequest) -> Endpoint<NoContent> {
        Endpoint(.post, "thread/cards/\(segment(cardId))/act", body: request, auth: .bearer, idempotent: false)
    }

    /// `GET /unread`.
    package static func unread() -> Endpoint<UnreadResponse> {
        Endpoint(.get, "unread", auth: .bearer, idempotent: true)
    }

    /// `POST /uploads`: idempotent on `requestId`.
    package static func createUpload(_ request: CreateUploadRequest) -> Endpoint<CreateUploadResponse> {
        Endpoint(.post, "uploads", body: request, auth: .bearer, idempotent: true, rateScope: .uploads)
    }

    /// `GET /attachments/:id`.
    package static func attachment(id: String) -> Endpoint<AttachmentURL> {
        Endpoint(.get, "attachments/\(segment(id))", auth: .bearer, idempotent: true)
    }

    /// `POST /reports`: idempotent on `clientId`.
    package static func report(_ request: CreateReportRequest) -> Endpoint<SendMessageResponse> {
        Endpoint(.post, "reports", body: request, auth: .bearer, idempotent: true, rateScope: .messages)
    }

    /// `POST /offers/signature`: signs an App Store promotional offer for this person.
    package static func signOffer(_ request: OfferSignatureRequest) -> Endpoint<PromotionalOfferSignature> {
        Endpoint(.post, "offers/signature", body: request, auth: .bearer, idempotent: true, rateScope: .offers)
    }

    /// `GET /moments/listened` (public, cached 5 minutes).
    package static func listenedMoments() -> Endpoint<ListenedMomentsResponse> {
        Endpoint(.get, "moments/listened", auth: .appKeyOnly, idempotent: true, rateScope: .moments)
    }

    /// `POST /moments`: idempotent on `clientId`.
    package static func moment(_ request: MomentRequest) -> Endpoint<MomentResponse> {
        Endpoint(.post, "moments", body: request, auth: .bearer, idempotent: true, rateScope: .moments)
    }

    /// `GET /team-actions`: the team actions the host app still has to do, oldest first.
    package static func teamActions() -> Endpoint<PendingTeamActionsResponse> {
        Endpoint(.get, "team-actions", auth: .bearer, idempotent: true)
    }

    /// `POST /team-actions/:id/ack`: 204, also for a repeat (the first answer wins).
    package static func ackTeamAction(id: String, _ ack: TeamActionAck) -> Endpoint<NoContent> {
        Endpoint(.post, "team-actions/\(segment(id))/ack", body: ack, auth: .bearer, idempotent: true)
    }

    /// `POST /store-actions`: the receipt for a store action's result, written once per `clientId`.
    package static func reportStoreAction(_ request: StoreActionResultRequest) -> Endpoint<StoreActionResultResponse> {
        Endpoint(.post, "store-actions", body: request, auth: .bearer, idempotent: true, rateScope: .messages)
    }

    /// The live socket URL: `liveUrl` from config, or the base URL with a ws scheme.
    package static func live(baseURL: URL, override: URL?) -> LiveEndpoint {
        if let override { return LiveEndpoint(url: override) }
        var components = URLComponents(url: baseURL.appending(path: "live"), resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        return LiveEndpoint(url: components?.url ?? baseURL)
    }

    /// Percent-encodes one path segment (ids never contain `/`, but a server bug must not change the route).
    static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
