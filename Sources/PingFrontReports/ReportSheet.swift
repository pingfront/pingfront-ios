#if canImport(UIKit)
    import SwiftUI
    import UIKit
    import PingFrontCore
    import PingFrontUI

    /// The bug report: what went wrong, the screenshot with freehand markup, and a note on what is attached.
    struct ReportSheet: View {
        let pingFront: PingFront
        let screenshot: UIImage?
        /// Where the screenshot comes from, said in its toggle.
        enum ScreenshotCaption { case current, beforeChat }
        @State var prefill: String
        /// Marks to show on first appearance, in unit coordinates of the screenshot (captures only).
        var initialMarks: [[CGPoint]] = []
        var screenshotCaption: ScreenshotCaption = .current
        @Environment(\.dismiss) private var dismiss
        @Environment(\.locale) private var locale
        /// Marks in unit coordinates of the screenshot (0...1), so they stay on the same spot when the sheet
        /// resizes (rotating, folding or unfolding the device, Split View).
        @State private var strokes: [[CGPoint]] = []
        @State private var current: [CGPoint] = []
        @State private var includeScreenshot = true
        @State private var submission: UUID?
        @State private var failed = false
        @State private var canvasSize: CGSize = .zero

        var body: some View {
            let t = L10n(locale)
            NavigationStack {
                Form {
                    Section(t("What went wrong?")) {
                        TextField(t("For example: the 06:30 alarm didn't ring"), text: $prefill, axis: .vertical)
                            .lineLimit(3...10)
                    }
                    if let screenshot {
                        Section {
                            Toggle(
                                screenshotCaption == .beforeChat
                                    ? t("Include the screen before you opened the chat") : t("Include screenshot"),
                                isOn: $includeScreenshot)
                            if includeScreenshot {
                                markup(screenshot)
                                if !strokes.isEmpty {
                                    Button(t("Clear marks")) { strokes = [] }
                                }
                            }
                        } footer: {
                            Text(t("Draw on the screenshot to point at the problem. Recent logs and device state are attached."))
                        }
                    }
                    if failed {
                        Text(t("Not sent.")).foregroundStyle(.red)
                    }
                }
                .navigationTitle(t("Report a bug"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { CancelButton(title: t("Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        SendButton(title: t("Send report")) { submission = UUID() }
                            .disabled(prefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submission != nil)
                    }
                }
                .task(id: submission) {
                    guard submission != nil else { return }
                    let image = includeScreenshot ? composite() : nil
                    do {
                        try await pingFront.reportBug(text: prefill, screenshot: image?.jpegData(compressionQuality: 0.9))
                        dismiss()
                    } catch {
                        failed = true
                    }
                    submission = nil
                }
            }
            .tint(pingFront.look.accent.dynamicColor)
            .sensoryFeedback(.success, trigger: submission == nil && !failed && !prefill.isEmpty)
        }

        /// The screenshot at its own aspect ratio, centered in its row, with the marks drawn over exactly the image.
        private func markup(_ image: UIImage) -> some View {
            let aspect = image.size.height > 0 ? image.size.width / image.size.height : 0.46
            return Image(uiImage: image)
                .resizable()
                .aspectRatio(aspect, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        Canvas { context, size in
                            for stroke in strokes + [current] where stroke.count > 1 {
                                var path = Path()
                                path.addLines(Markup.points(stroke, in: size))
                                context.stroke(
                                    path, with: .color(Color(red: 0.76, green: 0.21, blue: 0.18)),
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { current.append(Markup.unit($0.location, in: proxy.size)) }
                                .onEnded { _ in
                                    strokes.append(current)
                                    current = []
                                }
                        )
                        .onAppear {
                            canvasSize = proxy.size
                            if strokes.isEmpty, !initialMarks.isEmpty { strokes = initialMarks }
                        }
                        .onChange(of: proxy.size) { _, size in canvasSize = size }
                    }
                }
                // A screenshot reads as a small screen: continuous corners and a hairline edge, like Markup.
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5)
                }
                .frame(maxHeight: 440)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityLabel(L10n(locale)("Screenshot"))
        }

        /// The screenshot with the marks drawn at full resolution.
        private func composite() -> UIImage? {
            guard let screenshot else { return nil }
            guard !strokes.isEmpty, canvasSize.width > 0 else { return screenshot }
            // The line keeps the width it had on screen.
            let scale = screenshot.size.width / canvasSize.width
            let renderer = UIGraphicsImageRenderer(size: screenshot.size)
            return renderer.image { context in
                screenshot.draw(at: .zero)
                let cg = context.cgContext
                cg.setStrokeColor(UIColor(red: 0.76, green: 0.21, blue: 0.18, alpha: 1).cgColor)
                cg.setLineWidth(4 * scale)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                for stroke in strokes where stroke.count > 1 {
                    cg.addLines(between: Markup.points(stroke, in: screenshot.size))
                    cg.strokePath()
                }
            }
        }
    }

    /// Converts marks between the screenshot's unit square and a size in points or pixels.
    nonisolated enum Markup {
        static func unit(_ point: CGPoint, in size: CGSize) -> CGPoint {
            guard size.width > 0, size.height > 0 else { return .zero }
            return CGPoint(x: point.x / size.width, y: point.y / size.height)
        }

        static func points(_ stroke: [CGPoint], in size: CGSize) -> [CGPoint] {
            stroke.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        }
    }

    /// Cancel: the system close button (an x in glass) on iOS 26, the word on earlier versions.
    private struct CancelButton: View {
        let title: String
        let action: () -> Void

        var body: some View {
            if #available(iOS 26, *) {
                Button(role: .close, action: action).accessibilityLabel(title)
            } else {
                Button(title, action: action)
            }
        }
    }

    /// Send: an arrow in prominent glass on iOS 26 (like Mail), so the inline title has room to stay centered;
    /// the words on earlier versions.
    private struct SendButton: View {
        let title: String
        let action: () -> Void

        var body: some View {
            if #available(iOS 26, *) {
                Button(action: action) {
                    Label(title, systemImage: "arrow.up").labelStyle(.iconOnly)
                }
                .buttonStyle(.glassProminent)
                .accessibilityLabel(title)
            } else {
                Button(title, action: action).fontWeight(.semibold)
            }
        }
    }
#endif
