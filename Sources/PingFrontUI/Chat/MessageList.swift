#if canImport(UIKit)
    import SwiftUI
    import UserNotifications
    import UIKit
    import PingFrontCore

    /// The thread: load-older at the top, grouped rows, typing, and a jump-to-latest button with the
    /// new-message count.
    ///
    /// Starts at the bottom and stays there as messages arrive or the keyboard opens.
    struct MessageList: View {
        let pingFront: PingFront
        @Environment(\.chatTheme) private var theme
        @Environment(\.chatPreview) private var preview
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var atBottom = true
        @State private var seenSeq = 0
        /// iOS 17 only: until this time, growth of the thread (a card's native row loading, a plan line appearing)
        /// keeps the bottom in view even if the bottom marker has just been pushed off screen. iOS 18 and later keep the
        /// end from the scroll geometry instead (`StaysAtBottom`).
        @State private var followUntil = Date.distantPast
        /// Asks `StaysAtBottom` to pin the thread to its end and go there (a new message the thread follows).
        @State private var followRequest = 0
        @State private var threadWidth: CGFloat?
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @Environment(\.verticalSizeClass) private var verticalSizeClass
        @Environment(\.headerGaveWay) private var headerGaveWay
        /// Spacing grows with the text, as in Messages.
        @ScaledMetric(relativeTo: .body) private var spacingScale: CGFloat = 1
        #if DEBUG
            @Environment(\.composerProbe) private var probe
            private var debugProbe: DebugProbe { probe }
        #else
            private var debugProbe: DebugProbe { nil }
        #endif

        private var conversation: Conversation { pingFront.conversation }

        /// Whether the thread keeps its newest row in view.
        ///
        /// Previews, snapshots and staged audits that open the thread at its top or at a chosen row never follow
        /// the bottom, or a change after the sheet opens would scroll them away from it.
        private var followsBottom: Bool { !preview.scrolledToTop && preview.scrollTarget == nil }

        /// Brings the end of the thread into view and keeps it there while the arriving row lays out.
        ///
        /// The arriving row (and any card it changed) lays out after this update. iOS 18 pins the thread to its end, so
        /// each layout change scrolls again (`StaysAtBottom`); iOS 17 follows height changes for 3 s.
        private func followNewRows(_ proxy: ScrollViewProxy) {
            if #available(iOS 18, *) {
                followRequest += 1
            } else {
                followUntil = .now.addingTimeInterval(3)
            }
            withAnimation(.snappy) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
        }

        /// Whether the end of the thread is in view (it hides Jump to latest); what arrived up to now counts as seen.
        private func reachedEnd(_ atEnd: Bool) {
            if atBottom != atEnd { atBottom = atEnd }
            if atEnd { seenSeq = conversation.messages.last?.seq ?? 0 }
        }

        private var newCount: Int {
            if let forced = preview.newMessageCount { return forced }
            guard !atBottom else { return 0 }
            return conversation.messages.filter { $0.seq > seenSeq && !$0.isFromPerson }.count
        }

        var body: some View {
            let items = conversation.timeline
            let bannersInThread = BannerStack.movesIntoThread(dynamicTypeSize, verticalSizeClass)
            let noticeBefore = BannerStack.rowAfterNotice(in: items)
            let lastPersonSeq = conversation.lastPersonSeq
            let lastPersonItemId = conversation.lastPersonItemId
            ScrollViewReader { proxy in
                ScrollView {
                    // Eager on purpose: a lazy stack's estimated row heights break the bottom anchor at large
                    // Dynamic Type sizes, and the thread is paged (50 per page) so the cost stays small.
                    VStack(alignment: .leading, spacing: 0) {
                        if HeaderStatusRow.movesIntoThread(dynamicTypeSize, verticalSizeClass), !conversation.isEmpty {
                            HeaderStatusRow(pingFront: pingFront).padding(.bottom, theme.groupSpacing)
                        }
                        if conversation.hasOlder {
                            LoadOlderRow(isLoading: conversation.isLoadingOlder) { conversation.loadOlder() }
                                .onAppear { if !preview.scrolledToTop { conversation.loadOlder() } }
                        }
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 0) {
                                // At accessibility sizes or short on height, notices are a row of the thread
                                // (`BannerStack`): after what was delivered and before what waits to send, so a message
                                // the person sends lands below it and comes into view with its own line.
                                if bannersInThread, item.id == noticeBefore {
                                    BannerStack(pingFront: pingFront, insetsSides: false)
                                        .padding(.top, theme.groupSpacing)
                                }
                                if item.startsTimeSection, pingFront.look.timestamps == .grouped {
                                    TimeCaption(date: item.date)
                                        .padding(.top, theme.groupSpacing + 6)
                                        .padding(.bottom, 4)
                                }
                                MessageRow(
                                    item: item, pingFront: pingFront,
                                    isLastPersonMessage: item.id == lastPersonItemId,
                                    seen: lastPersonSeq.map { conversation.teamReadSeq >= $0 } ?? false
                                )
                                .padding(.top, (item.startsGroup ? theme.groupSpacing : theme.rowSpacing) * spacingScale)
                            }
                            // Debug builds with a probe (state tests): where each row is, to tell the place in the thread.
                            .probed("row \(item.id)", probe: debugProbe)
                            .id(item.id)
                            .transition(arrival(item.side))
                        }
                        PlanStatusLine(pingFront: pingFront)
                            .padding(.top, theme.groupSpacing)
                        if let typing = conversation.typing {
                            TypingRow(typing: typing)
                                .padding(.top, theme.groupSpacing)
                                .transition(.opacity)
                        }
                        if FirstMessageNote.applies(to: conversation.messages, pending: conversation.pending), conversation.policy.canSend {
                            FirstMessageNote(pingFront: pingFront)
                                .padding(.top, theme.groupSpacing)
                        }
                        // Nothing waits to send: the notice is the thread's last row, in view where it opens.
                        if bannersInThread, noticeBefore == nil {
                            BannerStack(pingFront: pingFront, insetsSides: false)
                                .padding(.top, theme.groupSpacing)
                        }
                        // The end of the thread, tall enough to clear the bottom edge fade, so scrolling to it shows
                        // the last row in full.
                        Color.clear
                            .frame(height: EdgeFade.bottom + 4)
                            .id(Self.bottomId)
                            // iOS 17 only (iOS 18 reads the scroll geometry in `StaysAtBottom`, which accounts for
                            // the bars' insets): whether the end is on screen, from the scroll view's visible bounds;
                            // in a plain stack, onAppear and onDisappear fire once, not as the marker scrolls in and out.
                            .onGeometryChange(for: Bool.self) { proxy in
                                guard let visible = proxy.bounds(of: .scrollView) else { return true }
                                return visible.intersects(CGRect(origin: .zero, size: proxy.size))
                            } action: { visible in
                                if #unavailable(iOS 18) { reachedEnd(visible) }
                            }
                            // What the thread opens with counts as seen, wherever it opens.
                            .onAppear { seenSeq = conversation.messages.last?.seq ?? 0 }
                    }
                    .environment(\.threadWidth, threadWidth)
                    // Debug builds with a probe: the thread's column, which centered system lines are centered on.
                    .probed("thread column", probe: debugProbe)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: {
                        threadWidth = $0
                    }
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: { _ in
                        // iOS 17: rows that grow after they arrive keep the bottom in view while it's being followed.
                        guard #unavailable(iOS 18) else { return }
                        if followsBottom, atBottom || Date.now < followUntil {
                            proxy.scrollTo(Self.bottomId, anchor: .bottom)
                        }
                    }
                    .padding(.horizontal, theme.gutter)
                    // The start of the thread, as tall as the top edge fade, so the first row is never faded while
                    // nothing is scrolled under the header (at the end, the bottom marker does the same).
                    .padding(.top, EdgeFade.top(headerGaveWay: headerGaveWay))
                    .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: items.map(\.id))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: conversation.typing)
                }
                .defaultScrollAnchor(preview.scrolledToTop ? .top : .bottom)
                .modifier(
                    StaysAtBottom(enabled: followsBottom, followRequest: followRequest, atEnd: reachedEnd) {
                        proxy.scrollTo(Self.bottomId, anchor: .bottom)
                    }
                )
                .edgeFade(top: EdgeFade.top(headerGaveWay: headerGaveWay))
                // A stable identifier for UI tests, like the header and the composer.
                .accessibilityIdentifier("PingFrontThread")
                .scrollDismissesKeyboard(.interactively)
                .overlay(alignment: .bottomTrailing) {
                    // Previews pinned to the top or to a row show it only when they set a count.
                    if followsBottom && !atBottom || preview.newMessageCount != nil {
                        JumpToLatestButton(count: newCount) {
                            withAnimation(.snappy) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                        }
                        .padding(theme.gutter)
                        .transition(.opacity)
                    }
                }
                .onAppear {
                    if #unavailable(iOS 18), followsBottom { followUntil = .now.addingTimeInterval(3) }
                    if let target = preview.scrollTarget { proxy.scrollTo(target, anchor: .top) }
                }
                .sensoryFeedback(.impact(weight: .light), trigger: conversation.messages.last(where: { !$0.isFromPerson })?.id)
                .onChange(of: items.last?.id) { _, _ in
                    // The person's own messages and receipts (which follow the person's actions, such as a
                    // purchase) always come into view; team messages only when already at the bottom.
                    let followsPerson = items.last?.side == .person || items.last?.side == .system
                    if followsBottom, atBottom || followsPerson { followNewRows(proxy) }
                    // A message that arrives in view is seen; one that arrives above the fold counts as new.
                    if atBottom { seenSeq = conversation.messages.last?.seq ?? 0 }
                }
                .onChange(of: pingFront.planEntitlement) { _, _ in
                    // The plan line under the thread changes after a purchase (the store refreshes a moment
                    // after the receipt): keep it in view the same way.
                    if followsBottom, atBottom || items.last?.side == .system { followNewRows(proxy) }
                }
                .task {
                    // iOS 17 only: keep the last message above the keyboard (iOS 18 and later: `StaysAtBottom`).
                    guard #unavailable(iOS 18) else { return }
                    for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardDidShowNotification).map({ _ in () })
                    {
                        if followsBottom, atBottom { withAnimation(.snappy) { proxy.scrollTo(Self.bottomId, anchor: .bottom) } }
                    }
                }
            }
        }

        static let bottomId = "pingfront.bottom"

        /// Keeps a thread the person left at its end there, through growth (late rows, the plan line) and room changes
        /// (the keyboard, a pushed chat's bars, a rotation), and says whether the end is in view (Jump to latest).
        ///
        /// Pinned or not is decided where a scroll ends, never by layout, which can push the end out of view for a
        /// moment without anyone scrolling. iOS 18 and later; iOS 17 keeps the bottom marker and `followUntil`.
        struct StaysAtBottom: ViewModifier {
            let enabled: Bool
            /// Changes when a new message should be followed: the thread pins itself to its end.
            let followRequest: Int
            /// Whether the end is in view (or the thread is pinned there and nobody is scrolling it).
            let atEnd: (Bool) -> Void
            /// Brings the end marker to the bottom of the visible thread (above the composer).
            let toBottom: () -> Void

            /// The scroll geometry that matters here.
            ///
            /// Equal while only the offset moves within the same state (at the end, near it, away), so the change action
            /// runs on layout changes and on crossings, not on every frame of a scroll (Apple's guidance for
            /// `onScrollGeometryChange`: transform the geometry to a value that changes rarely).
            nonisolated struct Extent: Equatable {
                static func == (a: Extent, b: Extent) -> Bool {
                    a.layout == b.layout && (a.remaining < 24) == (b.remaining < 24) && (a.remaining > 0.5) == (b.remaining > 0.5)
                }

                /// The content's height, the scroll view's height and its insets: a change to any of them is layout.
                var layout: [CGFloat]
                /// Points between the bottom of the visible thread (above the composer's inset) and the end of the
                /// content: 0 at the end.
                var remaining: CGFloat

                /// `visibleMaxY` is `ScrollGeometry.visibleRect.maxY`, which includes the insets the bars add; the
                /// thread the person sees ends `insetBottom` above it.
                init(contentHeight: CGFloat, container: CGFloat, insetTop: CGFloat, insetBottom: CGFloat, visibleMaxY: CGFloat) {
                    layout = [contentHeight, container, insetTop, insetBottom]
                    remaining = contentHeight - (visibleMaxY - insetBottom)
                }
            }

            /// Within 24 pt of the end counts as at the end.
            nonisolated static func isAtEnd(_ extent: Extent) -> Bool { extent.remaining < 24 }

            /// Whether a geometry change from `old` to `new` brings the thread back to its end: a layout change (not a
            /// scroll) while the thread is pinned there and nobody is moving it, that leaves the end out of place, short
            /// of the bottom of the visible thread or past it (a taller scroll view after a rotation, a blank gap).
            nonisolated static func keepsEnd(old: Extent, new: Extent, pinned: Bool, moving: Bool) -> Bool {
                old.layout != new.layout && pinned && !moving && abs(new.remaining) > 0.5
            }

            /// Whether Jump to latest stays hidden: the end is in view, or the thread is pinned to it and nobody is
            /// scrolling (a layout change is about to bring it back).
            nonisolated static func showsEnd(_ extent: Extent, pinned: Bool, moving: Bool) -> Bool {
                isAtEnd(extent) || (pinned && !moving)
            }

            func body(content: Content) -> some View {
                if #available(iOS 18, macOS 15, *) {
                    content.modifier(Follower(enabled: enabled, followRequest: followRequest, atEnd: atEnd, toBottom: toBottom))
                } else {
                    content
                }
            }

            @available(iOS 18, macOS 15, *)
            struct Follower: ViewModifier {
                let enabled: Bool
                let followRequest: Int
                let atEnd: (Bool) -> Void
                let toBottom: () -> Void
                /// At the end where the last scroll ended (a thread opens at its end).
                @State private var pinned = true
                /// The person is dragging the thread or it is still moving from their fling.
                @State private var moving = false
                /// An animated scroll is running (Jump to latest, following a new message, the system's).
                @State private var animating = false
                /// A scroll has ended at least once (the thread opening at its end, following a message, the person).
                @State private var hasScrolled = false
                /// The last geometry and what was last reported, kept out of view state: writing them on every scroll
                /// frame must not update the view (an update mid-scroll cut an animated scroll short).
                @State private var memory = Memory()

                final class Memory {
                    var extent: Extent?
                    var reported: Bool?
                }

                func body(content: Content) -> some View {
                    content
                        // When the container or content size changes (a rotation, the keyboard), the scroll view keeps
                        // its bottom where it was: a thread at its end stays there.
                        // https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor(_:for:)
                        .defaultScrollAnchor(enabled ? .bottom : nil, for: .sizeChanges)
                        .onScrollPhaseChange { old, phase, context in
                            moving = phase == .tracking || phase == .interacting || phase == .decelerating
                            animating = phase == .animating
                            let now = Self.extent(context.geometry)
                            // Where a scroll ends (not the first idle report, before the thread is laid out).
                            if phase == .idle, old != .idle {
                                pinned = isAtEnd(now)
                                hasScrolled = true
                            }
                            report(now)
                        }
                        .onScrollGeometryChange(for: Extent.self) { geometry in
                            Self.extent(geometry)
                        } action: { old, new in
                            if old.layout == new.layout, hasScrolled, !moving, !animating {
                                // The offset alone moved with no scroll phase: a scroll set in code (VoiceOver's, a
                                // test's). Where it leaves the thread decides, as for the person's own scroll. Not before
                                // the first scroll has ended: until then offsets are the hosting view's own (a chat
                                // pushed in a navigation stack is laid out off screen and its offset reset to the top).
                                pinned = isAtEnd(new)
                            } else if enabled, keepsEnd(old: old, new: new, pinned: pinned, moving: moving) {
                                toBottom()
                            }
                            report(new)
                        }
                        .onChange(of: followRequest) {
                            pinned = true
                            if let extent = memory.extent { report(extent) }
                        }
                }

                private func report(_ now: Extent) {
                    memory.extent = now
                    let shows = !enabled || showsEnd(now, pinned: pinned, moving: moving)
                    guard memory.reported != shows else { return }
                    memory.reported = shows
                    atEnd(shows)
                }

                nonisolated private static func extent(_ geometry: ScrollGeometry) -> Extent {
                    Extent(
                        contentHeight: geometry.contentSize.height, container: geometry.containerSize.height,
                        insetTop: geometry.contentInsets.top, insetBottom: geometry.contentInsets.bottom,
                        visibleMaxY: geometry.visibleRect.maxY)
                }
            }
        }

        /// New messages slide and scale in from their side.
        private func arrival(_ side: TimelineItem.Side) -> AnyTransition {
            guard !reduceMotion else { return .opacity }
            let edge: Edge = side == .person ? .trailing : .leading
            return .asymmetric(
                insertion: .move(edge: edge).combined(with: .scale(scale: 0.92, anchor: side == .person ? .bottomTrailing : .bottomLeading))
                    .combined(with: .opacity), removal: .opacity)
        }
    }

    /// The heights of the thread's edge fades under the header and over the composer.
    enum EdgeFade {
        static let top: CGFloat = 44
        static let bottom: CGFloat = 30
        /// Under the close control alone, when the header gave way: the room the thread has above the keyboard is
        /// small, and only the control's row needs the fade.
        static let topWithoutHeader: CGFloat = 16

        static func top(headerGaveWay: Bool) -> CGFloat { headerGaveWay ? topWithoutHeader : top }
    }

    extension View {
        /// The scroll view ends at the header and composer; content leaving it fades out completely at
        /// those edges, so no partially visible bubble or button sits hard against the bars.
        func edgeFade(top: CGFloat = EdgeFade.top) -> some View {
            mask {
                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0), .init(color: .black.opacity(0.2), location: 0.45),
                            .init(color: .black, location: 1),
                        ], startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: top)
                    Color.black
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0), .init(color: .black.opacity(0.2), location: 0.55),
                            .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: EdgeFade.bottom)
                }
            }
        }
    }

    /// A centered time caption at the start of a section: "Today 21:00".
    struct TimeCaption: View {
        let date: Date
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @Environment(\.chatPreview) private var preview
        @Environment(\.timeZone) private var timeZone

        var body: some View {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
        }

        private var label: String {
            let t = L10n(locale)
            var calendar = Calendar.current
            calendar.locale = locale
            calendar.timeZone = timeZone
            let now = preview.now ?? .now
            var time = Date.FormatStyle(date: .omitted, time: .shortened)
            time.timeZone = timeZone
            time.locale = locale
            let clock = date.formatted(time)
            if calendar.isDate(date, inSameDayAs: now) { return t("Today %@", clock) }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
                return t("Yesterday %@", clock)
            }
            var day = Date.FormatStyle().weekday(.wide).day().month(.abbreviated)
            day.timeZone = timeZone
            day.locale = locale
            return "\(date.formatted(day)), \(clock)"
        }
    }

    struct LoadOlderRow: View {
        let isLoading: Bool
        let load: () -> Void
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale

        var body: some View {
            let t = L10n(locale)
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.small)
                    Text(t("Loading earlier messages")).font(.footnote).foregroundStyle(theme.muted)
                } else {
                    Button(t("Load earlier messages"), action: load)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.authorName)
                        .frame(minHeight: 44)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
    }

    /// The Messages typing bubble: three animated dots in a tailed team bubble.
    struct TypingRow: View {
        let typing: TypingIndicator
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @Environment(\.pingFrontInstance) private var pingFront

        var body: some View {
            let t = L10n(locale)
            let name =
                typing.isAI
                ? (pingFront.map { aiDisplayName($0.look, author: typing.name, t) } ?? t("Assistant")) : (typing.name ?? t("The team"))
            HStack(alignment: .bottom, spacing: 6) {
                if pingFront?.look.showsAvatars ?? true {
                    AvatarView(
                        name: name, url: pingFront?.conversation.team.first(where: { $0.name == typing.name })?.avatarURL,
                        size: theme.avatarSize, isAI: typing.isAI, ring: false)
                }
                TypingDots()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(t("%@ is typing", name))
        }
    }

    /// Three dots that rise and fade in turn.
    ///
    /// Static when Reduce Motion is on.
    struct TypingDots: View {
        @Environment(\.chatTheme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        let wave = (sin((time * 2 * .pi / 1.2) - Double(index) * 0.9) + 1) / 2
                        Circle()
                            .fill(theme.onTeamBubble.opacity(0.35 + 0.4 * wave))
                            .frame(width: 8, height: 8)
                            .offset(y: -2.5 * wave)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .padding(.leading, theme.tailSpace)
                .background {
                    BubbleShape(radius: theme.bubbleRadius, tail: true, trailing: false, tailWidth: theme.tailSpace)
                        .fill(theme.teamBubble)
                        .flipsForRightToLeftLayoutDirection(true)
                }
            }
            .accessibilityHidden(true)
        }
    }

    struct JumpToLatestButton: View {
        let count: Int
        let action: () -> Void
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale

        var body: some View {
            let t = L10n(locale)
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down").font(.footnote.weight(.semibold))
                    Text(count > 0 ? t("%lld new messages", count) : t("Jump to latest"))
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(count > 0 ? theme.onAccent : theme.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(count > 0 ? theme.accent : theme.background, in: Capsule())
                .overlay(Capsule().strokeBorder(count > 0 ? Color.clear : theme.rule, lineWidth: 1))
                .shadow(color: Color(rgb: Contrast.darkText).opacity(0.18), radius: 16, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(count > 0 ? t("%lld new messages", count) : t("Jump to latest"))
            .accessibilityHint(t("Jump to latest"))
        }
    }

    /// The assistant's display name: the configured `aiName`, else the author name.
    func aiDisplayName(_ look: ResolvedLook, author: String?, _ t: L10n) -> String {
        if look.aiName != "Assistant" { return look.aiName }
        return author ?? t("Assistant")
    }

    /// After the person's first message, before any reply: when to expect one, and (with push and no
    /// decision yet) a way to be told.
    struct FirstMessageNote: View {
        let pingFront: PingFront
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @State private var canAskForNotifications = false

        /// Only once the person's latest message is delivered: "You can close this" would be untrue while one still
        /// waits to send (offline, unreachable, held).
        static func applies(to messages: [Message], pending: [PendingMessage] = []) -> Bool {
            guard pending.isEmpty else { return false }
            guard let first = messages.firstIndex(where: { $0.author.kind == .person }) else { return false }
            return !messages[first...].contains { $0.author.kind == .team || $0.author.kind == .ai }
        }

        var body: some View {
            let t = L10n(locale)
            let expectation = pingFront.look.showsReplyExpectation ? t.replyExpectation(pingFront) : nil
            VStack(spacing: 8) {
                Text(
                    expectation.map {
                        t("%@. You can close this; the reply waits here.", $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))
                    }
                        ?? t("You can close this; the reply waits here.")
                )
                .font(.footnote)
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                if canAskForNotifications, let request = pingFront.notificationsRequest {
                    Button(t("Turn on notifications")) {
                        Task {
                            _ = await request()
                            canAskForNotifications = false
                        }
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
            .task {
                guard pingFront.notificationsRequest != nil else { return }
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                canAskForNotifications = settings.authorizationStatus == .notDetermined
            }
        }
    }
#endif
