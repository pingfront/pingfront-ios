#if canImport(UIKit) && DEBUG
    public import UIKit
    import SwiftUI
    @_spi(Fixtures) import PingFrontCore

    /// Opens the chat as the SDK's sheet in the running window scene, lets messages arrive, and measures how far the
    /// thread sits from its end after each one.
    ///
    /// A message that arrives while the thread is at its end keeps the end in view, however tall it lays out; the
    /// person's own message always brings the end into view; a team message leaves a thread the person scrolled up
    /// where it is.
    @_spi(Snapshots)
    public enum ThreadFollow {
        /// Points between the visible bottom of the thread and its end (0 at the end), once each step settled.
        public struct Result: Sendable {
            /// Opened, before anything arrives.
            public let opened: CGFloat
            /// After a long team message arrived at the end.
            public let teamMessageAtEnd: CGFloat
            /// Scrolled to the top by the person, before the next message.
            public let scrolledUp: CGFloat
            /// After a team message arrived while the thread was scrolled to its top.
            public let teamMessageScrolledUp: CGFloat
            /// After the person's own message arrived while the thread was scrolled to its top.
            public let ownMessageScrolledUp: CGFloat
        }

        /// Opens the chat in `scene`, lets three messages arrive and measures each step.
        public static func run(scene: UIWindowScene) async throws -> Result {
            let pingFront = PingFront.preview(.conversation)
            var preview = ChatPreviewState()
            preview.isOffline = true
            let chat = PingFrontChatView(topic: nil, showsClose: true)
                .environment(\.pingFrontInstance, pingFront)
                .environment(\.chatPreview, preview)
            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = .light
            let root = UIHostingController(rootView: Color(uiColor: .systemBackground).ignoresSafeArea())
            window.rootViewController = root
            window.makeKeyAndVisible()
            defer {
                root.presentedViewController?.dismiss(animated: false)
                window.isHidden = true
            }
            let host = UIHostingController(rootView: chat)
            SheetPresenter.configureSheet(host)
            root.present(host, animated: false)

            let opened = try await settled(in: host)
            arrive(pingFront, from: .team, text: String(repeating: "A long answer that wraps over several lines. ", count: 8))
            let teamMessageAtEnd = try await settled(in: host)

            // The thread keeps following its end for 3 s after a message arrives (rows that grow late); the person
            // scrolls up after that.
            try await Task.sleep(for: .seconds(3.2))
            try scrollToTop(in: host)
            let scrolledUp = try await settled(in: host)
            arrive(pingFront, from: .team, text: "Another message from the team.")
            let teamMessageScrolledUp = try await settled(in: host)

            try scrollToTop(in: host)
            _ = try await settled(in: host)
            arrive(pingFront, from: .person, text: "Thanks, that helps.")
            let ownMessageScrolledUp = try await settled(in: host)

            return Result(
                opened: opened, teamMessageAtEnd: teamMessageAtEnd, scrolledUp: scrolledUp, teamMessageScrolledUp: teamMessageScrolledUp,
                ownMessageScrolledUp: ownMessageScrolledUp)
        }

        private static func arrive(_ pingFront: PingFront, from kind: Author.Kind, text: String) {
            let messages = pingFront.conversation.messages
            let seq = (messages.map(\.seq).max() ?? 0) + 1
            let author = kind == .person ? Author(kind: .person) : Author(kind: .team, id: "m_deniz", name: "Deniz")
            pingFront.conversation.messages =
                messages + [
                    Message(id: "follow_\(seq)", seq: seq, author: author, parts: [.text(text)], createdAt: .now)
                ]
        }

        /// The thread's scroll view: the tallest one that isn't a text view (the composer's field is one).
        private static func thread(in host: UIViewController) throws -> UIScrollView {
            var found: [UIScrollView] = []
            var stack: [UIView] = [host.view]
            while let view = stack.popLast() {
                if let scroll = view as? UIScrollView, !(view is UITextView) { found.append(scroll) }
                stack += view.subviews
            }
            guard let thread = found.max(by: { $0.bounds.height < $1.bounds.height }) else { throw Missing.thread }
            return thread
        }

        private enum Missing: Error { case thread }

        private static func remaining(_ scroll: UIScrollView) -> CGFloat {
            scroll.contentSize.height + scroll.adjustedContentInset.bottom - (scroll.contentOffset.y + scroll.bounds.height)
        }

        private static func scrollToTop(in host: UIViewController) throws {
            let scroll = try thread(in: host)
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        }

        /// The distance from the end once it stopped changing (animations and late layout done), at most 4 s.
        private static func settled(in host: UIViewController) async throws -> CGFloat {
            var last = CGFloat.nan
            var steady = 0
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                let now = remaining(try thread(in: host))
                steady = abs(now - last) < 0.5 ? steady + 1 : 0
                last = now
                if steady >= 4 { break }
            }
            return last
        }
    }
#endif
