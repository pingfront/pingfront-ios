import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// `thread_reset` on the live socket (G8): the team reset the conversation from the dashboard.
@Suite("thread_reset live event")
@MainActor
struct ThreadResetEventTests {
    let server = StubServer()

    static var fixture: [String: Any] {
        let data = (try? Data(contentsOf: ConformanceTests.root.appending(path: "live/ServerEvent.json"))) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func value(_ kind: String, named name: String) throws -> Data {
        let items = Self.fixture[kind] as? [[String: Any]] ?? []
        let item = try #require(items.first { ($0["name"] as? String)?.hasPrefix(name) == true }, "fixture \(kind) \(name)")
        return try JSONSerialization.data(withJSONObject: try #require(item["value"]))
    }

    @Test("The fixture's thread_reset decodes with its thread; without the threadId it is unknown")
    func decodesFixture() throws {
        #expect(try ServerEvent.decode(try Self.value("valid", named: "thread_reset")) == .threadReset(threadId: "thr_01HZX3K8Q2"))
        #expect(
            try ServerEvent.decode(try Self.value("invalid", named: "thread_reset needs the threadId")) == .unknown(type: "thread_reset"))
    }

    @Test("On thread_reset the thread, its revision and the unread count go; the draft and the outbox stay; the empty chat loads")
    func resetsTheThread() async throws {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse("pk_test_abcdefghijklmnopqrstuvvd").get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
                time: TimeSource(TestClock())))
        facade.engine = engine
        Retain.keep(facade)
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on(
            "GET thread", .ok(ChatSurfaceTests.thread(lastSeq: 2)),
            .ok(#"{"thread":null,"messages":[],"hasOlder":false,"team":[],"policy":{"canSend":true}}"#))
        _ = try await engine.session.token(reason: .chatOpened)
        await engine.loadThread()
        await engine.api.threadRevision.set(7)
        #expect(facade.conversation.messages.count == 2)
        #expect(facade.unreadCount == 2)
        facade.conversation.draft = "Half a sentence"
        await engine.outbox.enqueue(PendingMessage(clientId: "unsent", text: "Unsent"))

        await engine.apply(.threadReset(threadId: "thr_1"))

        #expect(facade.conversation.messages.isEmpty, "the old messages are gone")
        #expect(facade.unreadCount == 0)
        #expect(await engine.api.threadRevision.value == nil, "the stored PF-Thread-Rev is dropped")
        #expect(facade.conversation.draft == "Half a sentence")
        #expect(await engine.outbox.all().map(\.clientId) == ["unsent"], "the unsent message starts the new thread")
        #expect(facade.conversation.pending.map(\.clientId) == ["unsent"])
        #expect(await server.requests("GET thread").count == 2, "the empty chat was loaded")
        // The socket is not touched: thread_reset never stops it (only `reset` and a close code do).
    }
}
