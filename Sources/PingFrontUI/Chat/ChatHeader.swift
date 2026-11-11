#if canImport(UIKit)
    import SwiftUI
    import PingFrontCore

    /// Who you are talking to: one teammate (face, name, role, local time), the team, or the app,
    /// with an honest reply expectation, on bar material with a hairline.
    struct ChatHeader: View {
        let pingFront: PingFront
        /// Short on height or at accessibility sizes, while the person types: only the controls show, so the thread
        /// and the composer keep the room above the keyboard.
        var givesWay = false
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @Environment(\.chatClose) private var close
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @Environment(\.verticalSizeClass) private var verticalSizeClass

        private var look: ResolvedLook { pingFront.look }
        private var team: [TeamMember] { pingFront.conversation.team.isEmpty ? look.team : pingFront.conversation.team }

        /// Short on height (an iPhone in landscape): the face and the name on one row, the status line in the thread,
        /// so the thread and the composer keep the screen above the keyboard (the full header left the composer
        /// under the keyboard).
        private var compact: Bool { verticalSizeClass == .compact }

        /// The teammate shown in the person header: the configured one, else the latest team author, else the first.
        private var member: TeamMember? {
            if let id = look.headerMemberId, let match = team.first(where: { $0.id == id }) { return match }
            if let lastAuthor = pingFront.conversation.messages.last(where: { $0.author.kind == .team })?.author.id,
                let match = team.first(where: { $0.id == lastAuthor })
            {
                return match
            }
            return team.first
        }

        /// In the empty state the large centered face is the header, so only the controls show here.
        private var minimal: Bool { pingFront.conversation.isEmpty }

        var body: some View {
            if givesWay {
                // Nothing on screen of its own: the close control stays in the navigation bar, over the thread, and the
                // thread and the composer take the room above the keyboard. VoiceOver still finds who the chat is with.
                Color.clear.frame(height: 0)
                    .accessibilityElement()
                    .accessibilityLabel(title(L10n(locale)))
                    .accessibilityAddTraits(.isHeader)
            } else {
                full
            }
        }

        private var full: some View {
            let t = L10n(locale)
            return VStack(spacing: 5) {
                if minimal {
                    Color.clear.frame(height: 44)
                } else {
                    identity(t)
                }
            }
            // Clear of the close control, which the sheet's navigation bar puts at the leading edge of this row.
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .overlay(alignment: .topTrailing) {
                if look.isDraft { DraftMarker().padding(.trailing, theme.gutter).padding(.top, 10) }
            }
            // Clear of the sheet's grabber when presented as a sheet.
            .padding(.top, close == nil ? 8 : 18)
            .padding(.bottom, 10)
            // An opaque surface; the thread fades out beneath its edge (see `MessageList`).
            .background(theme.background.ignoresSafeArea(edges: .top))
            .barBackground()
            .accessibilityElement(children: .contain)
        }

        @ViewBuilder
        private func identity(_ t: L10n) -> some View {
            let layout = compact ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 5))
            layout {
                face(compact: compact)
                Text(title(t))
                    .font(.footnote.weight(.semibold))
                    .fontDesign(theme.displayDesign)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(theme.teamBubble, in: Capsule())
                    .accessibilityAddTraits(.isHeader)
                // At accessibility sizes the status line moves into the thread (`HeaderStatusRow`), so the fixed
                // header stays small and the conversation keeps the screen.
                if !HeaderStatusRow.movesIntoThread(dynamicTypeSize, verticalSizeClass) { HeaderStatusRow(pingFront: pingFront) }
            }
        }

        @ViewBuilder
        private func face(compact: Bool) -> some View {
            switch look.headerStyle {
            case .person:
                // No teammate known yet: the app's icon, as in the welcome, not a teammate's initial (`AppIconView`).
                if let member {
                    AvatarView(name: member.name, url: member.avatarURL, size: compact ? 32 : 52, ring: false)
                } else {
                    AppIconView(look: look, size: compact ? 32 : 52)
                }
            case .team: FacesStack(members: Array(team.prefix(3)), size: compact ? 28 : 44)
            case .app: AppIconView(look: look, size: compact ? 32 : 52)
            }
        }

        private func title(_ t: L10n) -> String {
            switch look.headerStyle {
            case .person: member?.name ?? (t.text(look.headerTitle) ?? look.appName)
            case .team: t.text(look.headerTitle) ?? t("The %@ team", look.appName)
            case .app: t.text(look.headerTitle) ?? look.appName
            }
        }
    }

    /// The reply expectation and the teammate's local time: under the name in the header, or at the top of the
    /// thread at accessibility text sizes.
    ///
    /// "Usually replies within a few hours" over "It's 11:20 PM for Deniz": two complete sentences, never a bare time.
    /// The time uses the locale's own style (24-hour where that is the norm).
    struct HeaderStatusRow: View {
        let pingFront: PingFront

        /// At accessibility text sizes, or short on height, the line sits at the top of the thread instead of the header.
        static func movesIntoThread(_ size: DynamicTypeSize, _ vertical: UserInterfaceSizeClass?) -> Bool {
            size.isAccessibilitySize || vertical == .compact
        }
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @Environment(\.chatPreview) private var preview

        private var look: ResolvedLook { pingFront.look }

        var body: some View {
            let t = L10n(locale)
            if statusLine(t) != nil {
                TimelineView(.everyMinute) { _ in
                    Text(statusLine(t) ?? "")
                        .font(.caption)
                        .foregroundStyle(theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
            }
        }

        private func statusLine(_ t: L10n) -> String? {
            let team = pingFront.conversation.team.isEmpty ? look.team : pingFront.conversation.team
            let member =
                look.headerMemberId.flatMap { id in team.first { $0.id == id } }
                ?? pingFront.conversation.messages.last(where: { $0.author.kind == .team }).flatMap { last in
                    team.first { $0.id == last.author.id }
                } ?? team.first
            let expectation = HeaderStatus.expectation(
                t.replyExpectation(pingFront), shown: look.showsReplyExpectation,
                policy: pingFront.conversation.policy)
            var time: String?
            if look.showsLocalTime, look.headerStyle == .person, let member, let zone = member.timeZone.flatMap(TimeZone.init(identifier:))
            {
                var style = Date.FormatStyle(date: .omitted, time: .shortened)
                style.timeZone = zone
                style.locale = locale
                time = (preview.now ?? .now).formatted(style)
            }
            return HeaderStatus.text(expectation: expectation, time: time, name: member?.name) { t("It's %1$@ for %2$@", $0, $1) }
        }
    }

    /// A small, unobtrusive marker on test devices previewing an unpublished look.
    struct DraftMarker: View {
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale

        var body: some View {
            Text(L10n(locale)("Draft look"))
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(theme.muted, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
    }

    /// Setup problems and offline notices: under the header, or a row of the content at accessibility text sizes and
    /// short on height (in the thread, after what was delivered and before what waits to send; the welcome's first
    /// row), where text that grows without limit in a bar would leave no room for the thread and the composer.
    struct BannerStack: View {
        let pingFront: PingFront
        /// Inset from the sides by the gutter; false inside the thread, whose rows already are.
        var insetsSides = true
        @Environment(\.locale) private var locale

        /// The same rule as the status line (`HeaderStatusRow.movesIntoThread`): the bars hold no text that can grow
        /// without limit.
        static func movesIntoThread(_ size: DynamicTypeSize, _ vertical: UserInterfaceSizeClass?) -> Bool {
            HeaderStatusRow.movesIntoThread(size, vertical)
        }

        /// In the thread, the notice goes before the first message still waiting to send (its id), or last when none
        /// waits (`nil`): a message the person sends lands below it, in view, and its line says what the notice says.
        static func rowAfterNotice(in items: [TimelineItem]) -> String? {
            items.first {
                if case .pending = $0.content { return true }
                return false
            }?.id
        }

        var body: some View {
            let t = L10n(locale)
            VStack(spacing: 0) {
                if let problem = pingFront.configurationProblem {
                    #if DEBUG
                        Banner(
                            icon: "exclamationmark.triangle.fill", title: t("Setup problem"), message: problem.message,
                            footnote: t("Only shown in debug builds."), style: .problem, insetsSides: insetsSides)
                    #else
                        if problem.disablesSDK {
                            Banner(
                                icon: "exclamationmark.circle", title: nil, message: t("Chat is unavailable right now."), footnote: nil,
                                style: .notice, insetsSides: insetsSides)
                        }
                    #endif
                }
                if pingFront.conversation.isServerUnreachable {
                    // Online, but the service can't be reached: saying "offline" would send the person to their Wi-Fi.
                    Banner(
                        icon: "exclamationmark.icloud", title: nil,
                        message: t("Can't reach the chat right now. Messages will send when it's back."), footnote: nil, style: .notice,
                        insetsSides: insetsSides)
                } else if pingFront.conversation.isOffline || pingFront.conversation.phase.failedOffline {
                    Banner(
                        icon: "wifi.slash", title: nil, message: t("You're offline. Messages will send when you're back online."),
                        footnote: nil, style: .notice, insetsSides: insetsSides)
                }
            }
        }
    }

    extension Conversation.Phase {
        /// The first load failed because the device is offline (the live connection may not have said so yet).
        var failedOffline: Bool {
            if case .failed(let error) = self { return error.isOffline }
            return false
        }
    }

    struct Banner: View {
        enum Style { case problem, notice }
        let icon: String
        let title: String?
        let message: String
        let footnote: String?
        let style: Style
        var insetsSides = true
        @Environment(\.chatTheme) private var theme

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).font(.subheadline.weight(.semibold)) }
                    Text(message).font(.subheadline)
                    if let footnote { Text(footnote).font(.caption).opacity(0.85) }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(style == .problem ? theme.onStrong : theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // An inset rounded card under the header, not a full-bleed band.
            .background(
                style == .problem ? AnyShapeStyle(theme.stop) : AnyShapeStyle(.regularMaterial),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .padding(.horizontal, insetsSides ? theme.gutter : 0)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
#endif
