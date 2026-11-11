import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// `PF-Wrapper`: sent on every request when a React Native or Flutter bridge configured the SDK, never otherwise.
@Suite("PF-Wrapper")
struct WrapperHeaderTests {
    static let key = "pk_test_abcdefghijklmnopqrstuvvd"

    func api(_ server: StubServer, wrapper: PingFrontWrapper?) -> APIClient {
        APIClient(
            baseURL: StubTransport.base, appKey: Self.key, transport: StubTransport(server: server),
            cooldowns: CooldownBook(time: TimeSource(TestClock())), wrapper: wrapper)
    }

    @Test("A bridge's wrapper goes on every request, app-key-only and bearer alike")
    func sentByBridges() async throws {
        let server = StubServer()
        await server.on("GET config", .ok(#"{"schema":1,"revision":1,"draft":false,"appName":"A","look":{},"team":[]}"#))
        await server.on("GET unread", .ok(#"{"unread":0,"lastSeq":0,"live":false}"#))
        let client = api(server, wrapper: PingFrontWrapper(name: "react-native", version: "1.0.0"))
        _ = try? await client.send(Endpoints.config(draft: false))
        _ = try? await client.send(Endpoints.unread(), token: "tok_1")
        let requests = await server.requests
        #expect(requests.count == 2)
        for request in requests { #expect(request.headers["PF-Wrapper"] == "react-native/1.0.0") }
        #expect(PingFrontWrapper(name: "flutter", version: "3.2.1+4").headerValue == "flutter/3.2.1+4")
    }

    @Test("A native app sends no PF-Wrapper, and a malformed wrapper is never sent")
    func nativeAndMalformed() async throws {
        let server = StubServer()
        await server.on("GET unread", .ok(#"{"unread":0,"lastSeq":0,"live":false}"#))
        _ = try? await api(server, wrapper: nil).send(Endpoints.unread(), token: "tok_1")
        _ = try? await api(server, wrapper: PingFrontWrapper(name: "react native", version: "1.0")).send(Endpoints.unread(), token: "tok_1")
        _ = try? await api(server, wrapper: PingFrontWrapper(name: "flutter", version: "")).send(Endpoints.unread(), token: "tok_1")
        let requests = await server.requests
        #expect(requests.count == 3)
        for request in requests { #expect(request.headers["PF-Wrapper"] == nil) }
    }
}
