#if canImport(UIKit)
    import SwiftUI
    import UIKit
    import XCTest
    import PingFrontCore
    @testable import PingFrontUI

    /// Pins the chat's bubble metrics to the Messages values measured on iPhone 17 (31 Oct 2026), so they cannot
    /// drift.
    @MainActor
    final class BubbleMetricsTests: XCTestCase {
        /// The message column on an iPhone 17 (402 pt screen, 12 pt gutters).
        let thread: CGFloat = 378

        func testTokensMatchMessages() {
            XCTAssertEqual(BubbleMetrics.padding, EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            XCTAssertEqual(BubbleMetrics.maxWidthFraction, 0.75)
            XCTAssertEqual(BubbleMetrics.accessibilityMaxWidthFraction, 0.9)
            XCTAssertEqual(BubbleMetrics.rowSpacing, 2)
            XCTAssertEqual(BubbleMetrics.groupSpacing, 10)
            XCTAssertEqual(BubbleMetrics.avatarSize, 28)
            XCTAssertEqual(BubbleMetrics.cardWidth, 300)
            XCTAssertEqual(ChatTheme.standard.bubbleRadius, 18)
            XCTAssertEqual(BubbleMetrics.insetScale(textScale: 1), 1)
            XCTAssertEqual(BubbleMetrics.insetScale(textScale: 40.0 / 17), 1.338, accuracy: 0.01)
            XCTAssertEqual(ChatTheme.standard.rowSpacing, 2)
            XCTAssertEqual(ChatTheme.standard.groupSpacing, 10)
        }

        func testOneLineBubbleIsMessagesHeight() {
            let size = bubble("Ok")
            // Messages: 40 pt (17 pt body on a 20.3 pt line plus 10 pt insets).
            XCTAssertEqual(size.height, 40, accuracy: 1)
            // Short bubbles hug their text.
            XCTAssertLessThan(size.width, 70)
        }

        func testLongBubbleWrapsAtMessagesWidth() {
            let size = bubble("Also, the timer skipped a second at midnight and the alarm rang a minute late on Saturday.")
            XCTAssertLessThanOrEqual(size.width, BubbleMetrics.maxWidth(threadWidth: thread, accessibility: false) + 0.5)
            XCTAssertGreaterThan(size.width, thread * 0.6)
        }

        func testAccessibilitySizesScaleTextAndInsets() {
            let regular = bubble("Ok")
            let large = bubble("Ok", size: .accessibility3)
            XCTAssertGreaterThan(large.height, regular.height * 1.8)
            let long = bubble("Also, the timer skipped a second at midnight.", size: .accessibility3)
            XCTAssertLessThanOrEqual(long.width, BubbleMetrics.maxWidth(threadWidth: thread, accessibility: true) + 0.5)
        }

        /// Launch audit I-02: a bubble that its row places (a failed send, with the red mark beside it) takes only
        /// its text's width when the row offers the whole thread, so the mark sits at the bubble's edge.
        func testPlacedBubbleHugsItsTextWhenOfferedTheRow() {
            let offered = CGSize(width: thread, height: .greatestFiniteMagnitude)
            let short = UIHostingController(
                rootView: TextBubble(text: "Is there a family plan?", side: .person, fillsRow: false).environment(\.threadWidth, thread)
            ).sizeThatFits(in: offered)
            XCTAssertLessThan(short.width, 200, "the bubble hugs its text instead of stretching to 75% of the thread")
            let long = UIHostingController(
                rootView: TextBubble(
                    text: "Also, the timer skipped a second at midnight and the alarm rang a minute late on Saturday.", side: .person,
                    fillsRow: false
                ).environment(\.threadWidth, thread)
            ).sizeThatFits(in: offered)
            XCTAssertLessThanOrEqual(long.width, BubbleMetrics.maxWidth(threadWidth: thread, accessibility: false) + 0.5)
            XCTAssertGreaterThan(long.width, thread * 0.6)
        }

        private func bubble(_ text: String, size: DynamicTypeSize = .large) -> CGSize {
            let view = TextBubble(text: text, side: .person, fillsRow: false)
                .environment(\.threadWidth, thread)
                .environment(\.dynamicTypeSize, size)
                .fixedSize()
            let host = UIHostingController(rootView: view)
            return host.sizeThatFits(in: CGSize(width: thread, height: .greatestFiniteMagnitude))
        }
    }
#endif
