#if canImport(UIKit)
    import SwiftUI
    import PhotosUI
    import UIKit
    import PingFrontCore

    /// One capsule: a "+" photo button inside its leading edge, the field, and a round send button that
    /// fills with the accent once there is something to send.
    ///
    /// Says why sending is off instead of failing.
    struct ComposerView: View {
        let pingFront: PingFront
        /// The field gained or lost focus (the keyboard is up or down).
        var onFocusChange: (Bool) -> Void = { _ in }
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @Environment(\.chatPreview) private var preview
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @Environment(\.verticalSizeClass) private var verticalSizeClass
        @Environment(\.composerRoom) private var room
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var pickerItems: [PhotosPickerItem] = []
        @State private var showsPicker = false
        @State private var staged: [StagedPhoto] = []
        @State private var showsCamera = false
        /// Whether the pasteboard holds a photo.
        ///
        /// The + menu's items are built from state, not read when the menu
        /// opens, so this is refreshed when the pasteboard changes here and when the app comes back (a photo
        /// copied in another app).
        @State private var pasteboardHasImages = UIPasteboard.general.hasImages
        @State private var sentCount = 0
        /// The field's one-line height at the current text size (measured; the + sits on the last line).
        @State private var lineHeight = ComposerMetrics.plusDiameter
        @State private var focused = false
        #if DEBUG
            @Environment(\.composerProbe) private var probe
        #endif

        private var conversation: Conversation { pingFront.conversation }
        #if DEBUG
            private var debugProbe: DebugProbe { probe }
        #else
            private var debugProbe: DebugProbe { nil }
        #endif

        /// The picked bytes (sent as is, after preparation) and a small thumbnail: the original is never
        /// also kept decoded.
        private struct StagedPhoto: Identifiable {
            static let thumbnailPixels = 240
            let id = UUID()
            let data: Data
            let image: UIImage
        }

        /// The most lines the field shows before it scrolls.
        ///
        /// As many as fit in the room above the keyboard, at least one (five, three at accessibility sizes, until the
        /// room is measured). The measured room wins: on a short screen in landscape at the largest sizes, a fixed
        /// minimum pushed the composer under the keyboard.
        private var maxLines: Int {
            guard let room else { return dynamicTypeSize.isAccessibilitySize ? 3 : 5 }
            // One line of text: the one-line field without its insets. The rest is the composer around the field.
            let line = max(lineHeight - 2 * ComposerMetrics.fieldVerticalInset, 1)
            let chrome = Self.topPadding + Self.bottomPadding + 2 * ComposerMetrics.fieldVerticalInset
            return max(1, Int(((room - chrome) / line).rounded(.down)))
        }

        /// The composer's own padding above and below the field.
        private static let topPadding: CGFloat = 6
        private static let bottomPadding: CGFloat = 8

        private var canSend: Bool {
            (!conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty)
                && TextLimit.remaining(conversation.draft) >= 0
                && conversation.cooldownRemaining(.messages) == nil
                && pingFront.configurationProblem?.disablesSDK != true
        }

        var body: some View {
            let t = L10n(locale)
            VStack(alignment: .leading, spacing: 8) {
                if let notice = policyNotice(t) {
                    // Its full height, always: at the largest sizes the bar never cuts the notice short.
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityElement(children: .combine)
                } else {
                    cooldownLines(t)
                    if !staged.isEmpty { stagedRow(t) }
                    field(t)
                    lengthCounter(t)
                }
            }
            .padding(.leading, ComposerMetrics.leadingPadding(theme))
            .padding(.trailing, theme.gutter)
            .padding(.top, Self.topPadding)
            .padding(.bottom, Self.bottomPadding)
            .barBackground()
            // The chat lets its header give way while the person types in a short window.
            .onChange(of: focused, initial: true) { onFocusChange(focused) }
            // Opening the chat while this one is embedded on screen focuses it instead of presenting a second chat.
            .onChange(of: conversation.composerFocusRequest) { focused = true }
            .task(id: pickerItems) { await loadPicked() }
            // iPad: drop photos from other apps onto the composer.
            .dropDestination(for: Data.self) { items, _ in
                guard canAddPhotos else { return false }
                return stage(items) > 0
            }
            .fullScreenCover(isPresented: $showsCamera) {
                CameraPicker { data in _ = stage([data]) }.ignoresSafeArea()
            }
            .onAppear {
                if staged.isEmpty, !preview.stagedPhotos.isEmpty {
                    staged = preview.stagedPhotos.compactMap { data in
                        ImageStore.downsample(data, maxPixelSize: StagedPhoto.thumbnailPixels).map { StagedPhoto(data: data, image: $0) }
                    }
                }
                if let draft = preview.draft { conversation.draft = draft }
                applyInsertion()
            }
            .onChange(of: conversation.composerInsertion) { _, _ in applyInsertion() }
            .task {
                for await _ in NotificationCenter.default.notifications(named: UIPasteboard.changedNotification) {
                    pasteboardHasImages = UIPasteboard.general.hasImages
                }
            }
            .task {
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                    pasteboardHasImages = UIPasteboard.general.hasImages
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
        }

        // MARK: Pieces

        /// Near the limit, a live count; over it, how much to cut (sending stays off).
        ///
        /// Nothing is truncated.
        @ViewBuilder
        private func lengthCounter(_ t: L10n) -> some View {
            let remaining = TextLimit.remaining(conversation.draft)
            if remaining < TextLimit.counterThreshold {
                Text(remaining >= 0 ? t("%lld characters left", remaining) : t("%lld characters over the limit", -remaining))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(remaining >= 0 ? theme.muted : theme.stop)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }

        @ViewBuilder
        private func field(_ t: L10n) -> some View {
            // Like Messages: the + circle is as tall as the one-line field and shares its center; when the field
            // grows, the + stays on its last line.
            HStack(alignment: .composerLine, spacing: ComposerMetrics.spacing(theme)) {
                plusButton(t)
                let capsule = HStack(alignment: .bottom, spacing: 0) {
                    // Like Messages: grows until the composer reaches the header (the thread scrolls out of view
                    // under it), then scrolls inside; Paste in its own menu takes a copied photo; a hardware
                    // keyboard's Return sends and Shift-Return adds a line.
                    ComposerField(
                        text: Binding(get: { conversation.draft }, set: { conversation.draft = $0 }),
                        isFocused: $focused,
                        placeholder: t.text(pingFront.look.composerPlaceholder) ?? t("Message"),
                        maxLines: maxLines,
                        canPastePhotos: canAddPhotos,
                        accessibilityLabel: t("Message"),
                        accessibilityHint: t("Return on a keyboard sends; Shift-Return adds a line."),
                        onReturn: {
                            guard canSend else { return false }
                            send()
                            return true
                        },
                        onPastePhotos: { stage($0) }
                    )
                    .padding(.leading, 14)
                    .padding(.trailing, canSend ? 4 : 14)
                    .padding(.vertical, ComposerMetrics.fieldVerticalInset)
                    .frame(minHeight: ComposerMetrics.plusDiameter)
                    if canSend {
                        sendButton(t)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72), value: canSend)
                // The same field with one line in it, hidden: the height the field has on one line.
                .background(alignment: .bottom) {
                    TextField(String(), text: .constant("M"), axis: .vertical)
                        .lineLimit(1...5)
                        .font(.body)
                        .disabled(true)
                        .accessibilityHidden(true)
                        .padding(.vertical, ComposerMetrics.fieldVerticalInset)
                        .frame(minHeight: ComposerMetrics.plusDiameter)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(dynamicTypeSize)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            lineHeight = $0
                        }
                }
                .alignmentGuide(.composerLine) { [lineHeight] in $0.height - lineHeight / 2 }
                let shape = RoundedRectangle(cornerRadius: ComposerMetrics.plusDiameter / 2, style: .continuous)
                Group {
                    // Reduce Transparency: an opaque field, as before Liquid Glass. Increase Contrast: a visible edge.
                    if #available(iOS 26, *), !reduceTransparency {
                        capsule.glassEffect(.regular.interactive(), in: shape)
                            .overlay {
                                if contrast == .increased { shape.strokeBorder(theme.muted, lineWidth: 1) }
                            }
                    } else {
                        capsule
                            .background(theme.background, in: shape)
                            .overlay(shape.strokeBorder(contrast == .increased ? theme.muted : theme.rule, lineWidth: 1))
                    }
                }
                .probed("field", probe: debugProbe)
                // Short on height (a phone in landscape), one line of the largest text sizes with the field's insets
                // is taller than the room the keyboard leaves on a small phone: the field's text stops growing at the
                // first accessibility size there, so it keeps a whole line. Only the field: the notices and the
                // counter keep the person's size.
                // https://developer.apple.com/documentation/swiftui/view/dynamictypesize(_:)
                .dynamicTypeSize(verticalSizeClass == .compact ? ...DynamicTypeSize.accessibility1 : ...DynamicTypeSize.accessibility5)
            }
            .disabled(pingFront.configurationProblem?.disablesSDK == true)
        }

        /// Whether another photo can be added now (photos on, not paused, under the limit).
        private var canAddPhotos: Bool {
            pingFront.look.allowsPhotos && conversation.cooldownRemaining(.uploads) == nil && staged.count < Limits.imagesPerMessage
        }

        /// "+": photo library, camera, a copied photo, and bug reports, each when available.
        @ViewBuilder
        private func plusButton(_ t: L10n) -> some View {
            let photos = pingFront.look.allowsPhotos
            let reports = pingFront.look.allowsReports
            let label = PlusGlyph(color: theme.text.opacity(0.7), fill: theme.teamBubble, probe: debugProbe)
            if photos || reports {
                // A PhotosPicker inside a Menu never presents; the menu item sets state and the picker is
                // attached outside the menu.
                Menu {
                    if photos {
                        Button {
                            showsPicker = true
                        } label: {
                            Label(t("Photos"), systemImage: "photo.on.rectangle")
                        }
                        .disabled(!canAddPhotos)
                        if CameraPicker.isAvailable {
                            Button {
                                showsCamera = true
                            } label: {
                                Label(t("Camera"), systemImage: "camera")
                            }
                            .disabled(!canAddPhotos)
                        }
                        if pasteboardHasImages {
                            Button {
                                _ = stage(UIPasteboard.general.images?.compactMap { $0.jpegData(compressionQuality: 0.9) } ?? [])
                            } label: {
                                Label(t("Paste photo"), systemImage: "doc.on.clipboard")
                            }
                            .disabled(!canAddPhotos)
                        }
                    }
                    if reports {
                        Button {
                            pingFront.openReport()
                        } label: {
                            Label(t("Report a bug"), systemImage: "ladybug")
                        }
                    }
                } label: {
                    label
                }
                .accessibilityLabel(photos ? (reports ? t("Add photo or report a bug") : t("Add photo")) : t("Report a bug"))
                .accessibilityShowsLargeContentViewer {
                    Label(photos ? t("Add photo") : t("Report a bug"), systemImage: "plus")
                }
                .photosPicker(
                    isPresented: $showsPicker, selection: $pickerItems, maxSelectionCount: max(Limits.imagesPerMessage - staged.count, 1),
                    matching: .images, photoLibrary: .shared())
            }
        }

        private func sendButton(_ t: L10n) -> some View {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(theme.onAccent, theme.accent)
                    // As tall as one line, so the arrow is centered on the field's last line.
                    // At least 36 pt wide, and wider when the text size grows, so the arrow never leaves the field.
                    .frame(minWidth: 36, minHeight: lineHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(t("Send"))
        }

        private func stagedRow(_ t: L10n) -> some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(staged.enumerated()), id: \.element.id) { index, photo in
                        Image(uiImage: photo.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.rule.opacity(0.6), lineWidth: 0.5)
                            )
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    staged.removeAll { $0.id == photo.id }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.heavy))
                                        .foregroundStyle(theme.onStrong)
                                        .frame(width: 22, height: 22)
                                        .background(theme.scrim, in: Circle())
                                        .overlay(Circle().strokeBorder(theme.onStrong, lineWidth: 1.5))
                                        .frame(width: 44, height: 44, alignment: .topTrailing)
                                }
                                .buttonStyle(.plain)
                                .offset(x: 8, y: -8)
                                .accessibilityLabel(t("Remove photo %lld", index + 1))
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(t("Photo"))
                    }
                }
                .padding(.top, 8)
                .padding(.leading, ComposerMetrics.fieldLeading(theme))
            }
        }

        @ViewBuilder
        private func cooldownLines(_ t: L10n) -> some View {
            if !conversation.cooldownDeadlines.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 4) {
                        if let left = conversation.cooldownRemaining(.messages) {
                            line(
                                Cooldowns.countdown(left).map { t("You can send again in %@.", $0) }
                                    ?? t("Sending is paused for a while. Try again later."))
                        }
                        if let left = conversation.cooldownRemaining(.uploads) {
                            line(
                                Cooldowns.countdown(left).map { t("Photos can be sent again in %@. Text still sends.", $0) }
                                    ?? t("Photos are paused for a while. Text still sends."))
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }

        private func line(_ text: String) -> some View {
            Label(text, systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(theme.muted)
                .monospacedDigit()
        }

        private func policyNotice(_ t: L10n) -> String? {
            guard !conversation.policy.canSend else { return nil }
            return switch conversation.policy.reason {
            case .blocked?: t("You can't send messages in this chat.")
            case .appPaused?: t("This chat is paused for now.")
            case .verificationRequired?: t("Sign in to the app to message the team.")
            default: t("You can't send messages in this chat.")
            }
        }

        // MARK: Actions

        private func send() {
            conversation.send(text: conversation.draft, photos: staged.map(\.data))
            staged = []
            sentCount += 1
        }

        private func applyInsertion() {
            guard let insertion = conversation.composerInsertion else { return }
            conversation.composerInsertion = nil
            // A topic's starter never replaces what the person already typed.
            conversation.draft = Conversation.inserting(insertion, into: conversation.draft)
            focused = true
        }

        /// Stages photo data (picker, camera, paste, drop) up to the per-message limit; returns how many.
        @discardableResult
        private func stage(_ items: [Data]) -> Int {
            var added = 0
            for data in items where staged.count < Limits.imagesPerMessage {
                guard let image = ImageStore.downsample(data, maxPixelSize: StagedPhoto.thumbnailPixels) else { continue }
                staged.append(StagedPhoto(data: data, image: image))
                added += 1
            }
            return added
        }

        private func loadPicked() async {
            guard !pickerItems.isEmpty else { return }
            let items = pickerItems
            pickerItems = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                stage([data])
            }
        }
    }

    /// The system camera, when the device has one and the app declares `NSCameraUsageDescription`.
    struct CameraPicker: UIViewControllerRepresentable {
        let onPhoto: (Data) -> Void
        @Environment(\.dismiss) private var dismiss

        static var isAvailable: Bool {
            UIImagePickerController.isSourceTypeAvailable(.camera)
                && Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
        }

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(onPhoto: onPhoto, dismiss: { dismiss() }) }

        final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            let onPhoto: (Data) -> Void
            let dismiss: () -> Void

            init(onPhoto: @escaping (Data) -> Void, dismiss: @escaping () -> Void) {
                self.onPhoto = onPhoto
                self.dismiss = dismiss
            }

            func imagePickerController(
                _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) { onPhoto(data) }
                dismiss()
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
        }
    }

    /// The "+" glyph in a glass circle.
    ///
    /// Nonisolated so the photo picker's label closure can build it.
    nonisolated struct PlusGlyph: View {
        let color: Color
        let fill: Color
        var probe: DebugProbe = nil

        var body: some View {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                // Like Messages, the + keeps its size at larger text sizes (the circle does too); the large
                // content viewer shows it big on a long press.
                .dynamicTypeSize(...DynamicTypeSize.large)
                .foregroundStyle(color)
                .frame(width: ComposerMetrics.plusDiameter, height: ComposerMetrics.plusDiameter)
                .glassCircle(fallback: fill)
                .probed("plus", probe: probe)
                .frame(width: ComposerMetrics.plusTarget, height: ComposerMetrics.plusTarget)
                .contentShape(Circle())
        }
    }

    #if DEBUG
        typealias DebugProbe = ComposerProbe?
    #else
        typealias DebugProbe = Void?
    #endif

    extension View {
        /// Debug builds with a probe: reports this view's frame in window coordinates.
        @ViewBuilder
        func probed(_ part: String, probe: DebugProbe) -> some View {
            #if DEBUG
                if let probe {
                    onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        probe.report(part, $0)
                    }
                } else {
                    self
                }
            #else
                self
            #endif
        }
    }

    /// The empty state, like opening a new Messages thread with a real person: a large centered face
    /// (or the team, or the app icon), the name, the reply expectation, and topic capsules.
    struct WelcomeView: View {
        let pingFront: PingFront
        @Environment(\.chatTheme) private var theme
        @Environment(\.locale) private var locale
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @Environment(\.verticalSizeClass) private var verticalSizeClass
        #if DEBUG
            @Environment(\.composerProbe) private var probe
            private var debugProbe: DebugProbe { probe }
        #else
            private var debugProbe: DebugProbe { nil }
        #endif

        private var look: ResolvedLook { pingFront.look }
        private var team: [TeamMember] { pingFront.conversation.team.isEmpty ? look.team : pingFront.conversation.team }
        private var member: TeamMember? { look.headerMemberId.flatMap { id in team.first { $0.id == id } } ?? team.first }

        /// The Free plan's line: the lockup's in-app size, 14 pt, as `brand/logo/source/inapp.mjs` draws it.
        private static let brandingSize: CGFloat = 14

        /// The opacity that keeps the line a footnote in either appearance.
        private static let brandingOpacity: Double = 0.65
        private static let brandingTop: CGFloat = 16
        private static let brandingBottom: CGFloat = 6
        /// The gap between the fold and the words above it or the buttons below it.
        private static let foldClearance: CGFloat = 16

        var body: some View {
            let t = L10n(locale)
            let branding = look.showsBranding
            GeometryReader { geometry in
                // Propped like a laptop, a fold runs across the welcome: the words stay above it and the topic
                // buttons move below it, onto the part that rests on the table (see `WelcomeFold`).
                let fold = WelcomeFold.across(size: geometry.size, folds: Folds.active(in: geometry))
                let showsTopics = !look.topics.isEmpty && canSend
                // Short on height (an iPhone, folded or not, in landscape): the words and the topics side by side,
                // so the topics are on screen without scrolling. The same views either way (`AnyLayout`).
                let sideBySide = verticalSizeClass == .compact && showsTopics && fold == nil
                let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 32)) : AnyLayout(VStackLayout(spacing: 0))
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            // At accessibility sizes or short on height, notices scroll with the welcome (`BannerStack`).
                            if BannerStack.movesIntoThread(dynamicTypeSize, verticalSizeClass) { BannerStack(pingFront: pingFront) }
                            layout {
                                VStack(spacing: 0) {
                                    if look.showsWelcomeFaces {
                                        Group {
                                            switch look.headerStyle {
                                            case .app: AppIconView(look: look, size: 88)
                                            case .team: FacesStack(members: Array(team.prefix(3)), size: 76)
                                            case .person:
                                                // No team yet (a first open while offline): the app's icon, not a teammate's initial (`AppIconView`).
                                                if let member {
                                                    AvatarView(name: member.name, url: member.avatarURL, size: 96, ring: false)
                                                } else {
                                                    AppIconView(look: look, size: 88)
                                                }
                                            }
                                        }
                                        .padding(.bottom, 14)
                                    }
                                    Text(title(t))
                                        .font(.title2.weight(.semibold))
                                        .fontDesign(theme.displayDesign)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityAddTraits(.isHeader)
                                    if let subtitle = subtitle(t) {
                                        Text(subtitle)
                                            .font(.subheadline)
                                            .foregroundStyle(theme.muted)
                                            .multilineTextAlignment(.center)
                                            .padding(.top, 3)
                                    }
                                    // While the person can't send (the notice in the composer's place says why), the
                                    // welcome does not invite them to write: no body, no reply expectation, no topics.
                                    if canSend {
                                        Text(
                                            t.text(look.welcomeBody)
                                                ?? t(
                                                    "Questions, bugs or ideas: the people who make %@ read every message and reply here.",
                                                    look.appName)
                                        )
                                        .font(.subheadline)
                                        .foregroundStyle(theme.muted)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: 320)
                                        .padding(.top, 10)
                                    }
                                }
                                // Folded: the words end just above the fold (nil leaves the stack as it was).
                                .frame(minHeight: fold.map { max($0.top - Self.foldClearance, 0) }, alignment: .bottom)
                                if showsTopics {
                                    FlowLayout(spacing: 8, centered: true) {
                                        ForEach(look.topics) { topic in
                                            Button {
                                                choose(topic, t)
                                            } label: {
                                                Label {
                                                    Text(t.label(topic))
                                                } icon: {
                                                    Image(systemName: topic.symbol.systemImage).foregroundStyle(theme.accentText)
                                                }
                                            }
                                            .buttonStyle(TopicCapsuleStyle())
                                        }
                                    }
                                    .frame(maxWidth: 420)
                                    .probed("topics", probe: debugProbe)
                                    // Folded: the buttons start just below the fold.
                                    .padding(.top, sideBySide ? 0 : fold.map { $0.bottom - $0.top + 2 * Self.foldClearance } ?? 24)
                                }
                            }
                            .padding(.horizontal, 24)
                            .frame(maxWidth: .infinity)
                            // Centered at normal sizes; at accessibility sizes, or split by a fold, it starts at the top
                            // and scrolls, so nothing runs under the composer.
                            .frame(
                                minHeight: dynamicTypeSize.isAccessibilitySize || fold != nil
                                    ? 0
                                    : (geometry.size.height - Self.brandingHeight(branding)) * 0.86,
                                alignment: fold == nil ? .center : .top
                            )
                        }
                    }
                    .defaultScrollAnchor(.top)
                    // Text leaving the welcome fades out at the header and composer, as in the thread, so at
                    // accessibility sizes no word sits under the composer's placeholder (audit I-01).
                    .edgeFade()
                    // On pingfront's Free plan (`features.branding`): the brand's own one-colour lockup on its own
                    // bar above the composer, in the chat's muted colour. It never scrolls with the welcome,
                    // never carries pink into a look that may not match, and never appears in a conversation.
                    if branding {
                        Image("PingFrontLockup", bundle: .module)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(height: Self.brandingSize)
                            .opacity(Self.brandingOpacity)
                            .foregroundStyle(theme.muted)
                            .accessibilityLabel(Text(t("Chat by pingfront")))
                            .padding(.top, Self.brandingTop)
                            .padding(.bottom, Self.brandingBottom)
                    }
                }
            }
        }

        /// The room the line takes at the bottom of the welcome, so the content stays centered in what is left.
        private static func brandingHeight(_ branding: Bool) -> CGFloat {
            branding ? brandingSize + brandingTop + brandingBottom : 0
        }

        private func title(_ t: L10n) -> String {
            if let custom = t.text(look.welcomeTitle) { return custom }
            switch look.headerStyle {
            case .person: return member?.name ?? look.appName
            case .team: return t.text(look.headerTitle) ?? t("The %@ team", look.appName)
            case .app: return t.text(look.headerTitle) ?? look.appName
            }
        }

        /// Whether the person can send now.
        private var canSend: Bool { pingFront.conversation.policy.canSend }

        private func subtitle(_ t: L10n) -> String? {
            let expectation = HeaderStatus.expectation(
                t.replyExpectation(pingFront), shown: look.showsReplyExpectation,
                policy: pingFront.conversation.policy)
            if look.headerStyle == .person, let role = member?.role, t.text(look.welcomeTitle) == nil {
                return [role, expectation].compactMap(\.self).joined(separator: "\n")
            }
            return expectation
        }

        /// A topic opens its flow or fills the composer; it never sends anything by itself.
        private func choose(_ topic: ChatTopic, _ t: L10n) {
            switch TopicAction.resolve(id: topic.id, prefill: t.text(topic.prefill), label: t.label(topic), translate: { t($0) }) {
            case .openReport: pingFront.openReport()
            case .compose(let text): pingFront.conversation.composerInsertion = text
            }
        }
    }

    /// A topic capsule: system gray fill, tinted symbol, 44 pt tall.
    struct TopicCapsuleStyle: ButtonStyle {
        @Environment(\.chatTheme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: ButtonStyleConfiguration) -> some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(theme.teamBubble.opacity(configuration.isPressed ? 0.6 : 1), in: Capsule())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
                .contentShape(Capsule())
        }
    }
#endif
