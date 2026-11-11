import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

@Suite("Rate-limit cooldowns")
struct CooldownTests {
    @Test("Scopes are independent")
    func scopes() {
        var cooldowns = Cooldowns()
        cooldowns.record(scope: .uploads, retryAfter: .seconds(42), now: .seconds(10))
        #expect(cooldowns.remaining(.uploads, now: .seconds(10)) == .seconds(42))
        #expect(cooldowns.remaining(.messages, now: .seconds(10)) == nil)
        #expect(cooldowns.remaining(.uploads, now: .seconds(51)) == .seconds(1))
        #expect(cooldowns.remaining(.uploads, now: .seconds(52)) == nil)
        #expect(cooldowns.active(now: .seconds(20)) == [.uploads: .seconds(32)])
    }

    @Test("A missing retryAfter waits 30 s; a shorter later limit never shortens the wait")
    func defaults() {
        var cooldowns = Cooldowns()
        cooldowns.record(scope: .moments, retryAfter: nil, now: .zero)
        #expect(cooldowns.remaining(.moments, now: .zero) == .seconds(30))
        cooldowns.record(scope: .moments, retryAfter: .seconds(5), now: .zero)
        #expect(cooldowns.remaining(.moments, now: .zero) == .seconds(30))
    }

    @Test(
        "Exact countdown under five minutes",
        arguments: [
            (Duration.seconds(42), "0:42" as String?),
            (.seconds(299), "4:59"),
            (.milliseconds(41_200), "0:42"),
            (.seconds(60), "1:00"),
            (.seconds(300), nil),
            (.seconds(3600), nil),
        ])
    func countdown(remaining: Duration, text: String?) {
        #expect(Cooldowns.countdown(remaining) == text)
    }

    @Test("After a 429 only that scope pauses; other scopes keep sending")
    func apiClient() async throws {
        let server = StubServer()
        let clock = TestClock()
        let api = APIClient(
            baseURL: StubTransport.base, appKey: "pk_test_abcdefghijklmnopqrstuvvd", transport: StubTransport(server: server),
            cooldowns: CooldownBook(time: TimeSource(clock)))
        let auth = FixedToken(api)
        defer { withExtendedLifetime(auth) {} }
        let upload = Endpoints.createUpload(
            CreateUploadRequest(requestId: "r", contentType: "image/jpeg", bytes: 1, width: 1, height: 1, sha256: "x"))
        let send = Endpoints.sendMessage(SendMessageRequest(clientId: "c", text: "hi", attachmentIds: nil, replyToCard: nil))
        await server.on(
            "POST uploads", .json(429, Wire.error("rate_limited", retryAfter: 42, scope: "uploads")),
            .ok(#"{"attachmentId":"att","putUrl":"https://put.test/x","headers":{},"expiresAt":"2099-01-01T00:00:00Z"}"#))
        await server.on("POST thread/messages", .ok(Wire.message()))

        do {
            _ = try await auth.client.send(upload)
            Issue.record("expected 429")
        } catch {
            #expect(error.code == .rateLimited)
        }
        await #expect(throws: PingFrontError.coolingDown(scope: .uploads, remaining: .seconds(42))) {
            _ = try await auth.client.send(upload)
        }
        let sent = try await auth.client.send(send)
        #expect(sent.message.id == "msg_1")
        #expect(await server.requests("POST uploads").count == 1)

        clock.advance(by: .seconds(42))
        let slot = try await auth.client.send(upload)
        #expect(slot.attachmentId == "att")
    }

    @Test("A 429 for another scope is recorded under the server's scope")
    func serverScopeWins() async {
        let server = StubServer()
        let clock = TestClock()
        let book = CooldownBook(time: TimeSource(clock))
        let api = APIClient(baseURL: StubTransport.base, appKey: "k", transport: StubTransport(server: server), cooldowns: book)
        await server.on("POST thread/messages", .json(429, Wire.error("rate_limited", retryAfter: 7, scope: "moments")))
        let auth = FixedToken(api)
        defer { withExtendedLifetime(auth) {} }
        _ = try? await auth.client.send(
            Endpoints.sendMessage(SendMessageRequest(clientId: "c", text: "hi", attachmentIds: nil, replyToCard: nil)))
        #expect(await book.remaining(.moments) == .seconds(7))
        #expect(await book.remaining(.messages) == nil)
    }

    @Test("Headers: app key, bearer, JSON body")
    func headers() async throws {
        let server = StubServer()
        let api = APIClient(
            baseURL: StubTransport.base, appKey: "pk_k", transport: StubTransport(server: server),
            cooldowns: CooldownBook(time: .continuous))
        await server.on("POST thread/read", .ok(#"{"readSeq":3,"unread":0}"#))
        let auth = FixedToken(api, token: "tok")
        defer { withExtendedLifetime(auth) {} }
        let response = try await auth.client.send(Endpoints.read(upTo: 3))
        #expect(response.readSeq == 3)
        let request = try #require(await server.requests.first)
        #expect(request.headers["PF-App-Key"] == "pk_k")
        #expect(request.headers["PF-SDK"] == "pingfront-ios/\(PingFrontVersion.current)")
        #expect(request.headers["PF-Protocol"] == "1.0.0")
        #expect(request.headers["Authorization"] == "Bearer tok")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.bodyString == #"{"upToSeq":3}"#)
    }
}

@Suite("Backoff")
struct BackoffTests {
    @Test("Nominal delays double up to 30 s")
    func nominal() {
        let backoff = Backoff()
        #expect((0..<8).map { backoff.nominal(attempt: $0) } == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
        #expect(backoff.nominal(attempt: 500) == .seconds(30))
        #expect(backoff.nominal(attempt: -3) == .seconds(1))
    }

    @Test("Jitter stays within ±20%", arguments: 0..<7)
    func jitter(attempt: Int) {
        let backoff = Backoff()
        let nominal = backoff.nominal(attempt: attempt)
        #expect(backoff.delay(attempt: attempt, unit: -1) == nominal * 0.8)
        #expect(backoff.delay(attempt: attempt, unit: 1) == nominal * 1.2)
        #expect(backoff.delay(attempt: attempt, unit: 0) == nominal)
        for _ in 0..<50 {
            let delay = backoff.delay(attempt: attempt)
            #expect(delay >= nominal * 0.8 && delay <= nominal * 1.2)
        }
    }
}
