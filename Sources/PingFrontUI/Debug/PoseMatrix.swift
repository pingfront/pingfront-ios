#if canImport(UIKit) && DEBUG
    public import UIKit
    import SwiftUI
    @_spi(Fixtures) import PingFrontCore

    /// The chat in a foldable iPhone's poses, rendered in the running window scene at its real size, safe area
    /// and folds, so what the images show is what the system gives the SDK.
    ///
    /// A host app's test runs once per pose, set on the iPhone Duo simulator with `foldctl`; nothing here knows
    /// the device. Each state also reports where its controls ended up and where the active folds are, so the test
    /// can check that no control sits in a fold.
    ///
    /// Images go to `<directory>/<pose>-<state>.png`, listed in that folder's `manifest.json`.
    @_spi(Snapshots)
    public final class PoseMatrix {
        /// A control's frame in one state, next to the folds active while it was rendered (window coordinates).
        public struct Placement: Sendable {
            /// The rendered state ("embedded-conversation").
            public let state: String
            /// The control ("field", "plus", "topics").
            public let part: String
            /// Where the control was.
            public let frame: CGRect
            /// The folds active at the time.
            public let folds: [CGRect]
            /// The window's bounds.
            public let window: CGRect
        }

        /// What one pose rendered.
        public struct Result: Sendable {
            /// Images written.
            public let count: Int
            /// Renders that fell back to `layer.render`.
            public let fallbacks: Int
            /// Every control measured, in every state.
            public let placements: [Placement]
        }

        /// `iphoneduo` in ``SnapshotMatrix/defaultDirectory``.
        public static var defaultDirectory: URL { SnapshotMatrix.defaultDirectory.appending(path: "iphoneduo") }

        /// A half of the display, as Split View gives an app.
        ///
        /// The system's Split View can't be entered from a script (it takes the home-indicator drag), so this is
        /// simulated: a window over one half of the live scene, compact width, with the side bar's room on the
        /// half's outer edge, where Split View puts an app's controls. The scene's own insets still apply, so
        /// on the right half the system's bar is real.
        public enum SplitHalf: String, Sendable {
            case left, right
        }

        /// The room the side bar takes on a half's outer edge in the simulated Split View (the vertical bar's
        /// width in Apple's iPhone Duo templates).
        ///
        /// A fixture value for the simulation, never used for layout.
        static let simulatedSideBar: CGFloat = 84

        private let pose: String
        private let split: SplitHalf?
        private let scene: UIWindowScene
        private let directory: URL
        private var entries: [SnapshotMatrix.Entry] = []
        private var placements: [Placement] = []
        private var fallbacks = 0
        /// Control frames reported by the probes during the current render.
        private var reported: [String: CGRect] = [:]
        private var folds: [CGRect] = []

        private init(pose: String, split: SplitHalf?, scene: UIWindowScene, directory: URL) {
            self.pose = split.map { "\(pose)-split-\($0.rawValue)" } ?? pose
            self.split = split
            self.scene = scene
            self.directory = directory
        }

        /// Renders every state for the current pose into `directory` and merges them into its manifest.
        ///
        /// `pose` only names the files ("half-book"); the layout comes from the scene as it is. With `split`,
        /// each state is rendered in one half instead (see `SplitHalf`).
        public static func render(pose: String, split: SplitHalf? = nil, to directory: URL = defaultDirectory, scene: UIWindowScene)
            async throws -> Result
        {
            let matrix = PoseMatrix(pose: pose, split: split, scene: scene, directory: directory)
            try await matrix.renderAll()
            return Result(count: matrix.entries.count, fallbacks: matrix.fallbacks, placements: matrix.placements)
        }

        private func renderAll() async throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FixtureImages.install()
            try await shot(
                "embedded-conversation", title: "Embedded chat, conversation", fixture: .conversation,
                notes:
                    "PingFrontChatView pushed in the host's navigation stack at full width. Folded like a book, the column moves into one region.",
                root: { self.embedded($0, $1) })
            try await shot(
                "embedded-welcome", title: "Embedded chat, welcome", fixture: .welcome,
                notes: "The welcome at full width. Propped like a laptop, the words stay above the fold and the topics move below it.",
                root: { self.embedded($0, $1) })
            try await shot(
                "sheet-conversation", title: "SDK sheet, conversation", fixture: .conversation,
                notes: "openChat(): a form sheet with the close control in the system bar (vertical on the outer display).",
                root: { _, _ in self.backdrop() },
                presented: { pingFront, preview in
                    let host = UIHostingController(rootView: self.chat(PingFrontChatView(topic: nil, showsClose: true), pingFront, preview))
                    SheetPresenter.configureSheet(host)
                    return host
                })
            try await shot(
                "sheet-welcome", title: "SDK sheet, welcome", fixture: .welcome,
                notes: "The welcome in the SDK's sheet.",
                root: { _, _ in self.backdrop() },
                presented: { pingFront, preview in
                    let host = UIHostingController(rootView: self.chat(PingFrontChatView(topic: nil, showsClose: true), pingFront, preview))
                    SheetPresenter.configureSheet(host)
                    return host
                })
            try await shot(
                "photo-viewer", title: "Full-screen photo over the chat", fixture: .conversation,
                notes: "The photo viewer's system bars: close and share move to the side where the display puts controls there.",
                root: { self.embedded($0, $1) },
                presented: { pingFront, _ in
                    let viewer = UIHostingController(
                        rootView: PhotoViewer(
                            part: ImagePart(attachmentId: "att_landscape", width: 1170, height: 1560, url: nil), pingFront: pingFront,
                            sender: "Ada", date: SnapshotMatrix.fixedNow.addingTimeInterval(-3_600)))
                    viewer.modalPresentationStyle = .fullScreen
                    return viewer
                })
            try await shot(
                "report", title: "Bug report sheet over the chat", fixture: .conversation,
                notes: "The bug report form sheet; the system moves it out of a fold.",
                root: { self.embedded($0, $1) },
                presented: { pingFront, _ in
                    let report = UIHostingController(rootView: SimpleReportSheet(pingFront: pingFront).pingFrontLanguage(pingFront))
                    report.modalPresentationStyle = .formSheet
                    return report
                })

            // One manifest for every pose: this pose's entries replace their earlier versions.
            let manifest = directory.appending(path: "manifest.json")
            let earlier =
                (try? Data(contentsOf: manifest)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            let mine = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)) as? [[String: Any]] ?? []
            let files = Set(mine.compactMap { $0["file"] as? String })
            let all = (earlier.filter { !files.contains($0["file"] as? String ?? "") } + mine)
                .sorted { ($0["file"] as? String ?? "") < ($1["file"] as? String ?? "") }
            try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: manifest)
        }

        // MARK: Building

        /// The chat as a host app pushes it: inside its navigation stack, under its bar.
        private func embedded(_ pingFront: PingFront, _ preview: ChatPreviewState) -> UIViewController {
            UIHostingController(
                rootView: NavigationStack {
                    chat(PingFrontChatView(), pingFront, preview)
                        .navigationTitle("Help")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .background { foldProbe })
        }

        private func chat(_ view: PingFrontChatView, _ pingFront: PingFront, _ preview: ChatPreviewState) -> some View {
            view
                .environment(\.pingFrontInstance, pingFront)
                .environment(\.chatPreview, preview)
                // Controls only: thread rows scroll, and scrolling content may pass the fold and leave the screen.
                .environment(
                    \.composerProbe,
                    ComposerProbe(report: { [weak self] part, frame in
                        if !part.hasPrefix("row "), !part.hasPrefix("line "), part != "thread column" { self?.reported[part] = frame }
                    })
                )
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.timeZone, TimeZone(identifier: "Europe/Berlin") ?? .gmt)
        }

        /// The host app's screen behind a sheet.
        private func backdrop() -> UIViewController {
            UIHostingController(rootView: HostAppBackdrop().environment(\.colorScheme, .light).background { foldProbe })
        }

        /// Reports the active folds in window coordinates.
        private var foldProbe: some View {
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: [CGRect].self) { proxy in
                    let origin = proxy.frame(in: .global).origin
                    return Folds.active(in: proxy).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
                } action: { [weak self] folds in
                    self?.folds = folds
                }
        }

        // MARK: Rendering

        private func shot(
            _ state: String, title: String, fixture: PreviewFixture, notes: String,
            root: (PingFront, ChatPreviewState) -> UIViewController,
            presented: ((PingFront, ChatPreviewState) -> UIViewController)? = nil
        ) async throws {
            let app = Fixtures.app(forVariant: "default")
            let host = HostAppInfo(
                appName: app.name, accent: PingFrontColor(light: "#007AFF", dark: "#0A84FF"),
                iconPNG: FixtureImages.appIcon(app.id).pngData(), appVersion: "1.0 (1)")
            let pingFront = PingFront.preview(fixture, host: host, app: app)
            var preview = ChatPreviewState()
            preview.isOffline = true
            preview.now = SnapshotMatrix.fixedNow
            if fixture == .conversation { preview.scrollTarget = "msg_10" }
            reported = [:]
            folds = []

            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = .light
            let controller = root(pingFront, preview)
            if let split {
                let whole = scene.coordinateSpace.bounds
                let half = whole.width / 2
                window.frame = CGRect(x: split == .left ? 0 : half, y: 0, width: half, height: whole.height)
                controller.traitOverrides.horizontalSizeClass = .compact
                // The left half's controls go on its left edge; the right half's are the system's own bar.
                if split == .left { controller.additionalSafeAreaInsets.left = Self.simulatedSideBar }
            }
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(600))
            if let presented {
                controller.present(presented(pingFront, preview), animated: false)
                try await Task.sleep(for: .milliseconds(900))
            }
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))

            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            format.opaque = true
            var drew = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
                drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                if !drew { window.layer.render(in: context.cgContext) }
            }
            if !drew { fallbacks += 1 }
            for (part, frame) in reported.sorted(by: { $0.key < $1.key }) {
                placements.append(Placement(state: state, part: part, frame: frame, folds: folds, window: window.bounds))
            }
            controller.presentedViewController?.dismiss(animated: false)
            window.isHidden = true

            let file = "\(pose)-\(state).png"
            guard let png = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: directory.appending(path: file))
            let size = window.bounds.size
            entries.append(
                SnapshotMatrix.Entry(
                    file: "iphoneduo/\(file)", title: "\(title), \(pose.replacingOccurrences(of: "-", with: " "))",
                    device: split == nil ? "iPhone Duo simulator (\(pose))" : "iPhone Duo simulator (\(pose), simulated Split View)",
                    points: [Int(size.width), Int(size.height)], scale: 2, scheme: "light",
                    textSize: "default", locale: "en", direction: "ltr", state: state, look: "default",
                    notes: notes
                        + (folds.isEmpty
                            ? ""
                            : " Active fold at x \(Int(folds[0].minX))–\(Int(folds[0].maxX)), y \(Int(folds[0].minY))–\(Int(folds[0].maxY)).")
                ))
        }
    }

    /// The embedded chat held open in the live scene while the device changes pose, for checking that the
    /// person's state survives: the draft, the focused composer (keyboard), the place in the thread and an open
    /// photo.
    ///
    /// The place in the thread comes from the rows' frames (the debug probe); the photo opens through the
    /// thread's own full-screen cover, once (`PhotoRequest`), so a photo whose view lost its state stays closed.
    @_spi(Snapshots)
    public final class ChatStateHarness {
        private let window: UIWindow
        private let pingFront: PingFront
        private let photoRequest = PhotoRequest()
        private let photoKey: String
        /// The latest frame of each thread row, in window coordinates.
        private var rows: [String: CGRect] = [:]

        /// Opens the conversation at its middle (the link card at the top of the screen).
        public init(scene: UIWindowScene) async throws {
            let app = Fixtures.app(forVariant: "default")
            photoKey = app.photoKey
            pingFront = PingFront.preview(.conversation, app: app)
            var preview = ChatPreviewState()
            preview.isOffline = true
            preview.now = SnapshotMatrix.fixedNow
            preview.scrollTarget = "msg_10"
            preview.openPhoto = photoRequest
            FixtureImages.install()
            window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = .light
            let probe = ComposerProbe(report: { [weak self] part, frame in
                if part.hasPrefix("row ") { self?.rows[String(part.dropFirst(4))] = frame }
            })
            window.rootViewController = UIHostingController(
                rootView: NavigationStack {
                    PingFrontChatView()
                        .environment(\.pingFrontInstance, pingFront)
                        .environment(\.chatPreview, preview)
                        .environment(\.composerProbe, probe)
                        .navigationTitle("Help")
                        .navigationBarTitleDisplayMode(.inline)
                })
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(800))
        }

        /// The composer's text.
        public var draft: String {
            get { pingFront.conversation.draft }
            set { pingFront.conversation.draft = newValue }
        }

        /// Puts the cursor in the composer (the keyboard comes up); false when the field was not found.
        public func focusComposer() -> Bool { composerField?.becomeFirstResponder() ?? false }

        /// Whether the composer has the cursor, so the keyboard stays up.
        public var composerIsFocused: Bool { composerField?.isFirstResponder ?? false }

        /// The thread rows on screen now, top to bottom.
        public var visibleRows: [String] {
            rows.filter { window.bounds.intersects($0.value) && $0.value.height > 0 }.sorted { $0.value.minY < $1.value.minY }.map(\.key)
        }

        /// The place in the thread: the positions (in the thread's order) of the rows on screen now.
        public var visibleRange: ClosedRange<Int>? {
            let order = pingFront.conversation.timeline.map(\.id)
            let indices = visibleRows.compactMap { order.firstIndex(of: $0) }
            guard let low = indices.min(), let high = indices.max() else { return nil }
            return low...high
        }

        /// Opens the thread's photo full screen, as a tap on it does.
        public func openPhoto() { photoRequest.attachmentId = photoKey }

        /// Whether a full-screen photo is showing over the chat.
        public var photoIsOpen: Bool { window.rootViewController?.presentedViewController != nil }

        /// Closes anything presented and the window.
        public func close() {
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
        }

        /// The composer's text view: the editable one holding the draft.
        private var composerField: UIView? {
            func search(_ view: UIView) -> UIView? {
                if let text = view as? UITextView, text.isEditable, text.text == draft { return text }
                if let text = view as? UITextField, text.isEnabled, text.text == draft { return text }
                return view.subviews.lazy.compactMap(search).first
            }
            return search(window)
        }
    }
#endif
