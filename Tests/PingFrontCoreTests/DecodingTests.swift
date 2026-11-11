import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore

@Suite("Wire decoding")
struct DecodingTests {
    let page: MessagesPage

    init() throws {
        page = try WireJSON.decode(MessagesPage.self, from: fixture("messages.json"))
    }

    func message(_ id: String) throws -> Message {
        try #require(page.messages.first { $0.id == id })
    }

    @Test("A malformed message is dropped, the rest of the page survives")
    func lossyPage() {
        #expect(page.hasMore)
        #expect(
            page.messages.map(\.id) == ["msg_text", "msg_ping", "msg_image", "msg_cards", "msg_receipt", "msg_ai", "msg_future_author"])
    }

    @Test("Text part and clientId")
    func text() throws {
        let message = try message("msg_text")
        #expect(message.parts == [.text("Is the yearly plan refundable?")])
        #expect(message.clientId == "6f1d6c2e-2f43-4f7e-9a4b-0d7a3f1c0001")
        #expect(message.isFromPerson)
    }

    @Test("Ping origin and offset dates with fractional seconds")
    func ping() throws {
        let message = try message("msg_ping")
        #expect(message.ping == PingOrigin(kind: .play, playId: "play_plans", explanation: "Sent automatically after you closed Plans"))
        #expect(message.author.avatarURL == URL(string: "https://cdn.test/deniz.png"))
        let expected = try #require(ISODate.parse("2026-10-30T18:01:00.123Z"))
        #expect(abs(message.createdAt.timeIntervalSince(expected)) < 0.001)
    }

    @Test("Image part")
    func image() throws {
        #expect(
            try message("msg_image").parts == [
                .image(ImagePart(attachmentId: "att_1", width: 1170, height: 2532, url: URL(string: "https://cdn.test/a.jpg")))
            ])
    }

    @Test("Every card kind, results, and an unknown card kind")
    func cards() throws {
        let parts = try message("msg_cards").parts
        #expect(parts.count == 7)
        guard case .card(let offer) = parts[0], case .offer(let card) = offer.card else {
            Issue.record("offer")
            return
        }
        #expect(card.offerId == "yearly" && card.body == "First month free" && card.button == "See the offer")
        guard case .card(let review) = parts[1], case .review(let reviewCard) = review.card else {
            Issue.record("review")
            return
        }
        #expect(reviewCard.mode == .nativePrompt && reviewCard.storeURL != nil)
        guard case .card(let link) = parts[2], case .link(let linkCard) = link.card else {
            Issue.record("link")
            return
        }
        #expect(linkCard.url == "clockwise://help")
        guard case .card(let choices) = parts[3], case .choices(let choicesCard) = choices.card else {
            Issue.record("choices")
            return
        }
        #expect(choicesCard.options.map(\.id) == ["a", "b"])
        #expect(choices.result?.choiceId == "b")
        guard case .card(let rating) = parts[4], case .rating(let ratingCard) = rating.card else {
            Issue.record("rating")
            return
        }
        #expect(ratingCard.scale == 5 && rating.result?.rating == 4)
        guard case .card(let report) = parts[5], case .report = report.card else {
            Issue.record("report")
            return
        }
        guard case .card(let future) = parts[6] else {
            Issue.record("future")
            return
        }
        #expect(future.card == .unknown(kind: "survey", id: "c_future"))
        #expect(future.card.id == "c_future")
    }

    @Test("Receipts, including an unknown action and the AI teammate's hand-off")
    func receipts() throws {
        let message = try message("msg_receipt")
        #expect(
            message.parts == [
                .receipt(ReceiptPart(action: .trialExtended, text: "Trial extended to 14 Nov")),
                .receipt(ReceiptPart(action: .custom, text: "Gift sent")),
                .receipt(ReceiptPart(action: .handedOff, text: "Deniz will reply")),
            ])
        #expect(message.author.kind == .system)
    }

    @Test("Translation, AI author and an unknown part type")
    func translationAndUnknown() throws {
        let message = try message("msg_ai")
        #expect(message.author.kind == .ai)
        #expect(message.parts == [.text("Hola"), .unknown(type: "poll")])
        #expect(message.translation == Translation(language: "en", texts: ["Hello"]))
        #expect(message.plainText == "Hola")
    }

    @Test("An unknown author kind decodes instead of failing")
    func unknownAuthor() throws {
        #expect(try message("msg_future_author").author.kind == .unknown)
    }

    @Test("Messages round-trip through the encoder")
    func roundTrip() throws {
        let data = try WireJSON.encode(page.messages)
        let decoded = try WireJSON.decode([Message].self, from: data)
        #expect(decoded == page.messages)
    }

    @Test("Thread response with team, expectation and policy")
    func thread() throws {
        let thread = try WireJSON.decode(ThreadResponse.self, from: fixture("thread.json"))
        #expect(thread.thread?.unread == 1)
        #expect(thread.messages.count == 2)
        #expect(thread.team.first?.role == "Maker of Clockwise")
        #expect(thread.policy == SendPolicy.closed(.blocked))
        // Verified-only apps close sending until the person is verified; an unknown reason decodes as unknown.
        let verified = try WireJSON.decode(SendPolicy.self, from: Data(#"{"canSend":false,"reason":"verification_required"}"#.utf8))
        #expect(verified == .closed(.verificationRequired))
        let unknown = try WireJSON.decode(SendPolicy.self, from: Data(#"{"canSend":false,"reason":"over_quota"}"#.utf8))
        #expect(unknown == .closed(.unknown))
        #expect(thread.replyExpectation == "Usually replies within a few hours")
    }

    @Test("A hello before the first message carries no thread revision")
    func helloWithoutThread() throws {
        let none = try ServerEvent.decode(Data(#"{"type":"hello","threadId":null,"rev":0,"lastSeq":0,"readSeq":0}"#.utf8))
        #expect(none == .hello(lastSeq: 0, readSeq: 0, rev: 0))
        let zero = try ServerEvent.decode(Data(#"{"type":"hello","rev":0,"lastSeq":0,"readSeq":0}"#.utf8))
        #expect(zero == .hello(lastSeq: 0, readSeq: 0, rev: 0))
        let thread = try ServerEvent.decode(Data(#"{"type":"hello","threadId":"thr_1","rev":2,"lastSeq":9,"readSeq":7}"#.utf8))
        #expect(thread == .hello(lastSeq: 9, readSeq: 7, rev: 2))
    }

    @Test("Live events, including config and an unknown type")
    func events() throws {
        let raw = try #require(try JSONSerialization.jsonObject(with: fixture("events.json")) as? [Any])
        let events = try raw.map { try ServerEvent.decode(JSONSerialization.data(withJSONObject: $0)) }
        #expect(events.count == 10)
        #expect(events[0] == .hello(lastSeq: 4, readSeq: 2))
        guard case .message(let seq, let message) = events[1] else {
            Issue.record("message")
            return
        }
        #expect(seq == 5 && message.id == "m5")
        #expect(events[1].seq == 5)
        guard case .messageUpdated(let updatedSeq, let updated) = events[2] else {
            Issue.record("updated")
            return
        }
        #expect(updatedSeq == 6 && updated.plainText == "Hi!")
        #expect(events[3] == .typing(kind: .ai, name: "Assistant", on: true))
        #expect(events[4] == .read(upToSeq: 5))
        #expect(events[5] == .thread(status: .resolved))
        #expect(events[6] == .reset)
        #expect(events[7] == .config(revision: 4, draft: true))
        #expect(events[8] == .reauth)
        #expect(events[9] == .unknown(type: "presence"))
        #expect(events[9].seq == nil)
    }

    @Test("Client events encode to the wire shape")
    func clientEvents() throws {
        #expect(String(decoding: try WireJSON.encode(ClientEvent.ping), as: UTF8.self) == #"{"type":"ping"}"#)
        #expect(String(decoding: try WireJSON.encode(ClientEvent.typing(on: true)), as: UTF8.self) == #"{"on":true,"type":"typing"}"#)
    }

    @Test("Session response defaults testDevice to false")
    func sessionDefaults() throws {
        let response = try WireJSON.decode(
            CreateSessionResponse.self,
            from: Data(
                #"{"accessToken":"t","accessExpiresAt":"2099-01-01T00:00:00+02:00","installSecret":"s","person":{"id":"p","level":"wizard"},"identityProblem":"token_expired"}"#
                    .utf8))
        #expect(response.testDevice == false)
        #expect(response.person.level == .guest)
        #expect(response.identityProblem == .tokenExpired)
    }
}
