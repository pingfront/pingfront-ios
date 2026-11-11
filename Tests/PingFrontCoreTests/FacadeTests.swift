import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// The public facade, end to end against the stub server.
@Suite("Facade behavior")
@MainActor
struct FacadeTests {
    let server = StubServer()
    let clock = TestClock()
    static let key = "pk_test_abcdefghijklmnopqrstuvvd"

    final class FakePresenter: ChatPresenting {
        var presented: [ChatTopic?] = []
        func presentChat(topic: ChatTopic?) { presented.append(topic) }
        func dismissChat() {}
        func open(_ url: URL) {}
        func presentSimpleReport() {}
    }

    struct Context: ReportContextProviding {
        let tail: String
        func reportContext() async -> ReportContext { ReportContext(logTail: tail, state: ["screen": "Settings"]) }
    }

    func start(_ build: (inout PingFrontConfiguration) -> Void = { _ in }) -> (PingFront, FakePresenter) {
        let facade = PingFront()
        let presenter = FakePresenter()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(), time: TimeSource(clock)
        )
        configuration.use(PingFrontModule(id: "test-ui") { $0.setChatPresenter(presenter) })
        build(&configuration)
        facade.start(appKey: Self.key, configuration: configuration)
        Retain.keep(facade)
        Retain.keep(presenter)
        return (facade, presenter)
    }

    @Test("Nothing touches the network at configure")
    func quietStart() async {
        _ = start()
        await settle()
        #expect(await server.requests.isEmpty)
    }

    // StoreKit can't be faked here: this proves the gate StoreKitLapses.watch checks before its launch sweep.
    @Test("Modules see no install at a new install's launch, so launch scans send nothing; after a session they do")
    func moduleInstallGate() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        var context: ModuleContext?
        let (facade, _) = start { $0.use(PingFrontModule(id: "test-gate") { context = $0 }) }
        let gate = try #require(context)
        #expect(await gate.hasInstall() == false)
        await settle()
        #expect(await server.requests.isEmpty)
        try await facade.prepare()
        #expect(await gate.hasInstall())
    }

    @Test("identify and setTraits are coalesced into the session request; overlong ids are refused, not cut")
    func identifyAndTraits() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        let (facade, _) = start()
        facade.identify(userId: String(repeating: "u", count: 300))
        facade.identify(userId: "u_42", name: "Ada", email: "ada@example.com")
        facade.setTraits(["plan": "pro"])
        await settle()
        try await facade.prepare()
        let body = try #require(await server.requests("POST sessions").first?.json)
        let identity = try #require(body["identity"] as? [String: Any])
        #expect(identity["userId"] as? String == "u_42")
        #expect((body["traits"] as? [String: String]) == ["plan": "pro"])
    }

    @Test("handlePush opens the chat for message pushes and ignores other payloads")
    func handlePush() {
        let (facade, presenter) = start()
        #expect(!facade.handlePush(userInfo: ["aps": ["alert": "hi"]]))
        #expect(facade.handlePush(userInfo: ["pingfront": ["v": 1, "kind": "message", "appId": "app_1"]]))
        #expect(presenter.presented.count == 1)
        #expect(facade.handlePush(userInfo: ["pingfront": ["v": 9, "kind": "message", "appId": "app_1"]]))
        #expect(presenter.presented.count == 1, "a future payload version must not act")
    }

    @Test("moment: unlisted names send nothing; an open request presents only when allowed")
    func moments() async throws {
        await server.on("GET moments/listened", .ok(#"{"names":["paywall_closed"],"storeEvents":[]}"#))
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST moments", .ok(#"{"outcome":"delivered","open":true}"#))
        let (facade, presenter) = start()
        #expect(await facade.moment("Bad Name") == .invalidName)
        #expect(await facade.moment("app_opened") == .notListened)
        #expect(await server.requests("POST moments").isEmpty)
        #expect(await facade.moment("paywall_closed") == .openRequested(presented: true))
        #expect(presenter.presented.count == 1)

        let (quiet, quietPresenter) = start { $0.presentsChatForMoments = false }
        #expect(await quiet.moment("paywall_closed") == .openRequested(presented: false))
        #expect(quietPresenter.presented.isEmpty)
    }

    @Test("reportBug sends text and a valid UTF-8 log tail, cut on a character boundary")
    func reportWithTail() async throws {
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST reports", .ok(Wire.message(id: "rep_1", seq: 3, text: "Sync stopped")))
        // 64 KB of 3-byte characters plus one byte: a byte cut would land inside a character.
        let tail = "x" + String(repeating: "€", count: 30_000)
        let (facade, _) = start { $0.use(PingFrontModule(id: "ctx") { $0.setReportContextProvider(Context(tail: tail)) }) }
        try await facade.reportBug(text: "Sync stopped")
        let body = try #require(await server.requests("POST reports").first?.json)
        let sent = try #require(body["logTail"] as? String)
        #expect(!sent.isEmpty)
        #expect(sent.utf8.count <= Limits.reportLogBytes)
        #expect(sent.allSatisfy { $0 == "€" })
        #expect((body["state"] as? [String: String])?["screen"] == "Settings")
    }

    @Test("logLevel .off silences every SDK logger")
    func logOff() {
        _ = start { $0.logLevel = .off }
        #expect(Log.network(.error) == nil)
        _ = start { $0.logLevel = .info }
        #expect(Log.network(.debug) == nil)
        #expect(Log.network(.info) != nil)
    }
}

@Suite("Models and helpers")
struct ModelTests {
    @Test("UTF8Tail never splits a character and keeps the newest bytes")
    func utf8Tail() {
        #expect(UTF8Tail.suffix("abc", maxBytes: 10) == "abc")
        #expect(UTF8Tail.suffix("a€b", maxBytes: 3) == "b")
        #expect(UTF8Tail.suffix("a€b", maxBytes: 4) == "€b")
        #expect(UTF8Tail.suffix("👍🏽👍🏽", maxBytes: 9) == "👍🏽")
    }

    @Test("One bad look field drops only that field")
    func tolerantLook() throws {
        let json =
            ##"{"theme":{"accent":{"light":"blue","dark":7},"scheme":"dark","corners":"soft"},"header":{"style":"team","showLocalTime":"yes"}}"##
        let look = try WireJSON.decode(ChatLook.self, from: Data(json.utf8))
        #expect(look.theme.accent == nil)
        #expect(look.theme.scheme == .dark)
        #expect(look.theme.corners == .soft)
        #expect(look.header.style == .team)
        #expect(look.header.showLocalTime == nil)
    }

    @Test("SendPolicy cannot say 'can send' and give a reason at once")
    func sendPolicy() throws {
        #expect(try WireJSON.decode(SendPolicy.self, from: Data(#"{"canSend":true,"reason":"blocked"}"#.utf8)) == .open)
        #expect(try WireJSON.decode(SendPolicy.self, from: Data(#"{"canSend":false}"#.utf8)) == .closed(.unknown))
        #expect(try WireJSON.decode(SendPolicy.self, from: Data(#"{"canSend":false,"reason":"app_paused"}"#.utf8)).reason == .appPaused)
    }

    @Test("CardResult answers decode and encode as { choiceId } or { rating }")
    func cardAnswer() throws {
        let result = try WireJSON.decode(CardResult.self, from: Data(#"{"at":"2026-10-30T18:00:00Z","rating":4}"#.utf8))
        #expect(result.answer == .rating(4))
        let encoded = try #require(String(data: try WireJSON.encode(CardResult(at: result.at, answer: .choice(id: "b"))), encoding: .utf8))
        #expect(encoded.contains(#""choiceId":"b""#) && !encoded.contains("rating"))
    }

    @Test("PingFrontColor(hex:) is failable")
    func hexColor() {
        #expect(PingFrontColor(hex: "#3550E6") != nil)
        #expect(PingFrontColor(hex: "blue") == nil)
    }

    @Test("StableID is deterministic and a valid version 8 UUID")
    func stableID() {
        #expect(StableID.uuid(from: "a") == StableID.uuid(from: "a"))
        #expect(StableID.uuid(from: "a") != StableID.uuid(from: "b"))
        #expect(UUID(uuidString: StableID.uuid(from: "a")) != nil)
    }

    @Test("A sent message keeps its pending row id; the window stays bounded")
    @MainActor func conversationRows() {
        let conversation = Conversation()
        conversation.pending = [PendingMessage(clientId: "c-1", text: "hi")]
        #expect(conversation.timeline.map(\.id) == ["c-1"])
        conversation.merge([makeMessage("m1", seq: 1, kind: .person, clientId: "c-1")])
        #expect(conversation.timeline.map(\.id) == ["c-1"])
        #expect(conversation.lastPersonItemId == "c-1")
        conversation.merge((2...(Conversation.window + 20)).map { makeMessage("m\($0)", seq: $0) })
        #expect(conversation.messages.count == Conversation.window)
        #expect(conversation.hasOlder)
        #expect(conversation.messages.last?.seq == Conversation.window + 20)
    }

    @Test("Rating answers are clamped to the card's scale")
    @MainActor func ratingScale() {
        final class Driver: ConversationDriver {
            var answers: [CardAnswer?] = []
            func send(text: String?, photos: [Data], replyTo: CardReply?) {}
            func retry(_ clientId: String) {}
            func discard(_ clientId: String) {}
            func loadOlder() {}
            func act(card: Card, messageId: String, answer: CardAnswer?) { answers.append(answer) }
            func setTyping(_ on: Bool) {}
            func reload() {}
            func reloadAndWait() async {}
            func markRead() {}
            func draftChanged(_ text: String) {}
            func photoData(_ photo: PendingMessage.Photo) async -> Data? { nil }
            func imageURL(_ part: ImagePart) async -> URL? { nil }
        }
        let conversation = Conversation()
        let driver = Driver()
        conversation.driver = driver
        let card = RatingCard(id: "r", question: "How was it?", scale: 3)
        conversation.rate(5, on: card, in: makeMessage("m", seq: 1))
        #expect(driver.answers == [.rating(3)])
    }
}
