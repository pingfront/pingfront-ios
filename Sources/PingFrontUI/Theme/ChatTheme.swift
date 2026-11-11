#if canImport(UIKit)
    public import SwiftUI
    public import PingFrontCore
    import UIKit

    /// The design tokens every chat view reads, resolved from `ResolvedLook` for one color scheme.
    ///
    /// Views never hard-code colors, radii or spacing; they read `@Environment(\.chatTheme)`.
    package struct ChatTheme: Sendable {
        package var look: ResolvedLook
        package var isDark: Bool

        package init(look: ResolvedLook, isDark: Bool) {
            self.look = look
            self.isDark = isDark
        }

        /// The color mode these tokens resolve for.
        package var mode: ColorMode { isDark ? .dark : .light }

        private func color(_ pair: PingFrontColor) -> Color { Color(rgb: pair.value(in: mode)) }

        package var accent: Color { color(look.accent) }
        package var onAccent: Color { color(look.onAccent) }
        package var background: Color { color(look.background) }
        package var teamBubble: Color { color(look.teamBubble) }
        package var text: Color { color(look.text) }
        /// Text on the team bubble (chosen for contrast with the bubble).
        package var onTeamBubble: Color {
            Color(
                rgb: Contrast.bestText(on: look.teamBubble.value(in: mode)) == Contrast.lightText
                    ? .white : look.text.value(in: .light))
        }
        /// Secondary text.
        ///
        /// It sits on the background and inside team bubbles (the composer's placeholder, card
        /// details), so it is nudged until it reads 4.5:1 on both, as on Android (the default light muted is
        /// 4.46:1 on the default bubble).
        package var muted: Color {
            Color(
                rgb: Contrast.adjustText(
                    Contrast.adjustText(look.muted.value(in: mode), on: look.teamBubble.value(in: mode), minimum: textContrast),
                    on: look.background.value(in: mode), minimum: textContrast))
        }
        /// The contrast secondary and accent text must reach: 4.5:1, or 5.5:1 in the serif face, whose thin
        /// strokes antialias lighter at small sizes (Apple's audit measures them below 4.5:1 at the minimum).
        private var textContrast: Double { look.font == .serif ? 5.5 : 4.5 }
        /// Secondary text on the team bubble and on cards, deepened until it reads 4.5:1 there.
        package var mutedOnTeamBubble: Color {
            Color(rgb: Contrast.adjustText(look.muted.value(in: mode), on: look.teamBubble.value(in: mode), minimum: textContrast))
        }
        /// Hairlines: iOS separator.
        package var rule: Color { isDark ? Color(rgb: RGBColor(rgb: 0x38383A)) : Color(rgb: RGBColor(rgb: 0xD1D1D6)) }
        /// The pingfront ping: the pink dot on a message the team sent first.
        ///
        /// Never text.
        package var ping: Color { isDark ? Color(rgb: RGBColor(rgb: 0xFF4F8F)) : Color(rgb: RGBColor(rgb: 0xFF2D78)) }
        /// The receipt check: pingfront's `leaf` design token in both schemes.
        package var lift: Color { Color(rgb: RGBColor(rgb: 0x30D158)) }
        /// iOS red for failures.
        package var stop: Color { isDark ? Color(rgb: RGBColor(rgb: 0xFF453A)) : Color(rgb: RGBColor(rgb: 0xD70015)) }
        /// iOS orange for filled rating stars.
        package var rating: Color { Color(uiColor: .systemOrange) }
        /// Text and glyphs on `stop` and on `scrim` (always white).
        package var onStrong: Color { .white }
        /// A dark wash behind small controls on photos.
        package var scrim: Color { Color.black.opacity(0.65) }
        /// Sender names above group bubbles (secondary label, like Messages).
        package var authorName: Color { muted }

        package var fontDesign: Font.Design {
            switch look.font {
            case .system: .default
            case .rounded: .rounded
            case .serif: .serif
            }
        }

        /// Titles and names follow the font token (SF by default, like Messages).
        package var displayDesign: Font.Design { fontDesign }

        /// The accent as readable text or icon color on the background (4.5:1).
        package var accentText: Color {
            Color(rgb: Contrast.adjustText(look.accent.value(in: mode), on: look.background.value(in: mode), minimum: textContrast))
        }

        /// A soft accent wash for icon tiles, monograms and offer bands.
        package var accentTint: Color {
            Color(rgb: look.background.value(in: mode).mixed(with: look.accent.value(in: mode), amount: isDark ? 0.26 : 0.14))
        }

        /// Accent-colored text on `accentTint` (4.5:1).
        package var onAccentTint: Color {
            let tint = look.background.value(in: mode).mixed(with: look.accent.value(in: mode), amount: isDark ? 0.26 : 0.14)
            return Color(rgb: Contrast.adjustText(look.accent.value(in: mode), on: tint, minimum: 4.5))
        }

        /// Width reserved on the tail side of every bubble, so tailed and untailed bubbles align.
        package var tailSpace: CGFloat { 6 }

        package var bubbleRadius: CGFloat { look.bubbleRadius }
        package var controlRadius: CGFloat { look.corners == .square ? 4 : 8 }
        package var isCompact: Bool { look.density == .compact }
        /// Space between groups.
        package var groupSpacing: CGFloat { isCompact ? BubbleMetrics.compactGroupSpacing : BubbleMetrics.groupSpacing }
        /// Space between bubbles in a group (Messages stacks them tightly).
        package var rowSpacing: CGFloat { BubbleMetrics.rowSpacing }
        /// Bubble insets at the default text size; `TextBubble` scales them with Dynamic Type.
        package var bubblePadding: EdgeInsets { isCompact ? BubbleMetrics.compactPadding : BubbleMetrics.padding }
        package var gutter: CGFloat { 12 }
        package var avatarSize: CGFloat { BubbleMetrics.avatarSize }

        package static let standard = ChatTheme(
            look: .resolve(remote: nil, code: ChatAppearance(), codeTopics: nil, host: nil), isDark: false)
    }

    extension Color {
        package init(rgb: RGBColor) {
            self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
        }
    }

    extension PingFrontColor {
        /// Resolves a SwiftUI color for light and dark mode, for `config.appearance.accent = PingFrontColor(myColor)`.
        public init(_ color: Color) {
            var light = EnvironmentValues()
            light.colorScheme = .light
            var dark = EnvironmentValues()
            dark.colorScheme = .dark
            self.init(light: RGBColor(resolved: color.resolve(in: light)), dark: RGBColor(resolved: color.resolve(in: dark)))
        }
    }

    extension PingFrontColor {
        /// A SwiftUI color that follows the system light or dark appearance.
        package var dynamicColor: Color {
            let light = self.light
            let dark = self.dark
            return Color(
                uiColor: UIColor { traits in
                    let c = traits.userInterfaceStyle == .dark ? dark : light
                    return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
                })
        }
    }

    extension RGBColor {
        package init(resolved: Color.Resolved) {
            self.init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
        }
    }

    /// Snapshot and preview overrides.
    ///
    /// Production leaves everything at its default.
    package struct ChatPreviewState: Sendable {
        /// Fixed "now" for timestamps and the teammate's local time.
        package var now: Date?
        /// Photos already staged in the composer.
        package var stagedPhotos: [Data] = []
        /// Start scrolled to the top (load-older and jump-to-latest states).
        package var scrolledToTop = false
        /// Show the jump-to-latest button with this many new messages.
        package var newMessageCount: Int?
        /// Draft text in the composer.
        package var draft: String?
        /// Scroll so this row is at the top (snapshots of the middle of a thread).
        package var scrollTarget: String?
        /// Offline renders (snapshots): nothing is fetched, link previews show the host only.
        package var isOffline = false
        /// Opens one photo full screen, once (state tests): a view that lost its state can't quietly reopen it.
        package var openPhoto: PhotoRequest?

        package init() {}
    }

    /// A request to open the photo with this attachment id; the photo clears it when it opens.
    @MainActor @Observable
    package final class PhotoRequest {
        package var attachmentId: String?
        package init() {}
    }

    /// Bubble metrics matched to Messages on iPhone 17 (iOS 27, measured from the simulator on 31 Oct 2026): at the
    /// default text size a one-line bubble is 40 pt tall and a long one wraps at about 70% of the screen.
    /// `BubbleMetricsTests` pins these values.
    package enum BubbleMetrics {
        /// Text inside a bubble at the default size (scaled with Dynamic Type).
        ///
        /// Measured in Messages: the glyphs
        /// start 15 pt from the bubble's edge and a one-line bubble is 40 pt tall (17 pt text on a 20.3 pt line).
        package static let padding = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        package static let compactPadding = EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        /// Widest bubble, as a share of the message column: Messages wraps at 281 pt on a 402 pt screen (74% of
        /// the 378 pt column, 70% of the screen); 75% gives the same line breaks.
        package static let maxWidthFraction: CGFloat = 0.75
        /// At accessibility text sizes bubbles use more of the row: Messages wraps at 341 pt at AX3 (90%).
        package static let accessibilityMaxWidthFraction: CGFloat = 0.9
        /// Space between bubbles of a group at the default size; `MessageList` scales spacing with Dynamic Type
        /// (Messages: 4 pt between bubble edges at the default size, 11 pt at AX3).
        package static let rowSpacing: CGFloat = 2
        package static let groupSpacing: CGFloat = 10
        package static let compactGroupSpacing: CGFloat = 8
        package static let avatarSize: CGFloat = 28
        /// Cards: the width of a Messages rich link.
        package static let cardWidth: CGFloat = 300
        /// The least room left on the far side of a bubble, and of the line under it: nothing in a row reaches past
        /// where the other side's bubbles start.
        package static let farSide: CGFloat = 56

        /// Bubble insets grow at a quarter of the text's rate (Messages at AX3: 2.35× text, about 1.3× insets).
        package static func insetScale(textScale: CGFloat) -> CGFloat { 1 + (textScale - 1) * 0.25 }

        /// The widest a bubble may be in a thread of `threadWidth` points.
        package static func maxWidth(threadWidth: CGFloat, accessibility: Bool) -> CGFloat {
            (threadWidth * (accessibility ? accessibilityMaxWidthFraction : maxWidthFraction)).rounded()
        }
    }

    /// Composer metrics matched to Messages on iOS 26.
    ///
    /// Measured on the iPhone 17 simulator at 3x: the + circle and the one-line field are both 122 px tall with
    /// one vertical center, and the gap between them is about 12 pt. The + keeps its size at every text size, as
    /// in Messages, and stays centered on the field's last line.
    /// `ComposerMetricsTests` measures the laid-out composer against these values.
    package enum ComposerMetrics {
        /// The + circle's diameter, and the field's one-line height at the default text size.
        package static let plusDiameter: CGFloat = 122.0 / 3
        /// The + button's tap target; the circle is centered in it.
        package static let plusTarget: CGFloat = 44
        /// Text inset inside the field, above and below the line.
        package static let fieldVerticalInset: CGFloat = 8
        /// The visible gap between the + circle and the field.
        package static func gap(_ theme: ChatTheme) -> CGFloat { theme.gutter }
        /// The composer's leading padding, so the visible circle starts at the thread's edge (the gutter, where
        /// avatars and bubbles start) although its tap target is wider.
        package static func leadingPadding(_ theme: ChatTheme) -> CGFloat { theme.gutter - (plusTarget - plusDiameter) / 2 }
        /// The spacing between the + target and the field that leaves `gap` between what you see.
        package static func spacing(_ theme: ChatTheme) -> CGFloat { gap(theme) - (plusTarget - plusDiameter) / 2 }
        /// Where the field starts, from the composer's leading padding (staged photos line up with it).
        package static func fieldLeading(_ theme: ChatTheme) -> CGFloat { plusTarget + spacing(theme) }
    }

    extension VerticalAlignment {
        private enum ComposerLine: AlignmentID {
            static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
        }
        /// The center of the composer field's last line: the + sits on it.
        package static let composerLine = VerticalAlignment(ComposerLine.self)
    }

    #if DEBUG
        /// Reports laid-out composer frames (debug builds only), for `ComposerMetricsTests`.
        package struct ComposerProbe: Sendable {
            package var report: @MainActor @Sendable (_ part: String, _ frame: CGRect) -> Void
            package init(report: @escaping @MainActor @Sendable (_ part: String, _ frame: CGRect) -> Void) { self.report = report }
        }
    #endif

    extension EnvironmentValues {
        #if DEBUG
            /// Debug builds: receives the composer's frames when set.
            @Entry package var composerProbe: ComposerProbe? = nil
        #endif
        /// The width of the message column, measured by `MessageList` (nil until laid out).
        @Entry package var threadWidth: CGFloat? = nil
        /// The height the composer may take, from the header down to the keyboard or the bottom edge.
        ///
        /// Measured by `ChatScreen` (nil until laid out). Like Messages, the field grows until it fills it.
        @Entry package var composerRoom: CGFloat? = nil
        /// The header gave way while the person types (`ChatHeader.givesWay`): the thread's top fade shrinks with it.
        @Entry package var headerGaveWay = false
        /// The resolved chat tokens.
        @Entry package var chatTheme: ChatTheme = .standard
        /// The SDK instance the chat renders (the shared one, or a preview instance).
        @Entry package var pingFrontInstance: PingFront? = nil
        /// Snapshot and preview overrides.
        @Entry package var chatPreview: ChatPreviewState = ChatPreviewState()
        /// Whether the chat shows a close button (SDK-presented sheet).
        @Entry package var chatClose: ChatCloseAction? = nil
    }

    /// Closes the SDK-presented chat.
    package struct ChatCloseAction: Sendable {
        let action: @MainActor @Sendable () -> Void
        package init(_ action: @escaping @MainActor @Sendable () -> Void) { self.action = action }
        package func callAsFunction() { action() }
    }
#endif
