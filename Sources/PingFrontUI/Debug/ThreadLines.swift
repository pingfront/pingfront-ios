#if canImport(UIKit) && DEBUG
    public import UIKit
    import SwiftUI
    @_spi(Fixtures) import PingFrontCore

    /// Measures the thread's centered system lines (the ping line and the receipt lines) against the thread, in the
    /// running window scene: brand.md centers them on the whole thread width, never on the bubble column.
    ///
    /// The thread has a ping, a system receipt and a team message that carries a receipt part next to its text. Each
    /// presentation (embedded in a navigation stack, or the SDK's sheet) renders it left to right and right to left.
    @_spi(Snapshots)
    public enum ThreadLines {
        /// One line's frame next to the thread's, in window coordinates.
        public struct Measure: Sendable {
            /// "embedded ltr", "sheet rtl".
            public let presentation: String
            /// "line ping", "line receipt Trial extended to 14 Nov".
            public let line: String
            /// The line's own content (dot or check, and text).
            public let frame: CGRect
            /// The thread's column.
            public let thread: CGRect
        }

        /// The receipt in the system message.
        public static let systemReceipt = "Trial extended to 14 Nov"
        /// The receipt carried by a team message next to its text.
        public static let teamReceipt = "Refund requested"

        /// Every line in every presentation, measured in `scene`.
        public static func measure(scene: UIWindowScene) async throws -> [Measure] {
            var all: [Measure] = []
            for sheet in [false, true] {
                for rightToLeft in [false, true] {
                    all += try await render(scene: scene, sheet: sheet, rightToLeft: rightToLeft)
                }
            }
            return all
        }

        @MainActor
        private final class Reports {
            var frames: [String: CGRect] = [:]
        }

        private static func render(scene: UIWindowScene, sheet: Bool, rightToLeft: Bool) async throws -> [Measure] {
            let pingFront = PingFront.preview(.conversation)
            pingFront.conversation.messages = messages
            var preview = ChatPreviewState()
            preview.isOffline = true
            preview.now = SnapshotMatrix.fixedNow
            preview.scrolledToTop = true
            let reports = Reports()
            let probe = ComposerProbe(report: { part, frame in
                if part == "thread column" || part.hasPrefix("line ") { reports.frames[part] = frame }
            })
            let chat = PingFrontChatView(topic: nil, showsClose: sheet)
                .environment(\.pingFrontInstance, pingFront)
                .environment(\.chatPreview, preview)
                .environment(\.composerProbe, probe)
                .environment(\.locale, Locale(identifier: rightToLeft ? "ar" : "en"))
                .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = .light
            let root: UIViewController
            if sheet {
                root = UIHostingController(rootView: Color(uiColor: .systemBackground).ignoresSafeArea())
            } else {
                root = UIHostingController(
                    rootView: NavigationStack { chat.navigationTitle("Help").navigationBarTitleDisplayMode(.inline) })
            }
            window.rootViewController = root
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(600))
            if sheet {
                let host = UIHostingController(rootView: chat)
                SheetPresenter.configureSheet(host)
                root.present(host, animated: false)
                try await Task.sleep(for: .milliseconds(900))
            }
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true

            let name = "\(sheet ? "sheet" : "embedded") \(rightToLeft ? "rtl" : "ltr")"
            guard let thread = reports.frames["thread column"] else { return [] }
            return reports.frames.filter { $0.key.hasPrefix("line ") }.sorted { $0.key < $1.key }.map {
                Measure(presentation: name, line: $0.key, frame: $0.value, thread: thread)
            }
        }

        private static var messages: [Message] {
            let at = { (minutes: Double) in SnapshotMatrix.fixedNow.addingTimeInterval(-3_600 + minutes * 60) }
            let deniz = Author(kind: .team, id: "m_deniz", name: "Deniz", avatarURL: Fixtures.deniz.avatarURL)
            return [
                Message(
                    id: "line_1", seq: 1, author: deniz, parts: [.text("Hi, I'm Deniz. Anything unclear about Pro?")], createdAt: at(0),
                    ping: PingOrigin(kind: .play, playId: "play_1", explanation: "Sent automatically after you closed Plans")),
                Message(id: "line_2", seq: 2, author: Author(kind: .person), parts: [.text("Can I try it first?")], createdAt: at(1)),
                Message(
                    id: "line_3", seq: 3, author: Author(kind: .system),
                    parts: [.receipt(ReceiptPart(action: .custom, text: systemReceipt))],
                    createdAt: at(2)),
                Message(
                    id: "line_4", seq: 4, author: deniz,
                    parts: [
                        .text("Done, and I asked Apple to refund last month."), .receipt(ReceiptPart(action: .custom, text: teamReceipt)),
                    ],
                    createdAt: at(3)),
            ]
        }
    }
#endif
