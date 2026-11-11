#if canImport(UIKit)
    import SwiftUI
    package import UIKit
    import SafariServices
    import StoreKit
    internal import os
    import PingFrontCore

    /// Presents the chat from anywhere, as a form sheet (see `configureSheet(_:)`).
    final class SheetPresenter: ChatPresenting, ReportsChatDismissal {
        /// The SDK instance this presenter shows (set when the module installs).
        private weak var pingFront: PingFront?
        private weak var presented: UIViewController?
        private var pending: Task<Void, Never>?
        private var opening: Task<Void, Never>?

        init(pingFront: PingFront) { self.pingFront = pingFront }

        func presentChat(topic: ChatTopic?) {
            pending?.cancel()
            pending = nil
            if present(topic: topic) { return }
            // At launch (for example `-PingFrontPreview`) there may be no window yet: present when a scene
            // becomes active. Another open or a close cancels the wait.
            Log.config(.info)?.info("openChat: no foreground window yet; the chat opens when the app becomes active.")
            pending = Task { [weak self] in
                let activations = NotificationCenter.default.notifications(named: UIScene.didActivateNotification).map { _ in () }
                // Checked again after subscribing, so an activation in between is not missed. Once presented, nothing
                // is pending any more (`isPresentingChat` then follows the sheet).
                if self?.present(topic: topic) != false {
                    self?.pending = nil
                    return
                }
                for await _ in activations {
                    if self?.present(topic: topic) != false {
                        self?.pending = nil
                        return
                    }
                }
            }
        }

        private func present(topic: ChatTopic?) -> Bool {
            if let presented, presented.presentingViewController != nil { return true }
            guard let pingFront, let top = Presentation.topViewController() else { return false }
            // A bug report started inside the chat should show the app's screen, not the chat.
            Presentation.screenBeforeChat = Presentation.snapshot(of: top.view.window)
            let host = UIHostingController(
                rootView: PingFrontChatView(topic: topic, showsClose: true).environment(\.pingFrontInstance, pingFront))
            Self.configureSheet(host)
            top.present(host, animated: true)
            presented = host
            return true
        }

        /// The chat's sheet, chosen by the space it gets rather than by the device.
        ///
        /// A form sheet adapts on its own: in compact width it is the large-detent sheet, and in regular width
        /// (iPad, a foldable iPhone's inner display) a centered card capped at a reading size, which the system
        /// moves out of a fold. It adapts again when the device folds or unfolds while the chat is open. The
        /// grabber shows in both, as with `.pingFrontChat(isPresented:)`.
        static func configureSheet(_ host: UIViewController) {
            host.modalPresentationStyle = .formSheet
            host.preferredContentSize = CGSize(width: 640, height: 820)
            host.sheetPresentationController?.detents = [.large()]
            host.sheetPresentationController?.prefersGrabberVisible = true
        }

        func dismissChat() {
            Presentation.screenBeforeChat = nil
            pending?.cancel()
            pending = nil
            // From the controller that presented the sheet: that dismisses the sheet and anything over it (the photo
            // picker, a report). Called on the sheet itself, UIKit would dismiss only what the sheet presented.
            presented?.presentingViewController?.dismiss(animated: true)
            presented = nil
        }

        /// The sheet is up (its own presenting controller says so: a sheet the person swiped away has none), or waits
        /// for a window to open in.
        var isPresentingChat: Bool { pending != nil || presented?.presentingViewController != nil }

        func dismissChatAndWait() async {
            Presentation.screenBeforeChat = nil
            pending?.cancel()
            pending = nil
            guard let presenter = presented?.presentingViewController else {
                presented = nil
                return
            }
            presented = nil
            // Dismissed from its presenter, so a photo picker or report over the sheet goes with it.
            await withCheckedContinuation { continuation in presenter.dismiss(animated: true) { continuation.resume() } }
        }

        /// Web links open in an in-app Safari view over the chat; other schemes go to the system.
        func open(_ url: URL) {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let top = Presentation.topViewController() {
                let safari = SFSafariViewController(url: url)
                safari.dismissButtonStyle = .close
                top.present(safari, animated: true)
                return
            }
            opening?.cancel()
            opening = Task { _ = await UIApplication.shared.open(url) }
        }

        /// Web links in Safari, other schemes through the system: false when nothing could open it.
        func openLink(_ url: URL) async -> Bool {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                guard let top = Presentation.topViewController() else { return false }
                let safari = SFSafariViewController(url: url)
                safari.dismissButtonStyle = .close
                top.present(safari, animated: true)
                return true
            }
            // https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:)
            return await UIApplication.shared.open(url)
        }

        func presentSimpleReport() {
            guard let pingFront, let top = Presentation.topViewController() else { return }
            let host = UIHostingController(rootView: SimpleReportSheet(pingFront: pingFront).pingFrontLanguage(pingFront))
            host.modalPresentationStyle = .formSheet
            top.present(host, animated: true)
        }

    }

    /// Apple's review prompt (`AppStore.requestReview(in:)`).
    ///
    /// Apple decides whether it shows.
    final class NativeReviewRequester: ReviewRequesting {
        func requestReview() async -> Bool {
            guard let scene = Presentation.activeScene() else { return false }
            AppStore.requestReview(in: scene)
            return true
        }
    }

    /// Where SDK UI is presented from.
    ///
    /// The one place that looks up windows.
    package enum Presentation {
        /// The app's screen right before the SDK presented the chat; reports from inside the chat use it.
        package static var screenBeforeChat: UIImage?

        /// The window as the person sees it.
        package static func snapshot(of window: UIWindow?) -> UIImage? {
            guard let window else { return nil }
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            return renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        }

        /// The foreground scene, or the first connected one.
        package static func activeScene() -> UIWindowScene? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        }

        /// The topmost presented view controller of the key window.
        package static func topViewController() -> UIViewController? {
            let scene = activeScene()
            guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first, var top = window.rootViewController
            else { return nil }
            while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            return top
        }
    }

    /// A plain text bug report, used when the reports module is not installed.
    struct SimpleReportSheet: View {
        let pingFront: PingFront
        @Environment(\.dismiss) private var dismiss
        @Environment(\.locale) private var locale
        @Environment(\.chatTheme) private var theme
        @State private var text = ""
        @State private var submission: UUID?
        @State private var failed = false

        var body: some View {
            let t = L10n(locale)
            NavigationStack {
                Form {
                    Section(t("What went wrong?")) {
                        TextField(t("What went wrong?"), text: $text, axis: .vertical).lineLimit(4...12)
                    }
                    if failed {
                        Text(t("Not sent.")).foregroundStyle(theme.stop)
                    }
                }
                .task(id: submission) {
                    // The send is owned by the view: leaving the sheet cancels it.
                    guard submission != nil else { return }
                    do {
                        try await pingFront.reportBug(text: text)
                        dismiss()
                    } catch { failed = true }
                    submission = nil
                }
                .navigationTitle(t("Report a bug"))
                .navigationBarTitleDisplayMode(.inline)
                // Symbols with titles, like the reports module's sheet, so the system can move them into the
                // vertical bar where a display puts its controls at the side.
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if #available(iOS 26, *) {
                            Button(role: .close) { dismiss() }.accessibilityLabel(t("Cancel"))
                        } else {
                            Button(t("Cancel")) { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Group {
                            if #available(iOS 26, *) {
                                Button {
                                    submission = UUID()
                                } label: {
                                    Label(t("Send report"), systemImage: "arrow.up").labelStyle(.iconOnly)
                                }
                                .buttonStyle(.glassProminent)
                            } else {
                                Button(t("Send report")) { submission = UUID() }
                            }
                        }
                        .accessibilityLabel(t("Send report"))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submission != nil)
                    }
                }
            }
        }
    }

    /// Values inferred from the host app: display name, AccentColor asset, icon.
    enum HostApp {
        static var displayName: String {
            let info = Bundle.main.infoDictionary
            return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName
        }

        /// The AccentColor asset resolved for light and dark (falls back to system blue when the app has none).
        static var accent: PingFrontColor {
            PingFrontColor(Color.accentColor)
        }

        /// The primary app icon as a PNG of `edge` pixels, when it can be read from the bundle.
        ///
        /// One key per icon image, so different looks never show each other's icon.
        static func iconKey(_ png: Data) -> String { "pingfront.host-icon.\(png.count).\(png.hashValue)" }

        /// The app icon as a PNG, rendered once per app version and cached in Caches.
        @concurrent static func iconPNG(edge: CGFloat) async -> Data? {
            let version = DeviceInfo.appVersion.filter { $0.isLetter || $0.isNumber || $0 == "." }
            let cache = URL.cachesDirectory.appending(path: "pingfront-host-icon-\(version)-\(Int(edge)).png")
            if let data = try? Data(contentsOf: cache) { return data }
            guard let data = renderIcon(edge: edge) else { return nil }
            try? data.write(to: cache, options: .atomic)
            return data
        }

        private nonisolated static func renderIcon(edge: CGFloat) -> Data? {
            guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
                let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                let files = primary["CFBundleIconFiles"] as? [String],
                let name = files.last,
                let image = UIImage(named: name)
            else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format)
            return renderer.pngData { _ in image.draw(in: CGRect(x: 0, y: 0, width: edge, height: edge)) }
        }
    }
#endif
