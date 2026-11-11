import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

func makeMessage(
    _ id: String, seq: Int, kind: Author.Kind = .team, author: String? = "Deniz", clientId: String? = nil, minutes: Double = 0,
    ping: PingOrigin? = nil, parts: [MessagePart]? = nil
) -> Message {
    Message(
        id: id, seq: seq, clientId: clientId, author: Author(kind: kind, id: author.map { "id_\($0)" }, name: author),
        parts: parts ?? [.text("m\(seq)")], createdAt: Date(timeIntervalSince1970: 1_793_390_400 + minutes * 60), ping: ping)
}

@Suite("Sequence gaps")
struct SeqTrackerTests {
    @Test("Next in order applies, old seqs are duplicates, jumps are gaps")
    func decisions() {
        var tracker = SeqTracker(lastSeq: 4)
        #expect(tracker.decide(5) == .apply)
        #expect(tracker.decide(4) == .duplicate)
        #expect(tracker.decide(1) == .duplicate)
        #expect(tracker.decide(7) == .gap(after: 4))
        tracker.advance(to: 7)
        #expect(tracker.lastSeq == 7)
        tracker.advance(to: 3)
        #expect(tracker.lastSeq == 7)
        #expect(tracker.decide(8) == .apply)
        tracker.reset(to: 0)
        #expect(tracker.decide(1) == .apply)
    }
}

@Suite("Conversation state")
@MainActor
struct ConversationTests {
    @Test("A teammate's changed name and photo show on their earlier messages")
    func teammateRename() {
        let conversation = Conversation()
        let old = makeMessage("m1", seq: 1, author: "Deniz")
        conversation.merge([old, makeMessage("m2", seq: 2, kind: .ai, author: "Deniz")])
        #expect(conversation.displayAuthor(of: old).name == "Deniz")
        conversation.refreshTeam(from: [TeamMember(id: "id_Deniz", name: "Deniz Y.")])
        let photo = URL(string: "https://cdn.test/deniz-new.jpg")
        conversation.refreshTeam(from: [TeamMember(id: "id_Deniz", name: "Deniz Yılmaz", avatarURL: photo)])
        #expect(conversation.displayAuthor(of: old).name == "Deniz Yılmaz")
        #expect(conversation.displayAuthor(of: old).avatarURL == photo)
        // Only team authors take the team's details; an unknown id keeps what the message carried.
        #expect(conversation.displayAuthor(of: conversation.messages[1]).name == "Deniz")
        #expect(conversation.displayAuthor(of: makeMessage("m3", seq: 3, author: "Mara")).name == "Mara")
    }

    @Test("merge dedupes by id, keeps seq order, drops acknowledged pending items")
    func merge() {
        let conversation = Conversation()
        let pending = PendingMessage(clientId: "c-1", text: "hi")
        conversation.pending = [pending, PendingMessage(clientId: "c-2", text: "still waiting")]
        conversation.merge([makeMessage("m3", seq: 3, kind: .person, clientId: "c-1"), makeMessage("m1", seq: 1)])
        conversation.merge([makeMessage("m2", seq: 2), makeMessage("m1", seq: 1, parts: [.text("edited")])])
        #expect(conversation.messages.map(\.id) == ["m1", "m2", "m3"])
        #expect(conversation.messages.first?.plainText == "edited")
        #expect(conversation.pending.map(\.clientId) == ["c-2"])
        // Merging (acks, older pages, reports) never moves the seq tracker; only live events and repairs do.
        #expect(conversation.tracker.lastSeq == 0)
    }

    @Test("replace(with:) loads the thread and hides pending items it already contains")
    func replace() throws {
        let conversation = Conversation()
        conversation.setPending([PendingMessage(clientId: "c-1", text: "hi")])
        let response = ThreadResponse(
            thread: ThreadInfo(id: "t", status: .resolved, lastSeq: 9, readSeq: 9, unread: 0),
            messages: [makeMessage("m1", seq: 1, kind: .person, clientId: "c-1")], hasOlder: true,
            team: [TeamMember(id: "m", name: "Deniz")], replyExpectation: "Soon", policy: SendPolicy.closed(.blocked))
        conversation.replace(with: response)
        #expect(conversation.pending.isEmpty)
        #expect(conversation.tracker.lastSeq == 9)
        #expect(conversation.status == .resolved && conversation.hasOlder && conversation.phase == .ready)
        #expect(conversation.policy.reason == .blocked)
        conversation.clear()
        #expect(conversation.isEmpty && conversation.phase == .idle && conversation.tracker.lastSeq == 0)
    }

