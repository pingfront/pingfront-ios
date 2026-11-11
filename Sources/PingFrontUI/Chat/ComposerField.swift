#if canImport(UIKit)
    import SwiftUI
    import UIKit

    /// The composer's text field: a UIKit text view, like Messages'.
    ///
    /// Paste in its own edit menu (and Command-V) takes a copied photo with no prompt; SwiftUI's `TextField` can't
    /// accept a pasted image.
    ///
    /// It grows a line at a time up to `maxLines`, then scrolls inside. A hardware keyboard's Return sends; Shift-Return
    /// adds a line (the on-screen keyboard's return key always adds a line).
    struct ComposerField: UIViewRepresentable {
        @Binding var text: String
        @Binding var isFocused: Bool
        let placeholder: String
        let maxLines: Int
        let canPastePhotos: Bool
        let accessibilityLabel: String
        let accessibilityHint: String
        let onReturn: () -> Bool
        let onPastePhotos: ([Data]) -> Void

        @Environment(\.chatTheme) private var theme
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @Environment(\.layoutDirection) private var layoutDirection
        @Environment(\.colorScheme) private var colorScheme

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> PastingTextView {
            let view = PastingTextView()
            view.delegate = context.coordinator
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.isScrollEnabled = false
            view.textAlignment = .natural
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultHigh, for: .vertical)
            return view
        }

        func updateUIView(_ view: PastingTextView, context: Context) {
            context.coordinator.parent = self
            let font = Self.font(size: dynamicTypeSize, design: theme.fontDesign)
            if view.font != font { view.font = font }
            view.textColor = UIColor(theme.text)
            view.tintColor = UIColor(theme.accent)
            view.semanticContentAttribute = layoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
            // The keyboard follows the chat's scheme. Left to the default, it came back dark in a light chat after the
            // app returned from the background with a photo on the pasteboard.
            let appearance: UIKeyboardAppearance = colorScheme == .dark ? .dark : .light
            if view.keyboardAppearance != appearance {
                view.keyboardAppearance = appearance
                if view.isFirstResponder { view.reloadInputViews() }
            }
            // Never while the person composes with a marked (IME) text: that would cancel it.
            if view.text != text, view.markedTextRange == nil { view.text = text }
            view.placeholder = placeholder
            view.canPastePhotos = canPastePhotos
            view.onReturn = onReturn
            view.onPastePhotos = onPastePhotos
            view.accessibilityLabel = accessibilityLabel
            view.accessibilityHint = accessibilityHint
            view.wantsFocus = isFocused
            if isFocused, !view.isFirstResponder, view.window != nil { view.becomeFirstResponder() }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PastingTextView, context: Context) -> CGSize? {
            let width = max(proposal.width ?? 200, 1)
            let font = view.font ?? Self.font(size: dynamicTypeSize, design: theme.fontDesign)
            var content = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            if view.text.isEmpty, !placeholder.isEmpty {
                content = max(content, Self.placeholderHeight(placeholder, font: font, width: width))
            }
            let line = font.lineHeight
            let most = (line * CGFloat(max(maxLines, 1))).rounded(.up)
            let height = min(max(content, line.rounded(.up)), most)
            let scrolls = content > most + 0.5
            if view.isScrollEnabled != scrolls { view.isScrollEnabled = scrolls }
            return CGSize(width: width, height: height)
        }

        /// The height the placeholder takes, wrapped to `width`.
        static func placeholderHeight(_ placeholder: String, font: UIFont, width: CGFloat) -> CGFloat {
            (placeholder as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil
            ).height.rounded(.up)
        }

        /// The body text style at the chat's text size and font design.
        static func font(size: DynamicTypeSize, design: Font.Design?) -> UIFont {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
            let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            let system: UIFontDescriptor.SystemDesign? =
                switch design {
                case .rounded?: .rounded
                case .serif?: .serif
                case .monospaced?: .monospaced
                default: nil
                }
            guard let system, let descriptor = body.fontDescriptor.withDesign(system) else { return body }
            return UIFont(descriptor: descriptor, size: body.pointSize)
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: ComposerField

            init(_ parent: ComposerField) { self.parent = parent }

            func textViewDidChange(_ textView: UITextView) {
                if parent.text != textView.text { parent.text = textView.text }
                (textView as? PastingTextView)?.setNeedsDisplay()
            }

            func textViewDidBeginEditing(_ textView: UITextView) { if !parent.isFocused { parent.isFocused = true } }

            func textViewDidEndEditing(_ textView: UITextView) { if parent.isFocused { parent.isFocused = false } }
        }
    }

    /// A text view that pastes photos, sends on a hardware Return and draws its own placeholder.
    final class PastingTextView: UITextView {
        var placeholder = "" { didSet { if placeholder != oldValue { setNeedsDisplay() } } }
        var canPastePhotos = false
        var onReturn: () -> Bool = { false }
        var onPastePhotos: ([Data]) -> Void = { _ in }
        /// Focus asked for before the view was in a window: taken when it arrives.
        var wantsFocus = false

        // swift-format-ignore: NeverUseImplicitlyUnwrappedOptionals
        // UITextView declares `text` this way; an override must match it.
        override var text: String! { didSet { setNeedsDisplay() } }
        override var font: UIFont? { didSet { setNeedsDisplay() } }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if wantsFocus, window != nil, !isFirstResponder { becomeFirstResponder() }
        }

        override func draw(_ rect: CGRect) {
            super.draw(rect)
            guard text.isEmpty, !placeholder.isEmpty, let font else { return }
            let style = NSMutableParagraphStyle()
            style.alignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
            // Wrapped, never truncated: at the largest text sizes a placeholder such as "Message Deniz" takes two
            // lines and the field grows to show them (`sizeThatFits`), as Dynamic Type asks of text.
            style.lineBreakMode = .byWordWrapping
            (placeholder as NSString).draw(
                in: bounds.inset(by: textContainerInset),
                withAttributes: [.font: font, .foregroundColor: UIColor.placeholderText, .paragraphStyle: style])
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if text.isEmpty { setNeedsDisplay() }
        }

        // MARK: Paste

        private var pasteboardHasOnlyPhotos: Bool {
            let board = UIPasteboard.general
            return board.hasImages && !board.hasStrings && !board.hasURLs
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), canPastePhotos, UIPasteboard.general.hasImages { return true }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            guard canPastePhotos, pasteboardHasOnlyPhotos else {
                super.paste(sender)
                return
            }
            // The person chose Paste, so reading the pasteboard asks no permission.
            let photos = UIPasteboard.general.images?.compactMap { $0.jpegData(compressionQuality: 0.9) } ?? []
            if !photos.isEmpty { onPastePhotos(photos) }
        }

        // MARK: Hardware keyboard

        override var keyCommands: [UIKeyCommand]? {
            let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(sendFromKeyboard))
            send.wantsPriorityOverSystemBehavior = true
            return (super.keyCommands ?? []) + [send]
        }

        @objc private func sendFromKeyboard() {
            // With nothing to send, Return adds a line as it would anyway.
            if !onReturn() { insertText("\n") }
        }
    }
#endif
