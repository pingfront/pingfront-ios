import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore

@Suite("Error envelope")
struct ErrorTests {
    @Test("429 with scope and retryAfter")
    func rateLimited() throws {
        let error = ErrorEnvelope.serverError(status: 429, data: try fixture("error-429.json"), retryAfterHeader: "5")
        #expect(error.code == .rateLimited)
        #expect(error.scope == .uploads)
        #expect(error.retryAfter == .seconds(42))
        #expect(error.docs?.absoluteString == "https://pingfront.sh/docs/errors#rate_limited")
        #expect(error.message == "Too many uploads")
    }

    @Test("401 session_revoked")
    func revoked() throws {
        let error = ErrorEnvelope.serverError(status: 401, data: try fixture("error-revoked.json"), retryAfterHeader: nil)
        #expect(error.code == .sessionRevoked)
        #expect(error.scope == nil && error.retryAfter == nil)
        #expect(!PingFrontError.server(error).isTransient)
    }

    @Test("A non-envelope body falls back to the status, Retry-After header is used")
    func nonEnvelope() throws {
        let error = ErrorEnvelope.serverError(status: 503, data: try fixture("error-500.html"), retryAfterHeader: "2.5")
        #expect(error.code == .unavailable)
        #expect(error.retryAfter == .milliseconds(2500))
        #expect(PingFrontError.server(error).isTransient)
    }

    @Test(
        "Status fallbacks",
        arguments: [
            (401, ErrorCode.unauthorized), (404, .notFound), (413, .tooLarge), (429, .rateLimited), (500, .unavailable),
            (422, .invalidRequest),
        ])
    func statusFallback(status: Int, code: ErrorCode) {
        #expect(ErrorEnvelope.serverError(status: status, data: Data(), retryAfterHeader: nil).code == code)
    }

    @Test("Unknown codes and scopes are kept or ignored, never fatal")
    func unknownCode() {
        let data = Data(#"{"error":{"code":"brand_new","message":"m","docs":"d","scope":"teleport"}}"#.utf8)
        let error = ErrorEnvelope.serverError(status: 418, data: data, retryAfterHeader: nil)
        #expect(error.code.rawValue == "brand_new")
        #expect(error.scope?.rawValue == "teleport")  // kept verbatim; only that scope would pause
    }

    @Test("A removed code (identity_token_invalid) decodes like any unknown 401: kept verbatim, not transient")
    @MainActor func removedIdentityTokenCode() {
        let data = Data(#"{"error":{"code":"identity_token_invalid","message":"m","docs":"d"}}"#.utf8)
        let error = ErrorEnvelope.serverError(status: 401, data: data, retryAfterHeader: nil)
        #expect(error.code.rawValue == "identity_token_invalid")
        #expect(error.status == 401)
        #expect(!PingFrontError.server(error).isTransient)
        let rejected = [RejectedField(field: "identity", code: "identity_token_invalid", message: "m")]
        #expect(Engine.identityProblem(in: rejected) == .unknown)
    }

    @Test("Transient and offline classification")
    func classification() {
        #expect(PingFrontError.network(.notConnectedToInternet).isOffline)
        #expect(PingFrontError.network(.notConnectedToInternet).isTransient)
        #expect(!PingFrontError.network(.badURL).isOffline)
        #expect(PingFrontError.coolingDown(scope: .uploads, remaining: .seconds(3)).isTransient)
        #expect(!PingFrontError.invalidInput("x").isTransient)
        let unprocessable = ServerError(status: 422, code: .invalidRequest, message: "", docs: nil, retryAfter: nil, scope: nil)
        #expect(!PingFrontError.server(unprocessable).isTransient)
        #expect(PingFrontError.server(unprocessable).code == .invalidRequest)
    }
}
