#if canImport(UIKit)
    import CoreGraphics
    import XCTest
    @testable import PingFrontReports

    /// Marks on a bug report's screenshot are kept in the screenshot's unit square, so they stay on their spot
    /// when the sheet resizes (rotating, folding or unfolding the device, Split View) and in the sent image.
    final class ReportMarkupTests: XCTestCase {
        func testMarksKeepTheirSpotWhenTheScreenshotResizes() {
            // A mark made on a 300 pt wide canvas lands on the same spot of a 420 pt canvas and of the image.
            let unit = Markup.unit(CGPoint(x: 150, y: 100), in: CGSize(width: 300, height: 400))
            XCTAssertEqual(unit, CGPoint(x: 0.5, y: 0.25))
            XCTAssertEqual(Markup.points([unit], in: CGSize(width: 420, height: 560)), [CGPoint(x: 210, y: 140)])
            XCTAssertEqual(Markup.points([unit], in: CGSize(width: 1398, height: 2034)), [CGPoint(x: 699, y: 508.5)])
            XCTAssertEqual(Markup.unit(CGPoint(x: 1, y: 1), in: .zero), .zero)
        }
    }
#endif
