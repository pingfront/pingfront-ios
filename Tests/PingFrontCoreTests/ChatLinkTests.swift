import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// Chat links (https://pingfront.sh/docs/chat-links): the shared case table, the queue before configure, and that handling
/// a link sends nothing.
@Suite("Chat links")
@MainActor
struct ChatLinkTests {
    let server = StubServer()
    static let key = "pk_test_abcdefghijklmnopqrstuvvd"

    final class FakePresenter: ChatPresenting, ReportPresenting {
        var chats: [ChatTopic?] = []
        var reports = 0
        func presentChat(topic: ChatTopic?) { chats.append(topic) }
        func dismissChat() {}
        func open(_ url: URL) {}
        func presentSimpleReport() { reports += 1 }
        func presentReport(prefill: String?) { reports += 1 }
    }

    // MARK: The parser

    nonisolated static let long = "https://example.com/?pingfront=chat&pad=" + String(repeating: "a", count: ChatLink.maxLength)

    nonisolated static let accepted: [(String, ChatLink)] = [
        ("https://example.com/help?pingfront=chat", .chat(topic: nil)),
        ("myapp://support?pingfront=chat", .chat(topic: nil)),
        ("HTTPS://example.com/?utm_source=mail&pingfront=chat", .chat(topic: nil)),
        ("https://example.com/?pingfront=ch%61t", .chat(topic: nil)),
        ("https://example.com/?p%69ngfront=chat", .chat(topic: nil)),
        ("myapp://support?pingfront=report", .report),
        ("https://example.com/?pingfront=chat&topic=billing", .chat(topic: "billing")),
        ("https://example.com/?topic=billing&pingfront=chat#top", .chat(topic: "billing")),
        // The topic is matched later; the parser keeps one plausible id.
        ("https://example.com/?pingfront=chat&topic=nope", .chat(topic: "nope")),
        ("https://example.com/?pingfront=chat&topic=billing&topic=bug", .chat(topic: nil)),
        ("https://example.com/?pingfront=chat&topic=" + String(repeating: "t", count: 40), .chat(topic: nil)),
        ("https://example.com/?pingfront=chat&topic=", .chat(topic: nil)),
        ("https://example.com/?pingfront=report&topic=billing", .report),
        ("https://example.com/?pingfront=chat&text=Cancel%20my%20plan", .chat(topic: nil)),
        ("https://example.com/?pingfront=chat&message=hi&x=%zz", .chat(topic: nil)),
    ]

    nonisolated static let refused: [(String, ChatLink.Refusal)] = [
        ("https://example.com/?pingfront=Chat", .unknownValue),
        ("https://example.com/?pingfront=", .unknownValue),
        ("https://example.com/?pingfront", .unknownValue),
        ("https://example.com/?pingfront=open", .unknownValue),
        ("https://example.com/?pingfront=chat%00", .unknownValue),
        ("https://example.com/?pingfront=chat&pingfront=chat", .repeated),
        ("https://example.com/?pingfront=chat&pingfront=report", .repeated),
        ("https://example.com/#pingfront=chat", .notALink),
        ("https://example.com/?a=1#?pingfront=chat", .notALink),
        ("https://example.com/pingfront=chat", .notALink),
        ("https://pingfront.example.com/chat", .notALink),
        ("https://example.com/?PingFront=chat", .notALink),
        ("javascript:alert(1)//?pingfront=chat", .scheme),
        ("JavaScript://x?pingfront=chat", .scheme),
        ("data:text/html,?pingfront=chat", .scheme),
        ("data://text/html?pingfront=chat", .scheme),
        ("vbscript://x?pingfront=chat", .scheme),
        ("file:///tmp/x?pingfront=chat", .scheme),
        ("intent://x?pingfront=chat", .scheme),
        ("myapp:support?pingfront=chat", .scheme),
        ("/help?pingfront=chat", .scheme),
        ("", .scheme),
        ("://x?pingfront=chat", .scheme),
        ("1app://x?pingfront=chat", .scheme),
        (long, .tooLong),
    ]

    @Test("Accepted links parse to the chat or the report", arguments: accepted.indices)
    func accepts(_ index: Int) {
        let (url, link) = Self.accepted[index]
        #expect(ChatLink.parse(url) == .success(link), "\(url)")
    }

    @Test("Everything else is refused or not a link", arguments: refused.indices)
    func refuses(_ index: Int) {
        let (url, refusal) = Self.refused[index]
        #expect(ChatLink.parse(url) == .failure(refusal), "\(url.prefix(80))")
    }

    @Test("The limit is 2,048 characters, inclusive")
    func limit() {
        let base = "https://example.com/?pingfront=chat&pad="
        let fits = base + String(repeating: "a", count: ChatLink.maxLength - base.count)
        #expect(ChatLink.parse(fits) == .success(.chat(topic: nil)))
        #expect(ChatLink.parse(fits + "a") == .failure(.tooLong))
    }

