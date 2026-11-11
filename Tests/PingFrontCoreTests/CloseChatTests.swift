import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// A sheet presenter like the one in `PingFrontUI`.
///
/// It knows whether its sheet is up, and its dismissal returns once the sheet is gone: here, once the test releases it.
@MainActor final class SheetLikePresenter: ChatPresenting, ReportsChatDismissal {
    weak var facade: PingFront?
    var sheetUp = false
    var dismissals = 0
    private var release: CheckedContinuation<Void, Never>?
    var isPresentingChat: Bool { sheetUp }
    func presentChat(topic: ChatTopic?) {
        sheetUp = true
        facade?.chatVisibilityChanged(true)
    }
    func dismissChat() { sheetUp = false }
    func dismissChatAndWait() async {
        guard sheetUp else { return }
        dismissals += 1
        await withCheckedContinuation { release = $0 }
        sheetUp = false
    }
    /// Ends the sheet's dismissal animation.
    func finishDismissal() {
        release?.resume()
        release = nil
    }
    var isDismissing: Bool { release != nil }
    func open(_ url: URL) {}
    func presentSimpleReport() {}
}

/// N15: `await closeChat()` waits only for a chat the SDK presented, never for an embedded `PingFrontChatView`.
///
/// The SDK's clock is a manual one that never moves here, so a call that fell back to the two-second wait would never
/// return.
@Suite("closeChat() and embedded chats")
@MainActor
struct CloseChatTests {
    @MainActor final class Done {
        var value = false
    }

    func configured(_ presenter: SheetLikePresenter) -> PingFront {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: StubServer()), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(TestClock()))
        configuration.use(PingFrontModule(id: "ui") { $0.setChatPresenter(presenter) })
        facade.start(appKey: "pk_test_abcdefghijklmnopqrstuvvd", configuration: configuration)
        Retain.keep(facade)
        presenter.facade = facade
        return facade
    }

    @Test("Only an embedded chat on screen: returns without asking the presenter or waiting")
    func embeddedOnly() async {
        let presenter = SheetLikePresenter()
        let facade = configured(presenter)
        defer { facade.teardown() }
        facade.chatVisibilityChanged(true)  // the embedded PingFrontChatView appeared
        await facade.closeChat()
        #expect(presenter.dismissals == 0)
        #expect(facade.isChatVisible, "the embedded chat is the app's to remove")
    }

    @Test("A sheet over an embedded chat: returns when the sheet is gone, not waiting for the embedded chat")
    func sheetAndEmbedded() async {
        let presenter = SheetLikePresenter()
        let facade = configured(presenter)
        defer { facade.teardown() }
        facade.chatVisibilityChanged(true)
        facade.openChat()
        let done = Done()
        let close = Task { @MainActor in
            await facade.closeChat()
            done.value = true
        }
        #expect(await eventually { await MainActor.run { presenter.isDismissing } })
        #expect(!done.value, "returned before the sheet was gone")
        presenter.finishDismissal()
        await close.value
        #expect(!presenter.sheetUp && presenter.dismissals == 1)
    }

    @Test("A sheet opened by a chat link: waits for it")
    func sheetFromLink() async throws {
        let presenter = SheetLikePresenter()
        let facade = configured(presenter)
        defer { facade.teardown() }
        #expect(facade.handle(try #require(URL(string: "clockwise-demo://help?pingfront=chat"))))
        #expect(presenter.sheetUp)
        let close = Task { @MainActor in await facade.closeChat() }
        #expect(await eventually { await MainActor.run { presenter.isDismissing } })
        presenter.finishDismissal()
        await close.value
        #expect(!presenter.sheetUp)
    }
}
