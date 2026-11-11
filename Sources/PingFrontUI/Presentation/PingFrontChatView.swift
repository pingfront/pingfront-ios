#if canImport(UIKit)
    public import SwiftUI
    public import PingFrontCore

    /// The chat as a SwiftUI view, for a tab or a navigation destination.
    ///
    /// ```swift
    /// TabView {
    ///     PingFrontChatView().tabItem { Label("Help", systemImage: "bubble.left") }
    /// }
    /// ```
    /// Marks the chat visible while on screen (live updates, read receipts, no unread polling).
    public struct PingFrontChatView: View {
        private let topic: ChatTopic?
        private let showsClose: Bool
        @Environment(\.pingFrontInstance) private var instance
        @Environment(\.dismiss) private var dismiss

        /// Creates the embedded chat.
        ///
        /// With a topic, its prefill goes into the composer.
        public init(topic: ChatTopic? = nil) {
            self.topic = topic
            self.showsClose = false
        }

        init(topic: ChatTopic?, showsClose: Bool) {
            self.topic = topic
            self.showsClose = showsClose
        }

        /// The chat screen.
        public var body: some View {
            let pingFront = instance ?? PingFront.shared
            ChatScreen(pingFront: pingFront, topic: topic)
                .transformEnvironment(\.chatPreview) { preview in
                    if preview.now == nil, let now = pingFront.demoNow { preview.now = now }
                    if pingFront.demoScrolledToTop { preview.scrolledToTop = true }
                }
                .transformEnvironment(\.chatClose) { close in
                    if showsClose, close == nil { close = ChatCloseAction { dismiss() } }
                }
                .pingFrontLanguage(pingFront)
        }
    }

    extension View {
        /// Presents the chat as a sheet (form sheet on iPad, reading width capped at 640 pt).
        ///
        /// Opens at the large detent by default; pass `[.medium, .large]` to open half height first.
        ///
        /// ```swift
        /// Button("Help") { showChat = true }
        ///     .pingFrontChat(isPresented: $showChat, topic: .billing)
        /// ```
        public func pingFrontChat(isPresented: Binding<Bool>, topic: ChatTopic? = nil, detents: Set<PresentationDetent> = [.large])
            -> some View
        {
            sheet(isPresented: isPresented) {
                PingFrontChatView(topic: topic, showsClose: true)
                    .presentationDetents(detents)
                    .presentationDragIndicator(.visible)
            }
        }
    }

    extension PingFrontModule {
        /// The SwiftUI chat UI: SDK-presented sheet, `openChat()`, host app inference (AccentColor, name, icon).
        ///
        /// Installed automatically by the `PingFront` product's `configure`.
        public static var chatUI: PingFrontModule {
            PingFrontModule(id: ModuleID.chatUI) { context in
                context.setChatPresenter(SheetPresenter(pingFront: context.pingFront))
                // Review cards ask Apple's native prompt even without the StoreKit module.
                context.setReviewRequester(NativeReviewRequester())
                // Store action receipts ("Payment method updated") in the person's language.
                context.pingFront.storeChangeText = { L10n.effective.storeChange($0) }
                context.pingFront.onLocalDataWipe {
                    ImageStore.shared.removeAll()
                    LinkPreviews.shared.removeAll()
                }
                context.setHostApp(name: HostApp.displayName, accent: HostApp.accent, iconPNG: nil)
                // Rendered off the main thread, once per app version (cached on disk).
                context.run {
                    guard let png = await HostApp.iconPNG(edge: 128) else { return }
                    if let image = UIImage(data: png) { ImageStore.shared.set(image, for: HostApp.iconKey(png)) }
                    context.setHostIcon(png)
                }
            }
        }
    }
#endif