    @Test("A URL value parses the same as its string")
    func urlValue() throws {
        let url = try #require(URL(string: "myapp://support?pingfront=chat&topic=billing"))
        #expect(ChatLink.parse(url) == .success(.chat(topic: "billing")))
    }

    // MARK: The facade

    func makeFacade() -> PingFront {
        let facade = PingFront()
        Retain.keep(facade)
        return facade
    }

    func configure(_ facade: PingFront, topics: [ChatTopic]? = nil) -> FakePresenter {
        let presenter = FakePresenter()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.topics = topics
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: MemoryPersistence(),
            time: TimeSource(TestClock())
        )
        configuration.use(
            PingFrontModule(id: "test-ui") {
                $0.setChatPresenter(presenter)
                $0.setReportPresenter(presenter)
            })
        facade.start(appKey: Self.key, configuration: configuration)
        Retain.keep(presenter)
        return presenter
    }

    @Test("After configure: a chat link opens the chat, a topic only when the chat shows it")
    func afterConfigure() throws {
        let facade = makeFacade()
        let presenter = configure(facade, topics: [.billing, .bug, ChatTopic(id: "alarms", label: "Alarms")])
        #expect(facade.handle(try #require(URL(string: "https://example.com/help?pingfront=chat"))))
        #expect(facade.handle(try #require(URL(string: "myapp://support?pingfront=chat&topic=alarms"))))
        #expect(facade.handle(try #require(URL(string: "myapp://support?pingfront=chat&topic=idea"))))
        #expect(facade.handle(try #require(URL(string: "myapp://support?pingfront=chat&topic=BILLING"))))
        #expect(presenter.chats.map { $0?.id } == [nil, "alarms", nil, nil])
        #expect(facade.conversation.composerInsertion == nil, "a link never puts text in the composer")
    }

    @Test("The default topics count when the app set none")
    func defaultTopics() throws {
        let facade = makeFacade()
        let presenter = configure(facade)
        #expect(facade.handle(try #require(URL(string: "myapp://x?pingfront=chat&topic=billing"))))
        #expect(presenter.chats.map { $0?.id } == ["billing"])
    }

    @Test("A report link opens the report flow")
    func report() throws {
        let facade = makeFacade()
        let presenter = configure(facade)
        #expect(facade.handle(try #require(URL(string: "myapp://x?pingfront=report&topic=billing"))))
        #expect(presenter.reports == 1)
        #expect(presenter.chats.isEmpty)
    }

    @Test("Refused links and other URLs return false and open nothing")
    func refusedOpenNothing() throws {
        let facade = makeFacade()
        let presenter = configure(facade)
        for raw in ["https://example.com/?pingfront=open", "https://example.com/settings", "myapp://x?pingfront=chat&pingfront=chat"] {
            #expect(!facade.handle(try #require(URL(string: raw))), "\(raw)")
        }
        #expect(presenter.chats.isEmpty)
        #expect(presenter.reports == 0)
    }

    @Test("Before configure: kept, the last one wins, applied once after configure")
    func beforeConfigure() async throws {
        let facade = makeFacade()
        #expect(facade.handle(try #require(URL(string: "myapp://x?pingfront=report"))))
        #expect(facade.handle(try #require(URL(string: "myapp://x?pingfront=chat&topic=billing"))))
        #expect(!facade.handle(try #require(URL(string: "myapp://x?pingfront=nope"))), "a refused link doesn't replace the kept one")
        let presenter = configure(facade)
        #expect(presenter.chats.map { $0?.id } == ["billing"])
        #expect(presenter.reports == 0)

        // Applied once: configuring again doesn't replay it.
        let again = configure(facade)
        #expect(again.chats.isEmpty)
        await settle()
    }

    @Test("Before configure with a bad key: still applied once, so the chat shows the problem")
    func beforeBadKey() throws {
        let facade = makeFacade()
        #expect(facade.handle(try #require(URL(string: "myapp://x?pingfront=chat"))))
        let presenter = FakePresenter()
        var configuration = PingFrontConfiguration()
        configuration.use(PingFrontModule(id: "test-ui") { $0.setChatPresenter(presenter) })
        facade.start(appKey: "pk_test_abcdefghijklmnopqrstuwvd", configuration: configuration)
        Retain.keep(presenter)
        #expect(facade.configurationProblem != nil)
        #expect(presenter.chats.count == 1)
    }

    @Test("Handling links sends nothing, before or after configure")
    func sendsNothing() async throws {
        let facade = makeFacade()
        _ = facade.handle(try #require(URL(string: "myapp://x?pingfront=chat")))
        _ = configure(facade)
        for (url, _) in Self.accepted { _ = facade.handle(try #require(URL(string: url) ?? URL(string: "myapp://x"))) }
        for (url, _) in Self.refused { if let parsed = URL(string: url) { _ = facade.handle(parsed) } }
        await settle()
        #expect(await server.requests.isEmpty)
    }
}
