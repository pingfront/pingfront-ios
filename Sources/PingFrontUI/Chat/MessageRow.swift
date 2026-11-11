#if canImport(UIKit)
    import SwiftUI
    import UIKit
    import PingFrontCore

    /// One timeline row: team (left, system gray), person (right, accent), or a centered system line.
    struct MessageRow: View {
        let item: TimelineItem
        let pingFront: PingFront
        var isLastPersonMessage = false
        var seen = false

        var body: some View {
            switch item.content {
            case .message(let message):
                switch item.side {
                case .system: ReceiptRows(message: message)
                case .team: TeamMessageRow(item: item, message: message, pingFront: pingFront)
                case .person:
                    PersonMessageRow(
                        item: item, message: message, pending: nil, status: isLastPersonMessage ? (seen ? .read : .delivered) : nil)
                }
            case .pending(let pending):
                PersonMessageRow(item: item, message: nil, pending: pending, status: nil)
            }
        }
    }

    // MARK: Team

    struct TeamMessageRow: View {
        let item: TimelineItem
        let message: Message
        let pingFront: PingFront
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @State private var showOriginal = false

        private var look: ResolvedLook { pingFront.look }

        var body: some View {
            let t = L10n(locale)
            let author = pingFront.conversation.displayAuthor(of: message)
            let name = item.isAI ? aiDisplayName(look, author: author.name, t) : (author.name ?? t("The team"))
            let avatarColumn: CGFloat = look.showsAvatars ? theme.avatarSize + 6 : 0
            VStack(alignment: .leading, spacing: theme.rowSpacing) {
                if item.startsPing, let ping = message.ping {
                    PingLine(ping: ping, authorName: name)
                        .padding(.bottom, 8)
                }
                if item.startsGroup, look.showsNames || item.isAI {
                    HStack(spacing: 5) {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(theme.authorName)
                        if item.isAI { AITag() }
                    }
                    .padding(.leading, avatarColumn + theme.tailSpace + 12)
                    .padding(.bottom, 1)
                    .accessibilityHidden(true)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    if look.showsAvatars {
                        if item.endsGroup {
                            AvatarView(name: name, url: author.avatarURL, size: theme.avatarSize, isAI: item.isAI, ring: false)
                        } else {
                            Color.clear.frame(width: theme.avatarSize, height: 1)
                        }
                    }
                    VStack(alignment: .leading, spacing: theme.rowSpacing) {
                        PartsView(
                            message: message, side: .team, texts: displayedTexts, pingFront: pingFront, joinTop: !item.startsGroup,
                            joinBottom: !item.endsGroup)
                        if message.translation != nil {
                            Button(showOriginal ? t("Show translation") : t("Show original")) { showOriginal.toggle() }
                                .font(.caption)
                                .foregroundStyle(theme.muted)
                                .padding(.leading, theme.tailSpace + 12)
                        }
                    }
                }
                // A receipt in a message with other parts is still a centered system line: on the row's (the
                // thread's) width, not the bubble column beside the avatar.
                if PartsView.rowDrawsReceipts(message) { ReceiptRows(message: message) }
                if look.timestamps == .always {
                    Timestamp(date: message.createdAt)
                        .padding(.leading, avatarColumn + theme.tailSpace + 12)
                }
                if item.isAI, item.endsGroup {
                    HandOffButton(pingFront: pingFront)
                        .padding(.leading, avatarColumn + theme.tailSpace)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }

        private var displayedTexts: [String]? {
            guard let translation = message.translation, !showOriginal else { return nil }
            return translation.texts
        }
    }

    /// Above a message the team sent first: a centered system line with the pink ping dot,
    /// "Deniz messaged you first".
    ///
    /// Tapping it explains why.
    struct PingLine: View {
        let ping: PingOrigin
        let authorName: String
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @State private var explaining = false
        #if DEBUG
            @Environment(\.composerProbe) private var probe
            private var debugProbe: DebugProbe { probe }
        #else
            private var debugProbe: DebugProbe { nil }
        #endif

        var body: some View {
            let t = L10n(locale)
            Button {
                explaining = true
            } label: {
                HStack(spacing: 6) {
                    PingDot()
                    // The system line: 13 pt semibold, scaled (pingfront's design tokens).
                    Text(t("%@ messaged you first", authorName))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.muted)
                    Image(systemName: "info.circle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.muted)
                }
                .probed("line ping", probe: debugProbe)
                // Tappable (it explains the ping), so a full 44 pt target.
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(t("%@ messaged you first", authorName))
            .accessibilityHint(t("Why you got this message"))
            .popover(isPresented: $explaining) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("Why you got this message")).font(.headline)
                    Text(Self.explanation(ping, authorName: authorName, t))
                        .font(.body)
                    Text(t("Reply if you like, or ignore it.")).font(.body).foregroundStyle(theme.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(idealWidth: 300)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    extension PingLine {
        /// The server's localized explanation first; otherwise a local sentence for the structured reason.
        static func explanation(_ ping: PingOrigin, authorName: String, _ t: L10n) -> String {
            if !ping.explanation.isEmpty { return ping.explanation }
            switch ping.reason?.code {
            case .manual?: return t("%@ wrote to you first.", authorName)
            case .moment?: return t("Sent after something you did in the app.")
            case .storeEvent?: return t("Sent after a change to your subscription.")
            case .scheduled?: return t("Sent at a time the team chose.")
            case .unknown?, nil:
                return ping.kind == .manual ? t("%@ wrote to you first.", authorName) : t("Sent automatically by the team.")
            }
        }
    }

    /// Always visible under assistant replies: ask for a person.
    struct HandOffButton: View {
        let pingFront: PingFront
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale

        var body: some View {
            let t = L10n(locale)
            Button {
                pingFront.conversation.send(text: t("I'd like to talk to a person, please."))
            } label: {
                Text(t("Ask for a person"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accentText)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
    }

    // MARK: Person

    struct PersonMessageRow: View {
        enum Status { case delivered, read }
        let item: TimelineItem
        let message: Message?
        let pending: PendingMessage?
        let status: Status?
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @Environment(\.pingFrontInstance) private var pingFront
        @State private var confirmingFailure = false

        /// What this undelivered message waits for (see `PendingLine.heldFor(_:in:)`).
        private var heldFor: SendPolicy.Reason? {
            guard let pending, let conversation = pingFront?.conversation else { return nil }
            return PendingLine.heldFor(pending, in: conversation)
        }

        /// This message's pending line, or `nil` when it isn't the last of a run with the same line (as in Messages,
        /// where a status shows under the last message it applies to).
        private var pendingLine: PendingLine? {
            guard let pending, let conversation = pingFront?.conversation else { return nil }
            let lines = conversation.pending.map { PendingLine.line(for: $0, in: conversation) }
            guard let index = conversation.pending.firstIndex(where: { $0.clientId == pending.clientId }) else {
                return PendingLine.line(for: pending, in: conversation)
            }
            return PendingLine.showsLine(lines, at: index) ? lines[index] : nil
        }

        var body: some View {
            let t = L10n(locale)
            VStack(alignment: .trailing, spacing: theme.rowSpacing) {
                // No spacing: the mark's 44 pt target already leaves about 11 pt between its glyph and the bubble.
                HStack(alignment: .center, spacing: 0) {
                    if pending != nil { Spacer(minLength: BubbleMetrics.farSide) }
                    // Like Messages: the red "!" sits right next to the bubble and offers Try again / Delete. Only for a
                    // failure that needs the person: a held message goes by itself, so it gets no mark.
                    if let pending, pending.state == .failed, !pending.isHeld, let pingFront {
                        Button {
                            confirmingFailure = true
                        } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(theme.stop)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t("Not delivered"))
                        .accessibilityHint(t("Opens options."))
                        .confirmationDialog(t("Not delivered"), isPresented: $confirmingFailure, titleVisibility: .visible) {
                            // Retry only where sending again can work: while the person can't send (the notice in
                            // the composer's place says why), the row offers Delete alone.
                            if pingFront.conversation.policy.canSend {
                                Button(t("Try again")) { pingFront.conversation.retry(pending) }
                            }
                            Button(t("Delete"), role: .destructive) { pingFront.conversation.discard(pending) }
                        }
                    }
                    VStack(alignment: .trailing, spacing: theme.rowSpacing) {
                        if let message, let pingFront {
                            PartsView(
                                message: message, side: .person, texts: nil, pingFront: pingFront, joinTop: !item.startsGroup,
                                joinBottom: !item.endsGroup)
                        } else if let pending {
                            PendingParts(pending: pending, joinTop: !item.startsGroup, joinBottom: !item.endsGroup)
                                .fixedSize(horizontal: false, vertical: true)
                                .modifier(HeldActions(pending: pending, heldFor: heldFor, pingFront: pingFront))
                        }
                    }
                }
                if let message, PartsView.rowDrawsReceipts(message) { ReceiptRows(message: message) }
                // Clear of the bubble's tail, so the line never sits on the accent (left of the tail in RTL too).
                // Wrapped lines end at the bubble's edge and never run past where incoming bubbles start.
                statusLine
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, theme.tailSpace + 6)
                    .padding(.leading, BubbleMetrics.farSide)
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .contain)
        }

        @ViewBuilder
        private var statusLine: some View {
            let t = L10n(locale)
            if let pending, pingFront != nil {
                switch pending.state {
                case .failed where pending.isHeld:
                    // Refused because sending is closed: it goes by itself when sending reopens, and says when, muted
                    // like a queued message, once under the last message that waits for the same thing. Delete is in
                    // the bubble's context menu and VoiceOver's actions.
                    if let line = pendingLine {
                        Text(line.text(t))
                            .font(.caption)
                            .foregroundStyle(theme.muted)
                    }
                case .failed:
                    // Like Messages: the red line says what happened; it and the "!" beside the bubble open the one
                    // Try again / Delete dialog (the same two actions are not repeated inline). VoiceOver hears it once,
                    // on the "!". The 44 pt target extends past the line instead of adding space under it.
                    Button {
                        confirmingFailure = true
                    } label: {
                        Text(t("Not delivered"))
                            .font(.caption)
                            .foregroundStyle(theme.stop)
                            .contentShape(Rectangle().inset(by: -14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                    .sensoryFeedback(.error, trigger: pending.state)
                case .queued, .sending:
                    // Honest status, as on Android and the web: offline it waits; only the message on the wire (or
                    // not tried yet) says Sending…; one the outbox will retry is not sent yet; while sending is
                    // closed, or behind a held message, it waits for the same thing. Once per run of the same line.
                    if let line = pendingLine {
                        Text(line.text(t))
                            .font(.caption)
                            .foregroundStyle(theme.muted)
                    }
                }
            } else if let message {
                HStack(spacing: 4) {
                    switch status {
                    case .read?: Text(t("Read")).font(.caption.weight(.semibold)).foregroundStyle(theme.muted)
                    case .delivered?: Text(t("Delivered")).font(.caption.weight(.semibold)).foregroundStyle(theme.muted)
                    case nil: EmptyView()
                    }
                    if pingFront?.look.timestamps == .always { Timestamp(date: message.createdAt) }
                }
            }
        }
    }

    /// The line under a message that has not been delivered yet (not failed).
    nonisolated enum PendingLine: Equatable {
        /// The device has no network: it goes when the connection is back.
        case waiting
        /// On the wire right now, or not tried yet.
        case sending
        /// After an attempt the outbox will retry (rate limit, backoff, the service unreachable).
        case retrying
        /// Sending is closed for this reason (the app paused, verification required): nothing retries until it
        /// reopens, and then the message goes by itself. Never for a blocked person, who is promised nothing.
        case held(SendPolicy.Reason)

        /// The line for an undelivered message.
        ///
        /// `unreachable`: online, but the service can't be reached; the outbox keeps retrying, so the message is not
        /// sent yet rather than waiting for a connection the device already has.
        ///
        /// `behindRetry`: a message ahead of it waits to be tried again, so this one is not on the wire either (only the
        /// message actually sending says Sending…).
        init(
            _ state: PendingMessage.State, attempts: Int = 0, held: SendPolicy.Reason? = nil, offline: Bool, unreachable: Bool = false,
            behindRetry: Bool = false
        ) {
            if let held {
                self = .held(held)
            } else if offline, !unreachable {
                self = .waiting
            } else if unreachable {
                self = .retrying
            } else if state == .sending || (attempts == 0 && !behindRetry) {
                self = .sending
            } else {
                self = .retrying
            }
        }

        /// What an undelivered message waits for: its own hold, a closed policy that holds messages, or a held message
        /// ahead of it (the queue goes in order). `nil` when it waits for nothing of the kind.
        @MainActor static func heldFor(_ pending: PendingMessage, in conversation: Conversation) -> SendPolicy.Reason? {
            if let reason = pending.heldFor { return reason }
            guard pending.state == .queued || pending.state == .sending else { return nil }
            if let reason = conversation.policy.reason, reason.holdsMessages { return reason }
            let ahead = conversation.pending.prefix { $0.clientId != pending.clientId }
            return ahead.last(where: \.isHeld)?.heldFor
        }

        /// The line under an undelivered message; `nil` for a failure that needs the person ("Not delivered", always
        /// under its own message).
        @MainActor static func line(for pending: PendingMessage, in conversation: Conversation) -> PendingLine? {
            if pending.state == .failed, !pending.isHeld { return nil }
            let ahead = conversation.pending.prefix { $0.clientId != pending.clientId }
            return PendingLine(
                pending.state, attempts: pending.attempts, held: heldFor(pending, in: conversation),
                offline: conversation.isOffline, unreachable: conversation.isServerUnreachable,
                behindRetry: ahead.contains { $0.state == .queued && $0.attempts > 0 })
        }

        /// Whether the message at `index` shows its line.
        ///
        /// Only the last of a run of consecutive messages with the same line does, as Messages shows Delivered and Read
        /// once, under the last message they apply to. A failure that needs the person (`nil`) ends a run.
        static func showsLine(_ lines: [PendingLine?], at index: Int) -> Bool {
            guard lines.indices.contains(index), let line = lines[index] else { return false }
            let next = lines.index(after: index)
            return next == lines.endIndex || lines[next] != line
        }

        @MainActor func text(_ t: L10n) -> String {
            switch self {
            case .waiting: t("Waiting for connection")
            case .sending: t("Sending…")
            case .retrying: t("Not sent yet. Trying again soon.")
            case .held(.verificationRequired): t("Not sent yet. It will send after you sign in.")
            case .held: t("Not sent yet. It will send when the chat is back.")
            }
        }
    }

    struct PendingParts: View {
        let pending: PendingMessage
        var joinTop = false
        var joinBottom = false
        @Environment(\.chatTheme) private var theme

        var body: some View {
            VStack(alignment: .trailing, spacing: theme.rowSpacing) {
                ForEach(Array(pending.photos.enumerated()), id: \.offset) { _, photo in
                    LocalPhoto(photo: photo)
                }
                if let text = pending.text {
                    // Opaque at full contrast: the state is in the status line, not in faded text.
                    TextBubble(text: text, side: .person, joinTop: joinTop, joinBottom: joinBottom, fillsRow: false)
                }
            }
        }
    }

    /// A held message (refused while sending is closed; it goes by itself later), or one queued behind it, has no "!" to
    /// open: Delete is in its context menu, as in Messages, and among VoiceOver's actions.
    ///
    /// - [contextMenu(menuItems:)](https://developer.apple.com/documentation/swiftui/view/contextmenu(menuitems:))
    /// - [accessibilityAction(named:_:)](https://developer.apple.com/documentation/swiftui/view/accessibilityaction(named:_:))
    struct HeldActions: ViewModifier {
        let pending: PendingMessage
        let heldFor: SendPolicy.Reason?
        let pingFront: PingFront?
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale

        func body(content: Content) -> some View {
            if heldFor != nil, pending.state != .sending, let pingFront {
                let t = L10n(locale)
                content
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: theme.bubbleRadius, style: .continuous))
                    .contextMenu {
                        Button(t("Delete"), role: .destructive) { pingFront.conversation.discard(pending) }
                    }
                    .accessibilityAction(named: t("Delete")) { pingFront.conversation.discard(pending) }
            } else {
                content
            }
        }
    }

    struct LocalPhoto: View {
        let photo: PendingMessage.Photo
        @Environment(\.pingFrontInstance) private var pingFront

        var body: some View {
            let key = "pending:\(photo.file)"
            ImageFrame(width: photo.width, height: photo.height, image: ImageStore.shared.image(for: key))
                .task(id: key) {
                    guard ImageStore.shared.image(for: key) == nil, let data = await pingFront?.conversation.photoData(for: photo),
                        let image = ImageStore.downsample(data, maxPixelSize: 720)
                    else { return }
                    ImageStore.shared.set(image, for: key)
                }
        }
    }

    // MARK: Parts

    /// Text bubbles, photos and cards, in order.
    ///
    /// The last bubble of a group gets the tail.
    struct PartsView: View {
        let message: Message
        let side: TimelineItem.Side
        let texts: [String]?
        let pingFront: PingFront
        var joinTop = false
        var joinBottom = false
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale

        var body: some View {
            let t = L10n(locale)
            let known = message.parts.filter(Self.isKnown)
            // Content this version cannot show: the server's plain-text rendering of the whole message stands in.
            let fallback = Self.fallback(message)
            // Receipts are drawn by the row at the thread's width, so the column (and its tails) leaves them out.
            let entries = fallback == nil ? Self.entries(known, texts: texts).filter { !Self.isReceipt($0.part) } : []
            let bubbles = entries.filter {
                if case .text = $0.part { return true }
                return false
            }.map(\.offset)
            if let fallback {
                TextBubble(text: fallback, side: side, authorName: message.author.name, joinTop: joinTop, joinBottom: joinBottom)
            } else if known.isEmpty {
                TextBubble(
                    text: t("This message needs a newer version of the app."), side: side, joinTop: joinTop, joinBottom: joinBottom,
                    muted: true)
            }
            ForEach(entries, id: \.offset) { entry in
                switch entry.part {
                case .text:
                    // Only the very last text bubble of a group carries the tail.
                    TextBubble(
                        text: entry.text ?? "", side: side, authorName: message.author.name,
                        joinTop: joinTop || entry.offset != bubbles.first,
                        joinBottom: joinBottom || entry.offset != bubbles.last || entry.offset != entries.last?.offset)
                    if let url = LinkText.soleLink(in: entry.text ?? "") {
                        LinkPreviewCard(url: url)
                            .padding(side == .person ? .trailing : .leading, theme.tailSpace)
                            .frame(maxWidth: .infinity, alignment: side == .person ? .trailing : .leading)
                    }
                case .image(let image):
                    let images = known.compactMap { part -> ImagePart? in
                        if case .image(let image) = part { return image }
                        return nil
                    }
                    if images.count < 2 {
                        AttachmentImage(part: image, message: message, pingFront: pingFront)
                            .padding(side == .person ? .trailing : .leading, theme.tailSpace)
                    } else if image.attachmentId == images.first?.attachmentId {
                        PhotoGrid(parts: images, message: message, pingFront: pingFront)
                            .padding(side == .person ? .trailing : .leading, theme.tailSpace)
                    }
                case .card(let card):
                    CardView(part: card, message: message, pingFront: pingFront)
                        .padding(side == .person ? .trailing : .leading, theme.tailSpace)
                case .receipt:
                    // Drawn by the row at the thread's width (`ReceiptRows`).
                    EmptyView()
                case .unknown:
                    EmptyView()
                }
            }
        }
    }

    extension PartsView {
        struct Entry {
            let offset: Int
            let part: MessagePart
            let text: String?
        }

        /// The server's plain-text rendering, when the message has content this version cannot show.
        static func fallback(_ message: Message) -> String? {
            guard !message.parts.allSatisfy(isKnown) else { return nil }
            return message.fallback.flatMap { $0.isEmpty ? nil : $0 }
        }

        /// The row draws the message's receipts as centered system lines (unless the fallback text stands in for all).
        static func rowDrawsReceipts(_ message: Message) -> Bool {
            message.parts.contains(where: isReceipt) && fallback(message) == nil
        }

        static func isReceipt(_ part: MessagePart) -> Bool {
            if case .receipt = part { return true }
            return false
        }

        static func isKnown(_ part: MessagePart) -> Bool {
            switch part {
            case .unknown: return false
            case .card(let card):
                if case .unknown = card.card { return false }
                return true
            default: return true
            }
        }

        /// Pairs each part with its displayed text (the translation when shown).
        static func entries(_ parts: [MessagePart], texts: [String]?) -> [Entry] {
            var textIndex = 0
            return parts.enumerated().map { offset, part in
                guard case .text(let text) = part else { return Entry(offset: offset, part: part, text: nil) }
                defer { textIndex += 1 }
                let shown = texts.flatMap { textIndex < $0.count ? $0[textIndex] : nil } ?? text
                return Entry(offset: offset, part: part, text: shown)
            }
        }
    }

    /// A Messages bubble: accent for the person, system gray for the team, a tail on the last of a group.
    struct TextBubble: View {
        let text: String
        let side: TimelineItem.Side
        var authorName: String?
        var joinTop = false
        var joinBottom = false
        var muted = false
        /// Reserve the far side of the row (false when the row already places the bubble).
        var fillsRow = true
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @Environment(\.threadWidth) private var threadWidth
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        /// How much the body text has grown with Dynamic Type.
        @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
        /// Insets grow with the text but more slowly, as in Messages (10 pt top at the default size, about
        /// 13 pt at AX3, where the text is 2.35 times larger).
        private var insetScale: CGFloat { BubbleMetrics.insetScale(textScale: textScale) }

        var body: some View {
            let isPerson = side == .person
            let maxWidth = threadWidth.map { BubbleMetrics.maxWidth(threadWidth: $0, accessibility: dynamicTypeSize.isAccessibilitySize) }
            HStack(spacing: 0) {
                if isPerson, fillsRow { Spacer(minLength: threadWidth == nil ? BubbleMetrics.farSide : 0) }
                if fillsRow {
                    bubble(isPerson: isPerson).frame(maxWidth: maxWidth, alignment: isPerson ? .trailing : .leading)
                } else {
                    // The row places the bubble (a failed send's mark sits beside it): as wide as its text, never
                    // wider, so nothing to its side drifts away from it.
                    WidthCap(maxWidth: maxWidth) { bubble(isPerson: isPerson) }
                }
                if !isPerson { Spacer(minLength: threadWidth == nil ? BubbleMetrics.farSide : 0) }
            }
        }

        private func bubble(isPerson: Bool) -> some View {
            let tail = !joinBottom
            let inset = theme.bubblePadding
            return Text(LinkText.attributed(text))
                .font(muted ? .subheadline : .body)
                .tint(muted ? theme.muted : (isPerson ? theme.onAccent : theme.onTeamBubble))
                .italic(muted)
                .foregroundStyle(muted ? theme.muted : (isPerson ? theme.onAccent : theme.onTeamBubble))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(
                    EdgeInsets(
                        top: inset.top * insetScale, leading: inset.leading * insetScale, bottom: inset.bottom * insetScale,
                        trailing: inset.trailing * insetScale)
                )
                .padding(isPerson ? .trailing : .leading, theme.tailSpace)
                .background {
                    BubbleShape(radius: theme.bubbleRadius, tail: tail, trailing: isPerson, tailWidth: theme.tailSpace)
                        .fill(isPerson ? theme.accent : theme.teamBubble)
                        .flipsForRightToLeftLayoutDirection(true)
                }
                .accessibilityLabel(isPerson ? L10n(locale)("You: %@", text) : "\(authorName.map { "\($0): " } ?? "")\(text)")
        }
    }

    /// Offers its content at most `maxWidth` and takes only the size the content needs (unlike
    /// `frame(maxWidth:)`, which grows to `maxWidth` whenever the row has room).
    struct WidthCap: Layout {
        var maxWidth: CGFloat?

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            return child.sizeThatFits(capped(proposal))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }

        private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
            guard let maxWidth else { return proposal }
            return ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
        }
    }

    struct AttachmentImage: View {
        let part: ImagePart
        let message: Message
        let pingFront: PingFront
        var tile: CGFloat?
        @Environment(\.locale) private var locale
        @Environment(\.chatPreview) private var preview
        @State private var viewing = false
        @Namespace private var zoom

        var body: some View {
            if part.removed {
                RemovedPhoto(tile: tile)
            } else {
                photo
                    .onChange(of: preview.openPhoto?.attachmentId, initial: true) { _, id in
                        guard let request = preview.openPhoto, id == part.attachmentId else { return }
                        request.attachmentId = nil
                        viewing = true
                    }
            }
        }

        private var photo: some View {
            let key = part.attachmentId
            let t = L10n(locale)
            return ImageFrame(width: part.width, height: part.height, image: ImageStore.shared.image(for: key), tile: tile)
                .contentShape(Rectangle())
                .modifier(ZoomSource(id: key, namespace: zoom))
                .onTapGesture { viewing = true }
                .fullScreenCover(isPresented: $viewing) {
                    PhotoViewer(
                        part: part, pingFront: pingFront,
                        sender: message.author.kind == .person ? t("You") : (message.author.name ?? pingFront.look.appName),
                        date: message.createdAt, zoom: zoom)
                }
                .accessibilityLabel(L10n(locale)("Photo"))
                .accessibilityAddTraits([.isImage, .isButton])
                .accessibilityHint(L10n(locale)("Opens the photo full screen"))
                .task(id: key) {
                    guard let url = part.url else { return }
                    // Decoded at bubble size (220 pt at 3x); the full-screen viewer loads its own copy.
                    await ImageStore.shared.load(url, key: key, maxPixelSize: 720) { await pingFront.conversation.refreshedURL(for: part) }
                }
        }
    }

    /// A photo the app's retention deleted (`removed: true`), shown as a quiet muted line.
    ///
    /// Never fetched and never spinning. In a photo grid it fills its tile with the symbol alone.
    struct RemovedPhoto: View {
        var tile: CGFloat?
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale

        var body: some View {
            let label = L10n(locale)("Photo removed")
            Group {
                if let tile {
                    // Said in words in the grid too, so a removed photo never looks like one still loading.
                    VStack(spacing: 4) {
                        Image(systemName: "photo").font(.body)
                        Text(label)
                            .font(.caption2)
                            .italic()
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(4)
                    .frame(width: tile, height: tile)
                    .background(theme.teamBubble, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Label(label, systemImage: "photo")
                        .font(.subheadline)
                        .italic()
                        .padding(theme.bubblePadding)
                        .background(theme.teamBubble, in: RoundedRectangle(cornerRadius: theme.bubbleRadius, style: .continuous))
                }
            }
            .foregroundStyle(theme.muted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }

    /// A photo at its aspect ratio, at most 240 × 320 pt, with a placeholder while loading.
    struct ImageFrame: View {
        let width: Int
        let height: Int
        let image: UIImage?
        /// A square tile of this side (photo grids), cropped to fill.
        var tile: CGFloat?
        @Environment(\.chatTheme) private var theme

        var body: some View {
            let aspect = tile == nil ? CGFloat(max(width, 1)) / CGFloat(max(height, 1)) : 1
            let boxWidth = tile ?? min(220, 300 * aspect)
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    theme.teamBubble.overlay(ProgressView())
                }
            }
            .frame(width: boxWidth, height: boxWidth / aspect)
            .clipShape(RoundedRectangle(cornerRadius: tile == nil ? theme.bubbleRadius : 4, style: .continuous))
        }
    }

    /// Two to six photos of one message: a two-column grid inside one rounded shape, like Messages.
    struct PhotoGrid: View {
        let parts: [ImagePart]
        let message: Message
        let pingFront: PingFront
        @Environment(\.chatTheme) private var theme

        var body: some View {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(Array(stride(from: 0, to: parts.count, by: 2)), id: \.self) { row in
                    GridRow {
                        ForEach(row..<min(row + 2, parts.count), id: \.self) { index in
                            AttachmentImage(part: parts[index], message: message, pingFront: pingFront, tile: 108)
                                .gridCellColumns(parts.count.isMultiple(of: 2) || index < parts.count - 1 ? 1 : 2)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.bubbleRadius, style: .continuous))
        }
    }

    // MARK: System lines and timestamps

    struct ReceiptRows: View {
        let message: Message
        var body: some View {
            VStack(spacing: 2) {
                ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                    if case .receipt(let receipt) = part { ReceiptLine(receipt: receipt) }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// A centered system line: "Trial extended to 14 Nov".
    ///
    /// Something done for the person has the green check; the AI teammate's hand-off ("Deniz will reply")
    /// records nothing done, so it shows without it.
    struct ReceiptLine: View {
        let receipt: ReceiptPart
        @Environment(\.chatTheme) private var theme
        #if DEBUG
            @Environment(\.composerProbe) private var probe
            private var debugProbe: DebugProbe { probe }
        #else
            private var debugProbe: DebugProbe { nil }
        #endif

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if receipt.action != .handedOff {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.lift)
                        .accessibilityHidden(true)
                }
                Text(receipt.text)
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
            }
            .probed("line receipt \(receipt.text)", probe: debugProbe)
            // The system line: 13 pt semibold, scaled (pingfront's design tokens).
            .font(.footnote.weight(.semibold))
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    struct Timestamp: View {
        let date: Date
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @Environment(\.chatPreview) private var preview
        @Environment(\.timeZone) private var timeZone

        var body: some View {
            Text(label)
                .font(.caption2)
                .foregroundStyle(theme.muted)
        }

        private var label: String {
            var calendar = Calendar.current
            calendar.locale = locale
            calendar.timeZone = timeZone
            let now = preview.now ?? .now
            var style =
                calendar.isDate(date, inSameDayAs: now)
                ? Date.FormatStyle(date: .omitted, time: .shortened) : Date.FormatStyle().weekday(.abbreviated).hour().minute()
            style.timeZone = timeZone
            style.locale = locale
            return date.formatted(style)
        }
    }
#endif
