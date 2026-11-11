import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// A presenter that records what it was asked to do.
@MainActor final class CountingPresenter: ChatPresenting {
    var presented: [ChatTopic?] = []
    func presentChat(topic: ChatTopic?) { presented.append(topic) }
    func dismissChat() {}
    func open(_ url: URL) {}
    func presentSimpleReport() {}
}

/// Chats on screen are counted (sheet and embedded), there is never a second one, a custom UI can mark the thread read,
/// and `reload()` can be awaited.
@Suite("Chat surfaces")
@MainActor
struct ChatSurfaceTests {
    let server = StubServer()

    func makeEngine() throws -> (PingFront, Engine) {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let engine = Engine(
            facade: facade, key: try AppKey.parse("pk_test_abcdefghijklmnopqrstuvvd").get(), configuration: configuration,
            dependencies: Dependencies(
                transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
                time: TimeSource(TestClock())))
        facade.engine = engine
        engine.preview = false
        Retain.keep(facade)
        return (facade, engine)
    }

    static func thread(lastSeq: Int) -> String {
        let messages = (1...lastSeq).map { seq in
            #"{"id":"msg_\#(seq)","seq":\#(seq),"author":{"kind":"team","id":"mem_1","name":"Deniz"},"parts":[{"type":"text","text":"Hi \#(seq)"}],"createdAt":"2026-10-30T18:00:00Z"}"#
        }.joined(separator: ",")
        return
            #"{"thread":{"id":"thr_1","status":"open","lastSeq":\#(lastSeq),"readSeq":0,"unread":\#(lastSeq)},"messages":[\#(messages)],"hasOlder":false,"team":[],"policy":{"canSend":true}}"#
    }

    @Test("Closing the sheet while an embedded chat shows keeps the chat visible (N3)")
    func visibilityCountsChats() throws {
        let (facade, _) = try makeEngine()
        facade.chatVisibilityChanged(true, embedded: true)
        #expect(facade.isChatVisible)
        facade.chatVisibilityChanged(true)
        facade.chatVisibilityChanged(false)
        #expect(facade.isChatVisible, "the embedded chat is still on screen")
        facade.chatVisibilityChanged(false, embedded: true)
        #expect(!facade.isChatVisible)
        // An extra disappearance never drives the count below zero.
        facade.chatVisibilityChanged(false)
        facade.chatVisibilityChanged(true)
        #expect(facade.isChatVisible)
    }

    @Test("With an embedded chat on screen, opening the chat (a call, a chat link) focuses it instead of a sheet (N7)")
    func neverTwoChats() throws {
        let (facade, _) = try makeEngine()
        let presenter = CountingPresenter()
        facade.registry.chatPresenter = presenter
        facade.hasStarted = true
        facade.openChat()
        #expect(presenter.presented.count == 1, "nothing embedded: the sheet")
        facade.chatVisibilityChanged(true, embedded: true)
        let before = facade.conversation.composerFocusRequest
        facade.openChat(topic: ChatTopic(id: "billing", label: "Billing", prefill: "About my plan: "))
        #expect(presenter.presented.count == 1, "no second chat")
        #expect(facade.conversation.composerFocusRequest == before + 1, "the embedded chat's composer is focused")
        #expect(facade.conversation.composerInsertion == "About my plan: ")
        #expect(facade.handle(URL(string: "myapp://help?pingfront=chat")!))
        #expect(presenter.presented.count == 1)
        #expect(facade.conversation.composerFocusRequest == before + 2)
        facade.chatVisibilityChanged(false, embedded: true)
        facade.openChat()
        #expect(presenter.presented.count == 2, "the embedded chat is gone: the sheet again")
    }

    @Test("markRead() marks the thread read for a custom UI, with no SDK chat on screen (N2)")
    func markRead() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET thread", .ok(Self.thread(lastSeq: 3)))
        await server.on("POST thread/read", .ok(#"{"readSeq":3,"unread":0}"#))
        _ = try await engine.session.token(reason: .chatOpened)
        await engine.loadThread()
        #expect(facade.unreadCount == 3)
        #expect(!facade.isChatVisible)
        facade.conversation.markRead()
        #expect(await eventually { await server.requests("POST thread/read").count == 1 })
        #expect(await server.requests("POST thread/read").first?.json?["upToSeq"] as? Int == 3)
        #expect(await eventually { @MainActor in facade.unreadCount == 0 })
    }

    @Test("markRead() sends nothing while the app is paused")
    func markReadPaused() async throws {
        let (facade, engine) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET thread", .ok(Self.thread(lastSeq: 2)))
        _ = try await engine.session.token(reason: .chatOpened)
        await engine.loadThread()
        engine.closePolicy(.appPaused)
        facade.conversation.markRead()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.requests("POST thread/read").isEmpty)
    }

    @Test("await conversation.reload() returns once the thread has loaded, or failed (N14)")
    func reloadAwaits() async throws {
        let (facade, _) = try makeEngine()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET thread", .ok(Self.thread(lastSeq: 2)), .json(500, Wire.error("internal")))
        await facade.conversation.reload()
        #expect(facade.conversation.messages.count == 2, "loaded when it returns")
        #expect(facade.conversation.phase == .ready)
        await facade.conversation.reload()
        #expect(await server.requests("GET thread").count == 2)
        #expect(facade.conversation.messages.count == 2, "a failed reload keeps the thread on screen")
    }
}
