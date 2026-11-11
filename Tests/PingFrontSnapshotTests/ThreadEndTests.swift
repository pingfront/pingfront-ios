#if canImport(UIKit)
    import XCTest
    @testable import PingFrontUI

    /// The thread keeps its end in view through layout changes (the keyboard opening, a pushed chat's bars settling),
    /// never through scrolls: those decide whether it is at its end (`MessageList.StaysAtBottom`).
    final class ThreadEndTests: XCTestCase {
        typealias Rule = MessageList.StaysAtBottom
        typealias Extent = Rule.Extent

        /// A 2,000 pt thread in a 600 pt scroll view with no bar insets, scrolled to `offset`.
        func plain(_ offset: CGFloat, height: CGFloat = 2000, container: CGFloat = 600, insetBottom: CGFloat = 0) -> Extent {
            Extent(
                contentHeight: height, container: container, insetTop: 0, insetBottom: insetBottom,
                visibleMaxY: offset + container + insetBottom)
        }

        var atEnd: Extent { plain(1400) }

        /// Landscape sheet, as measured on the simulator.
        ///
        /// The header and composer bars inset the scroll view (60 and 78 pt), and `visibleRect` spans them. At the end the bottom of the visible thread meets the content's end;
        /// counting the composer's inset as visible read 138 pt short and showed Jump to latest at the end.
        func testTheBarsInsetsAreNotPartOfTheVisibleThread() {
            let landscape = Extent(contentHeight: 2639.33, container: 302, insetTop: 60, insetBottom: 78, visibleMaxY: 2717.33)
            XCTAssertEqual(landscape.remaining, 0, accuracy: 0.01)
            XCTAssertTrue(Rule.isAtEnd(landscape))
        }

        func testTheKeyboardOpeningKeepsTheEnd() {
            // The keyboard's inset shrinks the visible thread by 336 pt at the same offset: the end is out of view.
            let keyboard = Extent(contentHeight: 2000, container: 264, insetTop: 0, insetBottom: 336, visibleMaxY: 1400 + 264 + 336)
            XCTAssertEqual(keyboard.remaining, 336, accuracy: 0.01)
            XCTAssertTrue(Rule.keepsEnd(old: atEnd, new: keyboard, pinned: true, moving: false))
            // Scrolled to the end above the keyboard: nothing more to do.
            let settled = Extent(contentHeight: 2000, container: 264, insetTop: 0, insetBottom: 336, visibleMaxY: 1736 + 264 + 336)
            XCTAssertTrue(Rule.isAtEnd(settled))
            XCTAssertFalse(Rule.keepsEnd(old: keyboard, new: settled, pinned: true, moving: false))
        }

        func testGrowingContentKeepsTheEnd() {
            XCTAssertTrue(Rule.keepsEnd(old: atEnd, new: plain(1400, height: 2044), pinned: true, moving: false))
        }

        func testAScrollNeverPullsTheThreadBack() {
            // Only the offset changed: a scroll, by the person, VoiceOver or the SDK.
            XCTAssertFalse(Rule.keepsEnd(old: atEnd, new: plain(900), pinned: true, moving: false))
        }

        func testAThreadScrolledUpStaysWhereItIs() {
            let up = plain(200)
            let keyboard = Extent(contentHeight: 2000, container: 264, insetTop: 0, insetBottom: 336, visibleMaxY: 200 + 264 + 336)
            XCTAssertFalse(Rule.keepsEnd(old: up, new: keyboard, pinned: false, moving: false))
            XCTAssertFalse(Rule.isAtEnd(up))
            XCTAssertFalse(Rule.showsEnd(up, pinned: false, moving: false), "Jump to latest shows when scrolled up")
        }

        func testNeverFightsTheFinger() {
            XCTAssertFalse(Rule.keepsEnd(old: atEnd, new: plain(1400, height: 2044), pinned: true, moving: true))
            XCTAssertFalse(Rule.showsEnd(plain(900), pinned: true, moving: true), "dragging up shows Jump to latest")
        }

        func testPinnedHidesJumpToLatestThroughALayoutChange() {
            // Mid keyboard animation the end is briefly out of view; pinned, Jump to latest does not flash.
            let keyboard = Extent(contentHeight: 2000, container: 264, insetTop: 0, insetBottom: 336, visibleMaxY: 1400 + 264 + 336)
            XCTAssertFalse(Rule.isAtEnd(keyboard))
            XCTAssertTrue(Rule.showsEnd(keyboard, pinned: true, moving: false))
        }

        /// Landscape to portrait with the keyboard up (audit 5, S1).
        ///
        /// The scroll view grows taller at the same offset, so the visible thread ends past the content's end, a blank
        /// gap above the composer. Pinned, the end comes back.
        func testRotatingBackKeepsTheEndWithoutAGap() {
            let landscape = Extent(contentHeight: 2000, container: 120, insetTop: 60, insetBottom: 200, visibleMaxY: 1880 + 120 + 200)
            XCTAssertEqual(landscape.remaining, 0, accuracy: 0.01)
            let portrait = Extent(contentHeight: 2000, container: 404, insetTop: 120, insetBottom: 336, visibleMaxY: 1880 + 404 + 336)
            XCTAssertLessThan(portrait.remaining, -200, "a gap past the end")
            XCTAssertTrue(Rule.keepsEnd(old: landscape, new: portrait, pinned: true, moving: false))
            // Scrolled up before rotating: it stays where it was.
            XCTAssertFalse(Rule.keepsEnd(old: landscape, new: portrait, pinned: false, moving: false))
        }
    }
#endif
