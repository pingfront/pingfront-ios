import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

@Suite("Engine wiring")
@MainActor
struct EngineTests {
    let server = StubServer()

    func makeEngine() throws -> (PingFront, Engine) {
        let facade = PingFront()
        let key = try AppKey.parse("pk_test_abcdefghijklmnopqrstuvvd").get()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let dependencies = Dependencies(
            transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(TestClock()))
        let engine = Engine(facade: facade, key: key, configuration: configuration, dependencies: dependencies)
        facade.engine = engine
        Retain.keep(facade)
        return (facade, engine)
    }

    static func messageJSON(_ seq: Int) -> String {
        #"{"id":"m\#(seq)","seq":\#(seq),"author":{"kind":"team","name":"Deniz"},"parts":[{"type":"text","text":"m\#(seq)"}],"createdAt":"2026-10-30T18:0\#(seq):00Z"}"#
    }

    @Test("A live event after a gap fetches the missing messages first")
    func gapRepair() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        // A real server's after=2 page includes the live event's own message (5).
        await server.on(
            "GET thread/messages",
            .ok(#"{"messages":[\#(Self.messageJSON(3)),\#(Self.messageJSON(4)),\#(Self.messageJSON(5))],"hasMore":false}"#))
        facade.conversation.merge([makeMessage("m1", seq: 1), makeMessage("m2", seq: 2)])
        facade.conversation.tracker.reset(to: 2)  // as after the thread load

        let live = try WireJSON.decode(Message.self, from: Data(Self.messageJSON(5).utf8))
        await engine.apply(.message(seq: 5, message: live))

        #expect(facade.conversation.messages.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(facade.conversation.tracker.lastSeq == 5)
        let repair = try #require(await server.requests("GET thread/messages").first)
        #expect(repair.query["after"] == "2")
        #expect(repair.headers["Authorization"] == "Bearer tok_1")
        // Every team message that arrived (live or repaired) counts as unread while the chat is closed.
        #expect(facade.unreadCount == 3)
    }

    @Test("In-order and duplicate live events need no repair")
    func noRepair() async throws {
        let (facade, engine) = try makeEngine()
        facade.conversation.merge([makeMessage("m1", seq: 1)])
        facade.conversation.tracker.reset(to: 1)  // as after the thread load
        let next = try WireJSON.decode(Message.self, from: Data(Self.messageJSON(2).utf8))
        await engine.apply(.message(seq: 2, message: next))
        await engine.apply(.message(seq: 2, message: next))
        #expect(facade.conversation.messages.map(\.seq) == [1, 2])
        #expect(await server.requests.isEmpty)
        #expect(facade.unreadCount == 1)
    }

    @Test("Typing, read and thread events update state")
    func otherEvents() async throws {
        let (facade, engine) = try makeEngine()
        // Only a human teammate shows typing dots; the assistant and automated pings never do.
        await engine.apply(.typing(kind: .ai, name: "Assistant", on: true))
        #expect(facade.conversation.typing == nil)
        await engine.apply(.typing(kind: .team, name: "Deniz", on: true))
        #expect(facade.conversation.typing == TypingIndicator(name: "Deniz", isAI: false))
        let ping = try WireJSON.decode(Message.self, from: Data(Self.messageJSON(1).utf8))
        await engine.apply(.message(seq: 1, message: ping))
        #expect(facade.conversation.typing == nil, "a message must end the dots")
        await engine.apply(.read(upToSeq: 7))
        #expect(facade.conversation.teamReadSeq == 7)
        await engine.apply(.thread(status: .resolved))
        #expect(facade.conversation.status == .resolved)
        await engine.apply(.typing(kind: .team, name: nil, on: false))
        #expect(facade.conversation.typing == nil)
    }

    @Test("The deliverer retries an outbox item over the wire with the same clientId")
    func idempotentSend() async throws {
        let (_, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        let message = PendingMessage(text: "Is the yearly plan refundable?")
        await server.on(
            "POST thread/messages", .failure(.notConnectedToInternet),
            .ok(Wire.message(id: "srv_1", seq: 1, clientId: message.clientId, text: "Is the yearly plan refundable?")))
        await engine.outbox.enqueue(message)

        let first = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        #expect(first == .retryLater(.network(.notConnectedToInternet)))
        let second = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        #expect(second == .idle)

        let sends = await server.requests("POST thread/messages")
        #expect(sends.count == 2)
        #expect(sends.map { $0.json?["clientId"] as? String } == [message.clientId, message.clientId])
        #expect(sends.first?.json?["text"] as? String == "Is the yearly plan refundable?")
        #expect(await engine.outbox.all().isEmpty)
    }

    @Test("A 401 on send refreshes the token once and resends")
    func reauthOnSend() async throws {
        let (_, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session(token: "tok_old")))
        await server.on("POST sessions/refresh", .ok(Wire.refresh(token: "tok_new")))
        let message = PendingMessage(text: "hello")
        await server.on("POST thread/messages", .json(401, Wire.error("unauthorized")), .ok(Wire.message(clientId: message.clientId)))
        await engine.outbox.enqueue(message)
        #expect(await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer()) == .idle)
        let sends = await server.requests("POST thread/messages")
        #expect(sends.map { $0.headers["Authorization"] } == ["Bearer tok_old", "Bearer tok_new"])
    }
}

@Suite("Configuration checks")
@MainActor
struct ConfigurationTests {
    @Test("Bad option values are reported with exact messages")
    func options() {
        var configuration = PingFrontConfiguration()
        configuration.topics = [.billing, .billing, .bug, .idea, .question, .account, ChatTopic(id: "Bad Id", label: "x")]
        configuration.baseURL = URL(string: "ftp://example.com")!
        let problems = PingFront.optionProblems(configuration)
        #expect(problems.contains { $0.message.contains("has 7 topics") })
        #expect(problems.contains { $0.message.contains("duplicate ids") })
        #expect(problems.contains { $0.message.contains("\"Bad Id\"") })
        #expect(problems.contains { $0.message.contains("http(s)") })
        #expect(problems.allSatisfy { !$0.disablesSDK })
        #expect(PingFront.optionProblems(PingFrontConfiguration()).isEmpty)
    }

    @Test("use(...) keeps the first module with an id")
    func modules() {
        var configuration = PingFrontConfiguration()
        configuration.use(PingFrontModule(id: "a") { _ in }, PingFrontModule(id: "b") { _ in }, PingFrontModule(id: "a") { _ in })
        #expect(configuration.modules.map(\.id) == ["a", "b"])
    }

    @Test("A bad key is reported and disables the SDK without network")
    func badKey() {
        let facade = PingFront()
        facade.start(appKey: "pk_live_0123456789ABCDEFGHIJKLNz", configuration: PingFrontConfiguration())
        #expect(facade.configurationProblem?.kind == .invalidKey(.checksumMismatch))
        #expect(facade.configurationProblem?.disablesSDK == true)
        #expect(facade.engine == nil && !facade.isConfigured)
    }
}