    @Test("Cooldown remaining is read from the injected clock")
    func cooldownRemaining() {
        let clock = TestClock()
        let conversation = Conversation()
        conversation.time = TimeSource(clock)
        conversation.cooldownDeadlines = [.uploads: .seconds(42)]
        #expect(conversation.cooldownRemaining(.uploads) == .seconds(42))
        clock.advance(by: .seconds(40))
        #expect(conversation.cooldownRemaining(.uploads) == .seconds(2))
        clock.advance(by: .seconds(2))
        #expect(conversation.cooldownRemaining(.uploads) == nil)
        #expect(conversation.cooldownRemaining(.messages) == nil)
    }

    @Test("Offline is derived from the live state")
    func offline() {
        let conversation = Conversation()
        conversation.live = .waiting(retryIn: .seconds(2), offline: true)
        #expect(conversation.isOffline)
        conversation.live = .live
        #expect(!conversation.isOffline)
    }
}

@Suite("Timeline grouping")
struct TimelineTests {
    let ping = PingOrigin(kind: .play, playId: "play_1", explanation: "Sent after you closed Plans")

    @Test("Messages from the same author within 5 minutes form a group")
    func groups() {
        let items = Timeline.build(
            messages: [
                makeMessage("a", seq: 1, minutes: 0),
                makeMessage("b", seq: 2, minutes: 1),
                makeMessage("c", seq: 3, minutes: 7),
                makeMessage("d", seq: 4, kind: .person, author: nil, minutes: 8),
                makeMessage("e", seq: 5, author: "Mara", minutes: 8.5),
            ], pending: [])
        #expect(items.map(\.startsGroup) == [true, false, true, true, true])
        #expect(items.map(\.endsGroup) == [false, true, true, true, true])
        #expect(items.map(\.side) == [.team, .team, .team, .person, .team])
    }

    @Test("Ping line on the first message of a ping run only")
    func pingRun() {
        let items = Timeline.build(
            messages: [
                makeMessage("p1", seq: 1, minutes: 0, ping: ping),
                makeMessage("p2", seq: 2, minutes: 0.5, ping: ping),
                makeMessage("n", seq: 3, minutes: 1),
                makeMessage("p3", seq: 4, minutes: 1.5, ping: PingOrigin(kind: .manual, playId: nil, explanation: "Deniz reached out")),
            ], pending: [])
        #expect(items.map(\.startsPing) == [true, false, false, true])
        // A new ping run starts a new group so its line sits above it.
        #expect(items[3].startsGroup)
        #expect(!items[1].startsGroup)
    }

    @Test("Receipts sit in the middle, AI is flagged, pending rows are the person's")
    func sides() {
        let receipt = makeMessage(
            "r", seq: 2, kind: .system, author: nil, minutes: 1,
            parts: [.receipt(ReceiptPart(action: .trialExtended, text: "Trial extended to 14 Nov"))])
        let teamReceipt = makeMessage(
            "tr", seq: 3, minutes: 1.2, parts: [.receipt(ReceiptPart(action: .promoGranted, text: "Promo granted"))])
        let ai = makeMessage("ai", seq: 4, kind: .ai, author: "Assistant", minutes: 2)
        let mine = makeMessage("me", seq: 5, kind: .person, author: nil, minutes: 3)
        let pending = PendingMessage(clientId: "c", text: "sending", createdAt: Date(timeIntervalSince1970: 1_793_390_400 + 200))
        let items = Timeline.build(messages: [makeMessage("t", seq: 1), receipt, teamReceipt, ai, mine], pending: [pending])
        #expect(items.map(\.side) == [.team, .system, .system, .team, .person, .person])
        #expect(items[3].isAI && !items[0].isAI)
        #expect(items[1].startsGroup && items[1].endsGroup)
        // The pending row continues the person's group.
        #expect(!items[5].startsGroup && items[4].startsGroup && !items[4].endsGroup)
        #expect(items[5].id == "c")
    }
}
