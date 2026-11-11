#if canImport(UIKit)
    package import SwiftUI
    package import UIKit
    import CryptoKit
    import ImageIO
    package import PingFrontCore

    /// Decoded images for the chat, observable per key: an arriving image re-renders only the views that
    /// show it.
    ///
    /// Memory, with a cost limit. Only teammates' avatars are also kept on disk (Caches), so a chat opened after
    /// a relaunch shows their faces in the first frame instead of a monogram; photos in the thread stay in
    /// memory. Cleared, avatars included, on logout, erase and revoked sessions.
    package final class ImageStore {
        package static let shared = ImageStore()

        /// One key's image.
        ///
        /// Views read `image`, so only they update when it arrives.
        @Observable
        package final class Slot {
            package fileprivate(set) var image: UIImage?
        }

        private let cache: NSCache<NSString, UIImage> = {
            let cache = NSCache<NSString, UIImage>()
            cache.totalCostLimit = 48 * 1024 * 1024
            return cache
        }()
        private var slots: [String: Slot] = [:]
        private var loading: Set<String> = []

        /// Ephemeral and uncached: no image bytes land in the shared URL cache on disk.
        private static let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: configuration)
        }()

        /// The observable slot for `key`.
        package func slot(for key: String) -> Slot {
            if let slot = slots[key] {
                if slot.image == nil, let cached = cache.object(forKey: key as NSString) { slot.image = cached }
                return slot
            }
            let slot = Slot()
            slot.image = cache.object(forKey: key as NSString)
            slots[key] = slot
            return slot
        }

        /// The image for `key`, when loaded (observes only that key).
        package func image(for key: String) -> UIImage? { slot(for: key).image }

        package func set(_ image: UIImage, for key: String) {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key as NSString, cost: cost)
            slot(for: key).image = image
        }

        package func removeAll() {
            cache.removeAllObjects()
            for slot in slots.values { slot.image = nil }
            slots = [:]
            try? FileManager.default.removeItem(at: Self.avatarDirectory)
        }

        // MARK: Teammate avatars

        /// Avatars are decoded at this size: the largest face (96 pt) at 3x.
        static let avatarPixels = 288

        /// Where teammates' avatars persist across launches (Caches: never backed up, purgeable).
        static let avatarDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "PingFront/avatars", directoryHint: .isDirectory)

        static func avatarFile(for url: URL) -> URL {
            let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            return avatarDirectory.appending(path: "\(name).png")
        }

        /// A teammate's avatar for the first render: memory, else the copy on disk from an earlier launch (or the
        /// local file itself), decoded once when the slot is created so the face is there in the first frame.
        package func avatar(for url: URL) -> UIImage? {
            let key = url.absoluteString
            if slots[key] == nil, cache.object(forKey: key as NSString) == nil {
                let source = url.isFileURL ? url : Self.avatarFile(for: url)
                if let data = try? Data(contentsOf: source), let image = Self.downsample(data, maxPixelSize: Self.avatarPixels) {
                    let slot = Slot()
                    slot.image = image
                    slots[key] = slot
                    cache.setObject(image, forKey: key as NSString, cost: Self.avatarPixels * Self.avatarPixels * 4)
                }
            }
            return image(for: key)
        }

        /// Loads a teammate's avatar and keeps a copy on disk for the next launch.
        package func loadAvatar(_ url: URL) async {
            let key = url.absoluteString
            await load(url, key: key, maxPixelSize: Self.avatarPixels)
            guard !url.isFileURL, let image = image(for: key), let png = image.pngData() else { return }
            await Self.store(png, at: Self.avatarFile(for: url))
        }

        @concurrent private static func store(_ png: Data, at file: URL) async {
            guard !FileManager.default.fileExists(atPath: file.path) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }

        /// Loads a remote image once, decoded at most `maxPixelSize` on its long edge.
        ///
        /// On failure it asks
        /// the conversation for a fresh URL (short-lived links).
        package func load(_ url: URL, key: String, maxPixelSize: Int = 1024, refresh: (@MainActor () async -> URL?)? = nil) async {
            guard image(for: key) == nil, !loading.contains(key), url.scheme != "fixture" else { return }
            loading.insert(key)
            defer { loading.remove(key) }
            if let image = await Self.fetch(url, maxPixelSize: maxPixelSize) {
                set(image, for: key)
                return
            }
            if let refresh, let fresh = await refresh(), let image = await Self.fetch(fresh, maxPixelSize: maxPixelSize) {
                set(image, for: key)
            }
        }

        @concurrent private static func fetch(_ url: URL, maxPixelSize: Int) async -> UIImage? {
            guard let (data, response) = try? await session.data(from: url),
                (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return downsample(data, maxPixelSize: maxPixelSize)
        }

        /// Decodes at display size with ImageIO thumbnailing, never the full bitmap.
        package nonisolated static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
            let thumbnail =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail) else { return nil }
            return UIImage(cgImage: image)
        }
    }

    /// A round face: the photo when there is one, else a two-tone accent monogram.
    ///
    /// The assistant gets its own mark.
    struct AvatarView: View {
        let name: String?
        let url: URL?
        let size: CGFloat
        var isAI = false
        var ring = true
        @Environment(\.chatTheme) private var theme

        var body: some View {
            let key = url?.absoluteString ?? ""
            ZStack {
                if isAI {
                    Circle().fill(LinearGradient(colors: [theme.accent.opacity(0.75), theme.accent], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "sparkle")
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(theme.onAccent)
                } else if let image = url.flatMap(ImageStore.shared.avatar(for:)) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    // The Contacts monogram: a soft gray gradient with white initials.
                    Circle().fill(
                        LinearGradient(
                            colors: [Color(white: theme.isDark ? 0.52 : 0.66), Color(white: theme.isDark ? 0.38 : 0.53)], startPoint: .top,
                            endPoint: .bottom))
                    Text(initials)
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.onStrong)
                        .minimumScaleFactor(0.5)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay { if ring { Circle().strokeBorder(theme.background, lineWidth: max(1.5, size * 0.05)) } }
            .task(id: key) { if let url, !isAI { await ImageStore.shared.loadAvatar(url) } }
            .accessibilityHidden(true)
        }

        private var initials: String {
            let words = (name ?? "").split(separator: " ")
            let letters = words.prefix(2).compactMap(\.first).map(String.init).joined()
            return letters.isEmpty ? "?" : letters.uppercased()
        }
    }

    /// Up to three overlapping faces.
    struct FacesStack: View {
        let members: [TeamMember]
        let size: CGFloat

        var body: some View {
            HStack(spacing: -size * 0.28) {
                ForEach(Array(members.prefix(3).enumerated()), id: \.element.id) { index, member in
                    AvatarView(name: member.name, url: member.avatarURL, size: size)
                        .zIndex(Double(3 - index))
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// The app icon in a rounded square.
    ///
    /// The host bundle's icon (`CFBundleIcons`) or the one set in the dashboard. Only an app with neither (a test target,
    /// a bare project) shows the first letter of its name on the same square.
    package struct AppIconView: View {
        let look: ResolvedLook
        let size: CGFloat
        @Environment(\.chatTheme) private var theme

        package init(look: ResolvedLook, size: CGFloat) {
            self.look = look
            self.size = size
        }

        package var body: some View {
            Group {
                if let png = look.appIconPNG, let image = ImageStore.shared.image(for: HostApp.iconKey(png)) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let url = look.appIconURL, let image = ImageStore.shared.image(for: url.absoluteString) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        theme.teamBubble
                        Text(String(look.appName.prefix(1))).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(
                            theme.authorName)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(theme.rule, lineWidth: 0.5))
            .task(id: look.appIconURL) { if let url = look.appIconURL { await ImageStore.shared.load(url, key: url.absoluteString) } }
            .task(id: look.appIconPNG) {
                // Decoded once into the store, never per render.
                guard let data = look.appIconPNG, ImageStore.shared.image(for: HostApp.iconKey(data)) == nil,
                    let image = ImageStore.downsample(data, maxPixelSize: 256)
                else { return }
                ImageStore.shared.set(image, for: HostApp.iconKey(data))
            }
            .accessibilityHidden(true)
        }
    }

    /// The small "AI" capsule next to the assistant's name.
    ///
    /// Not configurable.
    struct AITag: View {
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale

        var body: some View {
            // A small capsule tinted with the accent (not solid), the same shape as on Android.
            Text(L10n(locale)("AI"))
                // Caption, not caption2: caption2 stops shrinking below the default size, which Apple's audit
                // reports as Dynamic Type only partly supported.
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.onAccentTint)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(theme.accentTint, in: Capsule())
        }
    }

    /// The pingfront ping: a static pink dot (status dots never animate, per pingfront's design tokens).
    struct PingDot: View {
        @Environment(\.chatTheme) private var theme
        @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 8

        var body: some View {
            Circle().fill(theme.ping)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    /// Pressed state for tiles and rows: a subtle scale.
    struct PressableStyle: ButtonStyle {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: ButtonStyleConfiguration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
                .contentShape(Rectangle())
        }
    }

    /// A quick-reply capsule: accent outline, filled with a check when chosen.
    struct PillButtonStyle: ButtonStyle {
        var selected = false
        @Environment(\.chatTheme) private var theme

        func makeBody(configuration: ButtonStyleConfiguration) -> some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? theme.onAccent : theme.accentText)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(Capsule().fill(selected ? theme.accent : (configuration.isPressed ? theme.accentTint : theme.background)))
                .overlay(Capsule().strokeBorder(selected ? Color.clear : theme.accentText.opacity(0.6), lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        }
    }

    /// Wraps children into rows, leading-aligned (topic chips).
    struct FlowLayout: Layout {
        var spacing: CGFloat = 8
        /// Center each row (topic capsules in the empty state).
        var centered = false
        /// When wrapping is needed, split into the same number of rows with the most even widths
        /// (no lone item on a line when a better split exists).
        var balanced = false

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? .infinity
            let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            let rows = rowRanges(widths: sizes.map(\.width), limit: width)
            var height: CGFloat = 0
            var maxWidth: CGFloat = 0
            for (index, row) in rows.enumerated() {
                let rowWidth = row.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0))
                maxWidth = max(maxWidth, rowWidth)
                height += (row.map { sizes[$0].height }.max() ?? 0) + (index > 0 ? spacing : 0)
            }
            return CGSize(width: min(maxWidth, width), height: height)
        }

        /// Greedy rows; with `balanced`, the same row count split as evenly as possible.
        private func rowRanges(widths: [CGFloat], limit: CGFloat) -> [[Int]] {
            var greedy: [[Int]] = []
            var x: CGFloat = 0
            for (index, width) in widths.enumerated() {
                if greedy.isEmpty || (x > 0 && x + width > limit) {
                    greedy.append([])
                    x = 0
                }
                greedy[greedy.count - 1].append(index)
                x += width + spacing
            }
            guard balanced, greedy.count > 1, widths.count <= 8 else { return greedy }
            func rowWidth(_ range: Range<Int>) -> CGFloat {
                widths[range].reduce(0, +) + spacing * CGFloat(max(range.count - 1, 0))
            }
            // Contiguous splits into `greedy.count` rows; keep the one with the narrowest widest row.
            var best: (rows: [[Int]], widest: CGFloat)?
            func search(start: Int, rowsLeft: Int, acc: [[Int]], widest: CGFloat) {
                if rowsLeft == 1 {
                    let last = start..<widths.count
                    guard !last.isEmpty, rowWidth(last) <= limit else { return }
                    let candidate = max(widest, rowWidth(last))
                    if candidate < (best?.widest ?? .infinity) { best = (acc + [Array(last)], candidate) }
                    return
                }
                for end in (start + 1)..<widths.count where widths.count - end >= rowsLeft - 1 {
                    let range = start..<end
                    guard rowWidth(range) <= limit else { break }
                    search(start: end, rowsLeft: rowsLeft - 1, acc: acc + [Array(range)], widest: max(widest, rowWidth(range)))
                }
            }
            search(start: 0, rowsLeft: greedy.count, acc: [], widest: 0)
            return best?.rows ?? greedy
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            // Break into rows first so centered rows know their width.
            let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
            var rows: [[(Subviews.Element, CGSize)]] = rowRanges(widths: sizes.map(\.width), limit: bounds.width).map { range in
                range.map { (subviews[$0], sizes[$0]) }
            }
            if rows.isEmpty { rows = [[]] }
            var y = bounds.minY
            for row in rows where !row.isEmpty {
                let rowWidth = row.map(\.1.width).reduce(0, +) + spacing * CGFloat(row.count - 1)
                var x = centered ? bounds.minX + max(0, (bounds.width - rowWidth) / 2) : bounds.minX
                let rowHeight = row.map(\.1.height).max() ?? 0
                for (subview, size) in row {
                    subview.place(
                        at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                    x += size.width + spacing
                }
                y += rowHeight + spacing
            }
        }
    }

    /// A full-width primary action in the accent color with contrast-picked text. 44 pt minimum.
    struct PrimaryButtonStyle: ButtonStyle {
        @Environment(\.chatTheme) private var theme
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: ButtonStyleConfiguration) -> some View {
            configuration.label
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    theme.accent.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
    }

    /// A bordered secondary control (choices, chips).
    struct OutlineButtonStyle: ButtonStyle {
        var selected = false
        @Environment(\.chatTheme) private var theme

        func makeBody(configuration: ButtonStyleConfiguration) -> some View {
            configuration.label
                .foregroundStyle(selected ? theme.onAccent : theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                        .fill(selected ? theme.accent : (configuration.isPressed ? theme.teamBubble : theme.background))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                        .strokeBorder(selected ? theme.accent : theme.rule, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
    }

    extension View {
        /// Bars: transparent over the soft scroll-edge effect on iOS 26+, bar material before.
        @ViewBuilder
        func barBackground() -> some View {
            if #available(iOS 26, *) {
                self
            } else {
                self.background(.bar)
            }
        }

        /// Liquid Glass on iOS 26+, a plain fill before and with Reduce Transparency; an edge with Increase Contrast.
        func glassCircle(fallback: Color) -> some View { modifier(GlassCircle(fallback: fallback)) }
    }

    /// See `glassCircle(fallback:)`.
    struct GlassCircle: ViewModifier {
        let fallback: Color
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.chatTheme) private var theme

        func body(content: Content) -> some View {
            let edge = contrast == .increased ? theme.muted : .clear
            if #available(iOS 26, *), !reduceTransparency {
                content.glassEffect(.regular.interactive(), in: .circle).overlay(Circle().strokeBorder(edge, lineWidth: 1))
            } else {
                content.background(fallback, in: Circle()).overlay(Circle().strokeBorder(edge, lineWidth: 1))
            }
        }
    }
#endif
