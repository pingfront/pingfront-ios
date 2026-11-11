import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// A presenter whose sheet takes a moment to go away, like UIKit's dismissal animation.
@MainActor final class SlowPresenter: ChatPresenting {
    weak var facade: PingFront?
    func presentChat(topic: ChatTopic?) { facade?.chatVisibilityChanged(true) }
    func dismissChat() {}
    func dismissChatAndWait() async {
        try? await Task.sleep(for: .milliseconds(150))
        facade?.chatVisibilityChanged(false)
    }
    func open(_ url: URL) {}
    func presentSimpleReport() {}
}

/// A presenter whose sheet is gone at once; the chat reports its disappearance later (as a chat's
/// `onDisappear` can).
@MainActor final class LatePresenter: ChatPresenting {
    weak var facade: PingFront?
    func presentChat(topic: ChatTopic?) { facade?.chatVisibilityChanged(true) }
    func dismissChat() {}
    func dismissChatAndWait() async {}
    func open(_ url: URL) {}
    func presentSimpleReport() {}
}

/// The APIs the React Native and Flutter bridges rely on.
@Suite("Bridge APIs")
struct BridgeAPITests {
    let key = "pk_test_abcdefghijklmnopqrstuvvd"

    @MainActor
    func configured(_ server: StubServer, modules: [PingFrontModule] = []) -> PingFront {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(TestClock()))
        for module in modules { configuration.use(module) }
        facade.start(appKey: key, configuration: configuration)
        Retain.keep(facade)
        return facade
    }

    @Test("selfCheck() sends the setup message and passes")
    @MainActor func selfCheckPasses() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("POST thread/messages", .ok(Wire.message(clientId: "c1")))
        let facade = configured(server)
        defer { facade.teardown() }
        let result = await facade.selfCheck(timeout: .seconds(5))
        #expect(result == .pass)
        #expect(result.line == "PingFront self-check: PASS")
        let sent = await server.requests("POST thread/messages")
        #expect(sent.count == 1)
        #expect(sent.first?.bodyString.contains("Setup check from") == true)
    }

    @Test("selfCheck() reports a stable code and advice when the server refuses the key")
    @MainActor func selfCheckFails() async {
        let server = StubServer()
        await server.on("POST sessions", .json(401, Wire.error("invalid_app_key")))
        let facade = configured(server)
        defer { facade.teardown() }
        let result = await facade.selfCheck(timeout: .seconds(5))
        #expect(!result.passed)
        #expect(result.code == "key_unknown")
        #expect(result.advice?.isEmpty == false)
    }

    @Test("selfCheck() before configure says so instead of hanging")
    @MainActor func selfCheckNotConfigured() async {
        let result = await PingFront().selfCheck()
        #expect(result.code == "not_configured")
    }

    @Test("await closeChat() returns after the chat is gone and .chatClosed was sent")
    @MainActor func closeChatWaits() async throws {
        let presenter = SlowPresenter()
        let facade = configured(StubServer(), modules: [PingFrontModule(id: "ui") { $0.setChatPresenter(presenter) }])
        defer { facade.teardown() }
        presenter.facade = facade
        facade.openChat()
        #expect(facade.isChatVisible)
        await facade.closeChat()
        #expect(!facade.isChatVisible)
        // Already closed: returns at once.
        await facade.closeChat()
        #expect(!facade.isChatVisible)
    }

    @Test("await closeChat() waits for a .chatClosed that comes after the dismissal, and a cancelled wait ends at once")
    @MainActor func closeChatWaitsForTheChatToReport() async throws {
        let presenter = LatePresenter()
        let facade = configured(StubServer(), modules: [PingFrontModule(id: "ui") { $0.setChatPresenter(presenter) }])
        defer { facade.teardown() }
        presenter.facade = facade
        facade.openChat()
        let report = Task { @MainActor in
            await Task.yield()
            facade.chatVisibilityChanged(false)
        }
        await facade.closeChat()
        #expect(!facade.isChatVisible)
        await report.value

        facade.openChat()
        let started = ContinuousClock.now
        let wait = Task { @MainActor in await facade.closeChat() }
        wait.cancel()
        await wait.value
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(facade.isChatVisible)
    }

    @Test("setPushToken(nil) clears the token: the next profile update sends push: null")
    @MainActor func clearPushToken() async throws {
        let server = StubServer()
        let facade = configured(server)
        defer { facade.teardown() }
        let engine = try #require(facade.engine)
        facade.setPushToken(Data([0xAB, 0xCD]))
        #expect(engine.unread.pushRegistered)
        facade.setPushToken(nil)
        #expect(!engine.unread.pushRegistered)
    }
}
