import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// The link card URL rule (https://pingfront.sh/docs/chat-links): the shared fixture cases, and what a tap does with them.
@Suite("Link card URLs", .serialized)
@MainActor
struct LinkURLRuleTests {
    struct Case: Decodable {
        let name: String
        let url: String
    }
    struct Fixture: Decodable {
        let refusedSchemes: [String]
        let allowed: [Case]
        let refused: [Case]
    }

    static func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: ConformanceTests.root.appending(path: "link-urls.json")))
    }

    @Test("The fixture's allowed URLs pass and its refused ones don't")
    func fixtureCases() throws {
        let fixture = try Self.fixture()
        #expect(LinkURLRule.refusedSchemes == Set(fixture.refusedSchemes))
        #expect(ChatLink.refusedSchemes == LinkURLRule.refusedSchemes, "chat links refuse the same schemes")
        #expect(!fixture.allowed.isEmpty && !fixture.refused.isEmpty)
        for item in fixture.allowed { #expect(LinkURLRule.allows(item.url), "\(item.name)") }
        for item in fixture.refused { #expect(!LinkURLRule.allows(item.url), "\(item.name)") }
    }

    @Test("The app's own scheme opens; another app's scheme doesn't")
    func customScheme() async throws {
        let facade = PingFront()
        let presenter = LinkPresenter()
        facade.registry.chatPresenter = presenter
        facade.appURLSchemes = ["myapp"]
        let time = TimeSource(TestClock())
        let own = LinkCard(id: "card_1", title: "Sounds", url: " MyApp://settings/sound", button: "Open")
        #expect(await CardActions.open(own, facade: facade, time: time) == nil)
        #expect(presenter.opened == [URL(string: "MyApp://settings/sound")!], "the cleaned URL goes to the system")
        let other = LinkCard(id: "card_2", title: "Other", url: "otherapp://x", button: "Open")
        #expect(await CardActions.open(other, facade: facade, time: time) == .cannotOpen)
        #expect(presenter.opened.count == 1, "another app's scheme never reaches the system")
        // The app's onLink may still take any URL the rule allows.
        facade.onLink = { $0.scheme == "otherapp" }
        #expect(await CardActions.open(other, facade: facade, time: time) == nil)
        // Nothing opens the app's own scheme: cannot_open.
        presenter.opens = false
        #expect(await CardActions.open(own, facade: facade, time: time) == .cannotOpen)
    }

    @Test("A refused URL never reaches onLink or the system, and reports cannot_open")
    func refusedNeverOpens() async throws {
        let facade = PingFront()
        let presenter = LinkPresenter()
        facade.registry.chatPresenter = presenter
        facade.appURLSchemes = Set(LinkURLRule.refusedSchemes)
        var seen: [URL] = []
        facade.onLink = { url in
            seen.append(url)
            return true
        }
        let time = TimeSource(TestClock())
        for item in try Self.fixture().refused {
            let card = LinkCard(id: "card_r", title: "Open", url: item.url, button: "Open")
            #expect(await CardActions.open(card, facade: facade, time: time) == .cannotOpen, "\(item.name)")
        }
        #expect(seen.isEmpty, "onLink never sees a refused URL")
        #expect(presenter.opened.isEmpty)
    }

    @Test("openLinkByDefault, the fallback after onLink declines, applies the rule and opens only web links and the app's own scheme")
    func openByDefault() async throws {
        let facade = PingFront()
        let presenter = LinkPresenter()
        facade.registry.chatPresenter = presenter
        facade.appURLSchemes = ["myapp"]
        facade.onLink = { _ in
            Issue.record("openLinkByDefault never asks onLink")
            return true
        }
        #expect(await facade.openLinkByDefault(URL(string: "myapp://settings")!))
        #expect(await facade.openLinkByDefault(URL(string: "https://example.com/help")!))
        #expect(await !facade.openLinkByDefault(URL(string: "otherapp://x")!))
        for item in try Self.fixture().refused {
            guard let url = URL(string: item.url) else { continue }
            #expect(await !facade.openLinkByDefault(url), "\(item.name)")
        }
        #expect(presenter.opened.map(\.absoluteString) == ["myapp://settings", "https://example.com/help"])
    }

    @Test("A link tapped in a message is checked by the rule before onLink, so no bridge sees a refused one")
    func chatLinkRule() async throws {
        let facade = PingFront()
        let presenter = LinkPresenter()
        facade.registry.chatPresenter = presenter
        var seen: [URL] = []
        facade.onLink = { url in
            seen.append(url)
            return true
        }
        for item in try Self.fixture().refused {
            if let url = URL(string: item.url) { facade.openLink(url) }
        }
        #expect(facade.chatLinkTask == nil, "a refused URL starts no wait")
        #expect(seen.isEmpty && presenter.opened.isEmpty)
        facade.openLink(URL(string: "https://example.com")!)
        await facade.chatLinkTask?.value
        #expect(seen == [URL(string: "https://example.com")!])
    }
}
