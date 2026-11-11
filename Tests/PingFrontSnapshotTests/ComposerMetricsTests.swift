#if canImport(UIKit)
    import SwiftUI
    import UIKit
    import XCTest
    import PingFrontCore
    @testable import PingFrontUI

    /// Measures the laid-out composer against Messages on iOS 26: the + circle is as tall as the one-line field and
    /// shares its center (within 0.5 pt) at every text size, stays on the field's last line when the field grows,
    /// keeps one gap, and starts at the thread's edge, in both directions.
    @MainActor
    final class ComposerMetricsTests: XCTestCase {
        /// An iPhone 17's width.
        let width: CGFloat = 402
        let theme = ChatTheme.standard

        final class Frames {
            var parts: [String: CGRect] = [:]
        }

        func testOneLineCentersAlignAtDefaultAndAX3() async throws {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let frames = try await layout(size: size)
                let plus = try XCTUnwrap(frames["plus"])
                let field = try XCTUnwrap(frames["field"])
                XCTAssertEqual(plus.midY, field.midY, accuracy: 0.5, "centers at \(size)")
                XCTAssertEqual(plus.width, ComposerMetrics.plusDiameter, accuracy: 0.01, "+ size at \(size)")
                XCTAssertEqual(plus.height, ComposerMetrics.plusDiameter, accuracy: 0.01)
                if size == .large {
                    // At the default size the one-line field is exactly as tall as the + (Messages: both 122 px at 3x).
                    XCTAssertEqual(field.height, ComposerMetrics.plusDiameter, accuracy: 0.5)
                }
            }
        }

        func testEveryTextSizeKeepsOneCenter() async throws {
            for size in DynamicTypeSize.allCases {
                let frames = try await layout(size: size)
                let plus = try XCTUnwrap(frames["plus"])
                let field = try XCTUnwrap(frames["field"])
                XCTAssertEqual(plus.midY, field.midY, accuracy: 0.5, "centers at \(size)")
                XCTAssertGreaterThanOrEqual(field.height + 0.5, plus.height, "the field is never shorter than the + at \(size)")
            }
        }

        func testGapAndEdgesLeftToRight() async throws {
            let frames = try await layout(size: .large)
            let plus = try XCTUnwrap(frames["plus"])
            let field = try XCTUnwrap(frames["field"])
            XCTAssertEqual(plus.minX, theme.gutter, accuracy: 0.5, "the + starts at the thread's edge")
            XCTAssertEqual(field.minX - plus.maxX, ComposerMetrics.gap(theme), accuracy: 0.5, "one gap")
            XCTAssertEqual(width - field.maxX, theme.gutter, accuracy: 0.5, "the field ends at the thread's edge")
        }

        func testGapAndEdgesRightToLeft() async throws {
            let frames = try await layout(size: .large, rightToLeft: true)
            let plus = try XCTUnwrap(frames["plus"])
            let field = try XCTUnwrap(frames["field"])
            XCTAssertEqual(width - plus.maxX, theme.gutter, accuracy: 0.5, "the + starts at the thread's edge")
            XCTAssertEqual(plus.minX - field.maxX, ComposerMetrics.gap(theme), accuracy: 0.5, "one gap")
            XCTAssertEqual(field.minX, theme.gutter, accuracy: 0.5)
            XCTAssertEqual(plus.midY, field.midY, accuracy: 0.5)
        }

        func testGrownFieldKeepsThePlusOnItsLastLine() async throws {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let one = try await layout(size: size)
                let grown = try await layout(size: size, draft: "First line\nSecond line\nThird line")
                let field = try XCTUnwrap(grown["field"])
                let plus = try XCTUnwrap(grown["plus"])
                let oneLine = try XCTUnwrap(one["field"]).height
                XCTAssertGreaterThan(field.height, oneLine + 20, "the field grew at \(size)")
                // The + is centered on the last line: half a one-line field above the field's bottom.
                XCTAssertEqual(plus.midY, field.maxY - oneLine / 2, accuracy: 0.5, "last line at \(size)")
            }
        }

        private func layout(size: DynamicTypeSize, rightToLeft: Bool = false, draft: String = "") async throws -> [String: CGRect] {
            let pingFront = PingFront.preview(.conversation)
            pingFront.conversation.draft = draft
            let frames = Frames()
            let probe = ComposerProbe { part, frame in frames.parts[part] = frame }
            let view = ComposerView(pingFront: pingFront)
                .environment(\.composerProbe, probe)
                .environment(\.dynamicTypeSize, size)
                .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .bottom)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 874))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            window.isHidden = true
            return frames.parts
        }
    }
#endif
