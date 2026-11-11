#if canImport(UIKit)
    import SwiftUI
    import UIKit
    import XCTest
    @testable import PingFrontUI

    /// At the largest text sizes the composer's placeholder wraps instead of truncating ("Message De…"), and the empty
    /// field is as tall as the wrapped placeholder.
    @MainActor
    final class ComposerPlaceholderTests: XCTestCase {
        func testThePlaceholderWrapsAtAX5() {
            let font = ComposerField.font(size: .accessibility5, design: nil)
            // The field's width on an iPhone 17 Pro Max at AX5 (measured: about 280 pt beside the +).
            let height = ComposerField.placeholderHeight("Message Deniz", font: font, width: 280)
            XCTAssertGreaterThan(height, font.lineHeight * 1.5, "two lines, not one truncated line")
        }

        func testAShortPlaceholderStaysOneLine() {
            let font = ComposerField.font(size: .large, design: nil)
            let height = ComposerField.placeholderHeight("Message Deniz", font: font, width: 280)
            XCTAssertLessThan(height, font.lineHeight * 1.5)
        }
    }
#endif
