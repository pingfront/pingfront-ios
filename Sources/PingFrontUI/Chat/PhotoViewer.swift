#if canImport(UIKit)
    import SwiftUI
    import UIKit
    import PingFrontCore

    /// A photo attachment full screen, built like Photos and Messages from system components only: a
    /// navigation bar with Done and the sender over the date, a bottom bar with Share, and a tap that hides
    /// or shows the bars (the background turns black, the status bar hides).
    ///
    /// Pinch or double-tap zooms.
    /// On iOS 18 and later it zooms out of the tapped thumbnail and swipes down to close interactively.
    struct PhotoViewer: View {
        let part: ImagePart
        let pingFront: PingFront
        /// The sender's display name ("You" for the person).
        let sender: String
        let date: Date
        /// The thumbnail's namespace, for the zoom transition (iOS 18+).
        var zoom: Namespace.ID?
        @State var chromeHidden = false
        @Environment(\.dismiss) private var dismiss
        @Environment(\.locale) private var locale
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var scale: CGFloat = 1
        @State private var committedScale: CGFloat = 1
        @State private var offset: CGSize = .zero
        @State private var committedOffset: CGSize = .zero
        @State private var legacyDismissDrag: CGFloat = 0

        static func fullKey(_ part: ImagePart) -> String { "full:\(part.attachmentId)" }

        var body: some View {
            let t = L10n(locale)
            NavigationStack {
                photo(t)
                    .navigationTitle(sender)
                    .navigationBarTitleDisplayMode(.inline)
                    .modifier(TitleWithDate(title: sender, date: dateText))
                    .toolbar { toolbar(t) }
                    .modifier(BarsVisibility(hidden: chromeHidden))
                    .statusBarHidden(chromeHidden)
            }
            .modifier(ZoomTransition(sourceID: part.attachmentId, namespace: zoom))
            .task(id: part.attachmentId) {
                guard let url = part.url else { return }
                await ImageStore.shared.load(url, key: Self.fullKey(part), maxPixelSize: 4096) {
                    await pingFront.conversation.refreshedURL(for: part)
                }
            }
        }

        private var dateText: String {
            date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        }

        @ViewBuilder
        private func photo(_ t: L10n) -> some View {
            let image = ImageStore.shared.image(for: Self.fullKey(part)) ?? ImageStore.shared.image(for: part.attachmentId)
            ZStack {
                // Photos: the system background with the bars, black without them.
                (chromeHidden ? Color.black : Color(uiColor: .systemBackground)).ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(x: offset.width, y: offset.height + legacyDismissDrag)
                        .gesture(magnify)
                        .simultaneousGesture(drag, including: scale > 1 || Self.needsLegacyDismiss ? .all : .subviews)
                        .onTapGesture(count: 2) { toggleZoom() }
                        .onTapGesture { toggleChrome() }
                        .accessibilityLabel(t("Photo"))
                        .accessibilityAddTraits(.isImage)
                        .accessibilityHint(t("Pinch to zoom. Swipe down to close."))
                        .accessibilityAction(named: chromeHidden ? t("Show controls") : t("Hide controls")) { toggleChrome() }
                } else {
                    ProgressView()
                }
            }
            .ignoresSafeArea()
            .accessibilityAction(.escape) { dismiss() }
        }

        @ToolbarContentBuilder
        private func toolbar(_ t: L10n) -> some ToolbarContent {
            ToolbarItem(placement: .cancellationAction) {
                if #available(iOS 26, *) {
                    Button(role: .close) { dismiss() }
                } else {
                    Button(t("Done")) { dismiss() }
                }
            }
            if let image = ImageStore.shared.image(for: Self.fullKey(part)) ?? ImageStore.shared.image(for: part.attachmentId) {
                ToolbarItem(placement: .bottomBar) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(t("Photo"), image: Image(uiImage: image)))
                }
            }
        }

        // MARK: Gestures

        /// iOS 18+ closes with the zoom transition's own swipe; iOS 17 gets a plain swipe down.
        private static var needsLegacyDismiss: Bool {
            if #available(iOS 18, *) { return false }
            return true
        }

        private var magnify: some Gesture {
            MagnifyGesture()
                .onChanged { value in scale = PhotoZoom.clamped(committedScale * value.magnification) }
                .onEnded { _ in
                    committedScale = scale
                    if scale == 1 { resetPan() }
                }
        }

        private var drag: some Gesture {
            DragGesture()
                .onChanged { value in
                    if scale > 1 {
                        offset = CGSize(
                            width: committedOffset.width + value.translation.width,
                            height: committedOffset.height + value.translation.height)
                    } else {
                        legacyDismissDrag = max(value.translation.height, 0)
                    }
                }
                .onEnded { value in
                    if scale > 1 {
                        committedOffset = offset
                    } else if PhotoZoom.dismisses(
                        scale: scale, translation: value.translation.height, predicted: value.predictedEndTranslation.height)
                    {
                        dismiss()
                    } else {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3)) { legacyDismissDrag = 0 }
                    }
                }
        }

        private func toggleChrome() {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { chromeHidden.toggle() }
        }

        private func toggleZoom() {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3)) {
                if scale > 1 {
                    scale = 1
                    committedScale = 1
                    resetPan()
                } else {
                    scale = 2.5
                    committedScale = 2.5
                }
            }
        }

        private func resetPan() {
            offset = .zero
            committedOffset = .zero
        }
    }

    /// The sender over the date: a navigation subtitle on iOS 26, a principal title stack before.
    private struct TitleWithDate: ViewModifier {
        let title: String
        let date: String

        func body(content: Content) -> some View {
            if #available(iOS 26, *) {
                content.navigationSubtitle(date)
            } else {
                content.toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(title).font(.headline)
                            Text(date).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    /// Hides or shows the navigation and bottom bars together (`toolbarVisibility` on iOS 18+).
    private struct BarsVisibility: ViewModifier {
        let hidden: Bool

        func body(content: Content) -> some View {
            if #available(iOS 18, *) {
                content.toolbarVisibility(hidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
            } else {
                content.toolbar(hidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
            }
        }
    }

    /// Zooms the viewer out of the tapped thumbnail (iOS 18+).
    private struct ZoomTransition: ViewModifier {
        let sourceID: String
        let namespace: Namespace.ID?

        func body(content: Content) -> some View {
            if #available(iOS 18, *), let namespace {
                content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
            } else {
                content
            }
        }
    }

    /// Marks the thumbnail the viewer zooms from (iOS 18+).
    struct ZoomSource: ViewModifier {
        let id: String
        let namespace: Namespace.ID

        func body(content: Content) -> some View {
            if #available(iOS 18, *) {
                content.matchedTransitionSource(id: id, in: namespace)
            } else {
                content
            }
        }
    }
#endif
