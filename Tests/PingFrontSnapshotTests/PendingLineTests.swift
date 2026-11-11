#if canImport(UIKit)
    import XCTest
    @_spi(Fixtures) import PingFrontCore
    @testable import PingFrontUI

    /// N13: the line under an undelivered message says what is really happening, as on Android and the web.
    @MainActor
    final class PendingLineTests: XCTestCase {
        func testOnlyTheMessageOnTheWireIsSending() {
            XCTAssertEqual(PendingLine(.sending, offline: false), .sending)
        }

        func testAQueuedMessageIsNotSentYetOnlyAfterAnAttempt() {
            // After a rate limit or backoff: not sent yet. Never tried (behind the one on the wire): Sending….
            XCTAssertEqual(PendingLine(.queued, attempts: 1, offline: false), .retrying)
            XCTAssertEqual(PendingLine(.queued, attempts: 0, offline: false), .sending)
        }

        func testWhileSendingIsClosedItWaitsForTheChatToReopen() {
            XCTAssertEqual(PendingLine(.queued, attempts: 1, held: .appPaused, offline: false), .held(.appPaused))
            XCTAssertEqual(PendingLine(.queued, attempts: 0, held: .verificationRequired, offline: true), .held(.verificationRequired))
        }

        func testOfflineItWaitsWhateverTheOutboxIsDoing() {
            XCTAssertEqual(PendingLine(.queued, offline: true), .waiting)
            XCTAssertEqual(PendingLine(.sending, offline: true), .waiting)
        }

        func testUnreachableIsNotWaitingForAConnection() {
            // Online but the service can't be reached: the device has a connection, the outbox keeps trying.
            XCTAssertEqual(PendingLine(.queued, attempts: 1, offline: true, unreachable: true), .retrying)
            XCTAssertEqual(PendingLine(.queued, attempts: 0, offline: true, unreachable: true), .retrying)
        }

        @MainActor func testTheWords() {
            let t = L10n(Locale(identifier: "en"))
            XCTAssertEqual(PendingLine.retrying.text(t), "Not sent yet. Trying again soon.")
            XCTAssertEqual(PendingLine.waiting.text(t), "Waiting for connection")
            XCTAssertEqual(PendingLine.sending.text(t), "Sending…")
            XCTAssertEqual(PendingLine.held(.appPaused).text(t), "Not sent yet. It will send when the chat is back.")
            XCTAssertEqual(PendingLine.held(.verificationRequired).text(t), "Not sent yet. It will send after you sign in.")
        }

        /// One line per run of the same status, under its last message; a different status starts a new run.
        func testALineShowsOnceUnderTheLastOfItsRun() {
            let held = PendingLine.held(.appPaused)
            XCTAssertEqual(
                (0..<2).map { PendingLine.showsLine([held, held], at: $0) }, [false, true], "two held messages: one line")
            XCTAssertEqual(
                (0..<3).map { PendingLine.showsLine([held, held, .sending], at: $0) }, [false, true, true],
                "held, then sending: each run's last message")
            XCTAssertEqual(
                (0..<3).map { PendingLine.showsLine([.sending, held, held], at: $0) }, [true, false, true])
        }

        /// A failure that needs the person keeps its own line and splits the runs around it.
        func testAFailureEndsARun() {
            let held = PendingLine.held(.appPaused)
            XCTAssertEqual(
                (0..<3).map { PendingLine.showsLine([held, nil, held], at: $0) }, [true, false, true],
                "the failed message (nil) shows Not delivered itself; the held lines either side both show")
        }

        /// Through the conversation: a held message and the one queued behind it share the line; a plain failure
        /// has none.
        func testLinesFromTheConversation() {
            let conversation = Conversation()
            var held = PendingMessage(clientId: "a", text: "a")
            held.state = .failed
            held.heldFor = .appPaused
            let behind = PendingMessage(clientId: "b", text: "b")
            var failed = PendingMessage(clientId: "c", text: "c")
            failed.state = .failed
            conversation.pending = [held, behind, failed]
            let lines = conversation.pending.map { PendingLine.line(for: $0, in: conversation) }
            XCTAssertEqual(lines, [.held(.appPaused), .held(.appPaused), nil])
            XCTAssertEqual((0..<3).map { PendingLine.showsLine(lines, at: $0) }, [false, true, false])
        }

        /// "You can close this; the reply waits here." only once the person's message is delivered (audit 4, N4).
        func testTheCloseHintWaitsForDelivery() {
            let sent = Message(
                id: "m1", seq: 1, author: Author(kind: .person), parts: [.text("Hi")], createdAt: Date(timeIntervalSince1970: 0))
            XCTAssertTrue(FirstMessageNote.applies(to: [sent]))
            XCTAssertFalse(FirstMessageNote.applies(to: [sent], pending: [PendingMessage(clientId: "p", text: "More")]))
        }

        /// A message queued behind one that waits to be tried again is not on the wire: "Not sent yet. Trying again
        /// soon.", not Sending…, as on the web and Android.
        func testAMessageBehindARetryIsNotSending() {
            XCTAssertEqual(PendingLine(.queued, attempts: 0, offline: false, behindRetry: true), .retrying)
            let conversation = Conversation()
            var first = PendingMessage(clientId: "a", text: "a")
            first.attempts = 1
            conversation.pending = [first, PendingMessage(clientId: "b", text: "b")]
            XCTAssertEqual(conversation.pending.map { PendingLine.line(for: $0, in: conversation) }, [.retrying, .retrying])
            // Nothing ahead waits: the next one up is on its way.
            conversation.pending = [PendingMessage(clientId: "c", text: "c")]
            XCTAssertEqual(PendingLine.line(for: conversation.pending[0], in: conversation), .sending)
        }
    }
#endif
