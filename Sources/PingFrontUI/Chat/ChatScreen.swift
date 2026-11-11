#if canImport(UIKit)
    import SwiftUI
    import PingFrontCore

    /// The chat: header, banners, the thread (or welcome), composer.
    ///
    /// Reads every token from `ChatTheme`.
    struct ChatScreen: View {
        let pingFront: PingFront
        var topic: ChatTopic?
        @Environment(\.colorScheme) private var systemScheme
        @Environment(\.chatClose) private var close
        /// Where the column sits when a fold divides the chat (see `FoldPlacement`).
        @State private var fold = FoldPlacement.none
        /// The bottom of the header and of the composer, in the window: the composer may grow up to the header
        /// (`composerRoom`).
        @State private var headerBottom: CGFloat = 0
        @State private var composerBottom: CGFloat = 0
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @Environment(\.verticalSizeClass) private var verticalSizeClass

        /// The person is typing (the composer's field has focus).
        @State private var composing = false

        /// Short on height, or at accessibility sizes, while the person types (see `ChatHeader.givesWay`).
        private var headerGivesWay: Bool { (verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize) && composing }

        /// At accessibility sizes or short on height, notices are content, not bar (`BannerStack.movesIntoThread`).
        private var bannersInThread: Bool { BannerStack.movesIntoThread(dynamicTypeSize, verticalSizeClass) }

        private var scheme: ColorScheme {
            switch pingFront.look.scheme {
            case .auto: systemScheme
            case .light: .light
            case .dark: .dark
            }
        }

        var body: some View {
            let theme = ChatTheme(look: pingFront.look, isDark: scheme == .dark)
            let conversation = pingFront.conversation
            // The thread scrolls under the header and composer, which sit on bar material.
            // One container, not a `Group`: a modifier on a group applies to each view the conditional produces, so the
            // bars (and the composer, with its focus and the keyboard) were made again when the welcome turned into the
            // thread. https://developer.apple.com/documentation/swiftui/group
            ZStack {
                if conversation.isEmpty, conversation.phase != .loading {
                    // Offline, the welcome stays usable under the offline banner (a message waits in the outbox and the
                    // chat reloads by itself); only a server that failed while online gets the failure state.
                    // Closed (the app paused, blocked, verification required), the notice in the composer's place says
                    // why; the welcome shows without its invitation, never a failure with a Try again that can't work.
                    if case .failed(let error) = conversation.phase, !error.isOffline, conversation.policy.canSend {
                        if bannersInThread {
                            ScrollView {
                                BannerStack(pingFront: pingFront)
                                LoadFailedView { conversation.reload() }
                            }
                        } else {
                            LoadFailedView { conversation.reload() }
                        }
                    } else {
                        WelcomeView(pingFront: pingFront)
                    }
                } else if conversation.isEmpty {
                    if bannersInThread {
                        ScrollView {
                            BannerStack(pingFront: pingFront)
                            ProgressView().padding(.top, 24)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    MessageList(pingFront: pingFront)
                }
            }
            // A readable column: on a wide display the thread keeps a phone-like measure instead of stretching.
            .frame(maxWidth: 640, maxHeight: .infinity)
            // Every link in the chat goes through the host's onLink, then an in-app Safari view. OpenURLAction is
            // synchronous, so the facade waits for an async onLink in a task it owns (logout and teardown cancel it).
            .environment(
                \.openURL,
                OpenURLAction { url in
                    pingFront.openLink(url)
                    return .handled
                }
            )
            .foldPlacement(fold)
            .frame(maxWidth: .infinity)
            .chatBars {
                VStack(spacing: 0) {
                    // Short on height, or at accessibility sizes, while the person types, the header gives way to the
                    // thread and the composer, as Messages hides its navigation content: only the close control stays,
                    // and the message being written and the one just sent keep the room above the keyboard.
                    ChatHeader(pingFront: pingFront, givesWay: headerGivesWay)
                    if !bannersInThread { BannerStack(pingFront: pingFront) }
                }
                .frame(maxWidth: 640)
                .foldPlacement(fold)
                // Containers with stable identifiers for UI tests, the host's included.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("PingFrontChatHeader")
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .global).maxY
                } action: {
                    headerBottom = $0
                }
            } bottom: {
                ComposerView(pingFront: pingFront) { composing = $0 }
                    .environment(\.composerRoom, composerBottom > headerBottom ? composerBottom - headerBottom : nil)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .global).maxY
                    } action: {
                        composerBottom = $0
                    }
                    .frame(maxWidth: 640)
                    .foldPlacement(fold)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("PingFrontComposer")
            }
            .background(theme.background.ignoresSafeArea())
            // Measured on the full-width chat and applied to the column inside it. Only padding changes, so the
            // thread, its scroll position, the draft, the keyboard and an open photo keep their identity.
            // Without an animation: the fold appears while the person is bending the device, and an animated
            // move would slide the header's name apart from its capsule on the way.
            .onFoldPlacementChange { fold = $0 }
            // With the header gone, the thread's top fade is as small as the close control's row needs.
            .environment(\.headerGaveWay, headerGivesWay)
            // The chat's text colour and accent belong to its content (links, chips, the send button), inside the sheet's
            // navigation stack: the toolbar keeps the system's default, so the close button is exactly the system's.
            .foregroundStyle(theme.text)
            .tint(theme.accent)
            .modifier(SheetBars(close: close))
            .fontDesign(theme.fontDesign)
            .environment(\.chatTheme, theme)
            .environment(\.colorScheme, scheme)
            .environment(\.pingFrontInstance, pingFront)
            .onAppear {
                #if DEBUG
                    FixtureImages.install()
                #endif
                if let topic {
                    pingFront.conversation.composerInsertion =
                        L10n.effective.text(topic.prefill) ?? pingFront.conversation.composerInsertion
                }
                // The sheet (or a custom presenter) or an embedded chat: counted apart, so closing one leaves the other.
                pingFront.chatVisibilityChanged(true, embedded: close == nil)
            }
            .onDisappear { pingFront.chatVisibilityChanged(false, embedded: close == nil) }
        }
    }

    /// In a sheet, the close control is an item in the system's navigation bar, so the system places it: at the
    /// top of the sheet, or in the vertical bar at the side where the display puts its controls there.
    ///
    /// The contact header stays the chat's own content and keeps its place at the top of the sheet: the chat
    /// lays out from the sheet's top edge, so the bar's row holds the close control beside the centered face,
    /// as in Messages, instead of adding a row above the header. Only the top is ignored; where the bar goes
    /// vertical it insets the side as usual. An embedded chat uses the host's bars.
    struct SheetBars: ViewModifier {
        let close: ChatCloseAction?
        @Environment(\.locale) private var locale

        func body(content: Content) -> some View {
            if let close {
                NavigationStack {
                    content
                        .ignoresSafeArea(.container, edges: .top)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { CloseButton(title: L10n(locale)("Close chat"), close: close) }
                        }
                        .navigationBarTitleDisplayMode(.inline)
                        // The header's surface runs up behind the bar, so the bar draws no background of its own.
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
            } else {
                content
            }
        }
    }

    /// The sheet's close control: the system's own.
    ///
    /// On iOS 26 `Button(role: .close)` in the sheet's toolbar draws Apple's
    /// glass close button (its glyph size, weight, colour and centring); before, UIKit's close button
    /// (`UIButton(type: .close)`), the system's equivalent. The chat's accent never reaches it (see `ChatScreen`), and its
    /// colour is never set by hand.
    ///
    /// - [Button(role:action:)](https://developer.apple.com/documentation/swiftui/button/init(role:action:))
    /// - [UIButton.ButtonType.close](https://developer.apple.com/documentation/uikit/uibutton/buttontype/close)
    struct CloseButton: View {
        let title: String
        let close: ChatCloseAction

        var body: some View {
            if #available(iOS 26, *) {
                Button(role: .close) { close() }
                    .accessibilityLabel(title)
            } else {
                SystemCloseButton(title: title, close: close)
                    .fixedSize()
            }
        }
    }

    /// UIKit's close button, for iOS before 26.
    struct SystemCloseButton: UIViewRepresentable {
        let title: String
        let close: ChatCloseAction

        func makeUIView(context: Context) -> UIButton {
            let button = UIButton(type: .close, primaryAction: UIAction { _ in close() })
            button.accessibilityLabel = title
            return button
        }

        func updateUIView(_ button: UIButton, context: Context) {
            button.accessibilityLabel = title
        }
    }

    extension View {
        /// Header and composer as bars the thread scrolls under: `safeAreaBar` with the soft scroll-edge
        /// effect on iOS 26+, `safeAreaInset` with bar material before.
        @ViewBuilder
        func chatBars(@ViewBuilder top: () -> some View, @ViewBuilder bottom: () -> some View) -> some View {
            if #available(iOS 26, *) {
                self
                    .safeAreaBar(edge: .top, spacing: 0, content: top)
                    .safeAreaBar(edge: .bottom, spacing: 0, content: bottom)
                    .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            } else {
                self
                    .safeAreaInset(edge: .top, spacing: 0, content: top)
                    .safeAreaInset(edge: .bottom, spacing: 0, content: bottom)
            }
        }
    }

    /// Shown when the first load failed while online and nothing is cached: one calm, centered line and Try again.
    ///
    /// Never offline: then the offline banner says it once, the welcome stays usable and the chat reloads by itself.
    struct LoadFailedView: View {
        let retry: () -> Void
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale

        var body: some View {
            let t = L10n(locale)
            VStack(spacing: 12) {
                Text(t("Couldn't load the conversation."))
                    .font(.body)
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(t("Try again"), action: retry)
                    .buttonStyle(OutlineButtonStyle())
            }
            .padding(theme.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
#endif
