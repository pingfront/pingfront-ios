#if canImport(UIKit)
    import LinkPresentation
    import SwiftUI
    import UIKit
    import PingFrontCore

    /// Detected links, marked for SwiftUI so taps route through `openURL`.
    enum LinkText {
        static func attributed(_ text: String) -> AttributedString {
            var result = AttributedString(text)
            for link in LinkDetection.links(in: text) {
                guard let range = Range(link.range, in: result) else { continue }
                result[range].link = link.url
                result[range].underlineStyle = .single
            }
            return result
        }

        static func soleLink(in text: String) -> URL? { LinkDetection.soleLink(in: text) }
    }

    /// Link metadata fetched on this device with LinkPresentation.
    ///
    /// The URL is never sent to pingfront.
    @Observable
    final class LinkPreviews {
        static let shared = LinkPreviews()
        private var metadata: [URL: LPLinkMetadata] = [:]
        @ObservationIgnored private var loading: Set<URL> = []

        func metadata(for url: URL) -> LPLinkMetadata? { metadata[url] }

        func load(_ url: URL) async {
            guard metadata[url] == nil, !loading.contains(url) else { return }
            loading.insert(url)
            defer { loading.remove(url) }
            let provider = LPMetadataProvider()
            provider.shouldFetchSubresources = true
            provider.timeout = 10
            if let fetched = try? await provider.startFetchingMetadata(for: url) { metadata[url] = fetched }
        }

        func removeAll() { metadata = [:] }
    }

    /// A rich preview for a message that is only a link.
    ///
    /// Offline previews show the host name only.
    struct LinkPreviewCard: View {
        let url: URL
        @Environment(\.chatTheme) private var theme
        @Environment(\.chatPreview) private var preview
        @Environment(\.openURL) private var openURL

        var body: some View {
            Group {
                if let metadata = LinkPreviews.shared.metadata(for: url) {
                    LinkView(metadata: metadata)
                        .frame(width: 260)
                        .frame(minHeight: 72)
                } else {
                    Button {
                        openURL(url)
                    } label: {
                        Label(url.host() ?? url.absoluteString, systemImage: "link")
                            .font(.subheadline)
                            .foregroundStyle(theme.onTeamBubble)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(theme.teamBubble, in: RoundedRectangle(cornerRadius: theme.bubbleRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .task(id: url) { if !preview.isOffline { await LinkPreviews.shared.load(url) } }
        }
    }

    private struct LinkView: UIViewRepresentable {
        let metadata: LPLinkMetadata
        func makeUIView(context: Context) -> LPLinkView { LPLinkView(metadata: metadata) }
        func updateUIView(_ view: LPLinkView, context: Context) { view.metadata = metadata }
    }
#endif
