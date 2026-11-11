#if canImport(UIKit)
    import CoreGraphics
    import XCTest
    @testable import PingFrontUI

    /// Where the chat goes when a fold divides it, from the space it has and the folds the system reports.
    ///
    /// The numbers are a foldable iPhone's inner display (951 × 669 pt landscape, the vertical bar's 84 pt
    /// on the trailing side), but nothing in the code knows them: these are only inputs.
    final class FoldLayoutTests: XCTestCase {
        /// A fold down the middle of a 951 pt wide view, as reported while partly folded like a book.
        let bookFold = CGRect(x: 461, y: 0, width: 29, height: 669)

        func testNoFoldKeepsTheColumnCentered() {
            XCTAssertEqual(FoldPlacement.column(width: 867, safeLeading: 0, safeTrailing: 0, folds: []), .none)
        }

        func testABookFoldMovesTheColumnIntoTheLargerRegion() {
            // The bar on the trailing side leaves more room on the leading side: the column ends at the fold.
            let placement = FoldPlacement.column(width: 951, safeLeading: 0, safeTrailing: 84, folds: [bookFold])
            XCTAssertEqual(placement, FoldPlacement(leading: 0, trailing: 951 - 461))
        }

        func testTheSafeAreaDecidesTheSideNotTheDevice() {
            // In Split View on the right, the bar is on the leading side: the column moves to the trailing region.
            let placement = FoldPlacement.column(width: 951, safeLeading: 84, safeTrailing: 0, folds: [bookFold])
            XCTAssertEqual(placement, FoldPlacement(leading: 490, trailing: 0))
        }

        func testAnEvenSplitPrefersTheLeadingRegion() {
            let placement = FoldPlacement.column(width: 951, safeLeading: 0, safeTrailing: 0, folds: [bookFold])
            XCTAssertEqual(placement.leading, 0)
            XCTAssertEqual(placement.trailing, 490)
        }

        func testAFoldAcrossTheChatLeavesTheColumnAlone() {
            // Propped like a laptop: the composer is already in the lower region and the thread scrolls across.
            let tabletop = CGRect(x: 0, y: 461, width: 669, height: 29)
            XCTAssertEqual(FoldPlacement.column(width: 669, safeLeading: 0, safeTrailing: 0, folds: [tabletop]), .none)
        }

        func testAFoldClippingAnEdgeKeepsTheColumnOffIt() {
            // The system moves a sheet beside the fold, but the sheet still overlaps the fold's margin: the
            // sheet's chat (458 pt wide, from x 8) sees the fold from x 447.5 and keeps its column before it.
            let clipped = CGRect(x: 447.5, y: 0, width: 40, height: 669)
            XCTAssertEqual(
                FoldPlacement.column(width: 458, safeLeading: 0, safeTrailing: 0, folds: [clipped]), FoldPlacement(leading: 0, trailing: 11)
            )
            let leadingEdge = CGRect(x: -30, y: 0, width: 40, height: 669)
            XCTAssertEqual(
                FoldPlacement.column(width: 460, safeLeading: 0, safeTrailing: 0, folds: [leadingEdge]),
                FoldPlacement(leading: 10, trailing: 0))
        }

        func testAFoldOutsideTheChatOrUnderTheBarIsIgnored() {
            let outside = CGRect(x: 470, y: 0, width: 40, height: 669)
            XCTAssertEqual(FoldPlacement.column(width: 460, safeLeading: 0, safeTrailing: 0, folds: [outside]), .none)
            let underBar = CGRect(x: 870, y: 0, width: 20, height: 669)
            XCTAssertEqual(FoldPlacement.column(width: 951, safeLeading: 0, safeTrailing: 84, folds: [underBar]), .none)
        }

        func testTheWelcomeBreaksAroundAFoldAcrossIt() {
            let size = CGSize(width: 669, height: 700)
            XCTAssertEqual(
                WelcomeFold.across(size: size, folds: [CGRect(x: 0, y: 380, width: 669, height: 29)]), WelcomeFold(top: 380, bottom: 409))
            // A book fold runs down the welcome, not across it.
            XCTAssertNil(WelcomeFold.across(size: size, folds: [CGRect(x: 320, y: 0, width: 29, height: 700)]))
            XCTAssertNil(WelcomeFold.across(size: size, folds: []))
        }
    }
#endif
