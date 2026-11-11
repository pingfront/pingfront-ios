#if canImport(UIKit) && DEBUG
    public import UIKit
    import SwiftUI
    @_spi(Fixtures) import PingFrontCore

    /// Renders the real SDK views into PNGs in a folder and writes `manifest.json` from the same list, so a
    /// gallery made from it never drifts from the code.
    ///
    /// Each view is hosted in a `UIWindow` at
    /// the device's point size with its safe-area insets, scheme, Dynamic Type size, layout direction and
    /// locale, and rendered at the device scale.
    ///
    /// Debug builds only. Called by a host app's snapshot test (real window scene, so `drawHierarchy` works)
    /// and by the package's host-less smoke test.
    @_spi(Snapshots)
    public final class SnapshotMatrix {
        struct Device {
            let slug: String
            let name: String
            let points: CGSize
            let scale: CGFloat
            let safeArea: UIEdgeInsets
            let idiom: UIUserInterfaceIdiom
            enum Presentation { case fullScreen, formSheet, splitDetail }
            let presentation: Presentation
        }

        static let iPhoneSE = Device(
            slug: "iphonese", name: "iPhone SE (3rd generation)", points: CGSize(width: 375, height: 667), scale: 2,
            safeArea: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0), idiom: .phone, presentation: .fullScreen)
        static let iPhone17 = Device(
            slug: "iphone17", name: "iPhone 17", points: CGSize(width: 402, height: 874), scale: 3,
            safeArea: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0), idiom: .phone, presentation: .fullScreen)
        static let iPhone17ProMax = Device(
            slug: "iphone17promax", name: "iPhone 17 Pro Max", points: CGSize(width: 440, height: 956), scale: 3,
            safeArea: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0), idiom: .phone, presentation: .fullScreen)
        static let iPadMini = Device(
            slug: "ipadmini", name: "iPad mini (form sheet)", points: CGSize(width: 744, height: 1133), scale: 2,
            safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0), idiom: .pad, presentation: .formSheet)
        static let iPadPro13 = Device(
            slug: "ipadpro13", name: "iPad Pro 13-inch (form sheet)", points: CGSize(width: 1032, height: 1376), scale: 2,
            safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0), idiom: .pad, presentation: .formSheet)
        static let iPadPro13Split = Device(
            slug: "ipadpro13-split", name: "iPad Pro 13-inch (split view detail)", points: CGSize(width: 1376, height: 1032), scale: 2,
            safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0), idiom: .pad, presentation: .splitDetail)

        struct Variant {
            var scheme: ColorScheme = .light
            var textSize: DynamicTypeSize = .large
            var locale = "en"
            var look = "default"
            /// Settings > Accessibility > Display & Text Size: Reduce Transparency.
            var reduceTransparency = false
            /// Settings > Accessibility > Display & Text Size: Increase Contrast.
            var increaseContrast = false
        }

        struct Entry: Encodable {
            let file: String
            let title: String
            let surface = "ios"
            let device: String
            let points: [Int]
            let scale: Int
            let scheme: String
            let textSize: String
            let locale: String
            let direction: String
            let state: String
            let look: String
            let notes: String
        }

        static let fixedNow = Fixtures.base.addingTimeInterval(20 * 60)
        /// `Snapshots` beside the package's `Sources`, found from this source file's location.
        public static var defaultDirectory: URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "Snapshots")
        }

        private var entries: [Entry] = []
        private let outputDirectory: URL
        private let scene: UIWindowScene?
        /// Renders that fell back to `layer.render` (no window scene).
        public private(set) var fallbackCount = 0

        private init(outputDirectory: URL, scene: UIWindowScene?) {
            self.outputDirectory = outputDirectory
            self.scene = scene
        }

        /// Renders every snapshot into `directory` and writes `manifest.json`.
        ///
        /// Returns the number of images.
        /// Pass the host app's window scene for pixel-exact renders.
        public static func render(to directory: URL = defaultDirectory, scene: UIWindowScene?) async throws -> (count: Int, fallbacks: Int)
        {
            let matrix = SnapshotMatrix(outputDirectory: directory, scene: scene)
            try await matrix.renderAll()
            return (matrix.entries.count, matrix.fallbackCount)
        }

        private func renderAll() async throws {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            // Replace the top-level images only; review/ and simulator/ subfolders stay.
            for file in (try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "png" || file.lastPathComponent == "manifest.json" {
                try? FileManager.default.removeItem(at: file)
            }
            FixtureImages.install()
            let base = Self.iPhone17

            // Base screens.
            try await shot(
                base, state: "welcome", title: "Welcome with topics",
                notes:
                    "Like opening a new Messages thread: a large centered face, the name, role and reply expectation, topic capsules the app chose, and the composer. The header shows only the close control here."
            )
            try await shot(
                base, state: "welcome-branding", title: "Welcome on the Free plan",
                notes:
                    "features.branding: our one-colour lockup, 14 pt and faded, on its own bar above the composer. It takes the chat's muted ink, so it follows the app's palette, and never appears inside a conversation.",
                configure: { pingFront in
                    pingFront.previewConfig?.features.branding = true
                    pingFront.refreshLook()
                    pingFront.look.showsBranding = true
                }
            )
            try await shot(
                base, variant: Variant(scheme: .dark), state: "welcome-branding", title: "Welcome on the Free plan, dark",
                notes:
                    "The same branding line in dark mode: the lockup follows the look's muted ink, so it stays quiet in either appearance.",
                configure: { pingFront in
                    pingFront.previewConfig?.features.branding = true
                    pingFront.refreshLook()
                    pingFront.look.showsBranding = true
                }
            )
            try await shot(
                base, state: "conversation", title: "Conversation",
                notes:
                    "The end of the thread: quick-reply capsules, a star rating, and a review card shaped like a rich link preview with one capsule button."
            )
            try await shot(
                base, state: "conversation-top", title: "Conversation, start of the thread",
                notes:
                    "Centered time, the pink ping line (tap for the reason), tailed bubbles with tight grouping, the AI name with its capsule and the hand-off, and a receipt.",
                preview: { preview in preview.scrolledToTop = true })
            try await shot(
                base, state: "conversation-middle", title: "Conversation, middle of the thread",
                notes: "Answered quick replies, a photo and a bubble from the person with Read under the last one, then a report card.",
                preview: { preview in preview.scrollTarget = "msg_7" })
            try await shot(
                base, variant: Variant(scheme: .dark), state: "conversation-top", title: "Conversation, start of the thread, dark",
                notes: "The pink ping line, the AI capsule, tailed bubbles and a receipt in dark mode.",
                preview: { preview in preview.scrolledToTop = true })

            // States on the base device.
            try await shot(
                base, state: "staged-photos", title: "Composer with two staged photos", fixture: .conversation, short: true,
                notes:
                    "Two photos staged above the field, each removable; the send arrow appears inside the field once there is something to send.",
                preview: { preview in
                    preview.stagedPhotos = [
                        FixtureImages.widgetScreenshot().jpegData(compressionQuality: 0.8) ?? Data(),
                        FixtureImages.appIcon().pngData() ?? Data(),
                    ]
                    preview.draft = "Both screens show the glitch"
                })
            try await shot(
                base, state: "sending-failed", title: "Sending and failed with inline retry", fixture: .conversation, short: true,
                notes: "One message sending; one not delivered, with the red marker, Retry and Delete, like Messages.",
                configure: { pingFront in
                    var sending = PendingMessage(
                        clientId: "c1", text: "Also, the timer skipped a second at midnight.", createdAt: Fixtures.at(19))
                    sending.state = .sending
                    var failed = PendingMessage(clientId: "c2", text: "Is there a family plan?", createdAt: Fixtures.at(19.5))
                    failed.state = .failed
                    failed.failure = "invalid_request"
                    pingFront.conversation.pending = [sending, failed]
                })
            try await shot(
                base, state: "offline-queued", title: "Offline with a queued message", fixture: .conversation, short: true,
                notes: "Offline banner; the queued message waits and sends when the connection returns.",
                configure: { pingFront in
                    var queued = PendingMessage(clientId: "c3", text: "Sending this from the train.", createdAt: Fixtures.at(19))
                    queued.attempts = 1
                    pingFront.conversation.pending = [queued]
                    pingFront.conversation.live = .waiting(retryIn: .seconds(4), offline: true)
                })
            try await shot(
                base, state: "rate-limited", title: "Rate-limited countdown", fixture: .conversation, short: true,
                notes: "Only uploads are paused (429 scope uploads); the countdown is exact under five minutes and text still sends.",
                configure: { pingFront in
                    pingFront.conversation.cooldownDeadlines = [.uploads: pingFront.conversation.time.now() + .milliseconds(41_600)]
                })
            try await shot(
                base, state: "blocked", title: "Blocked", fixture: .conversation, short: true,
                notes: "The composer is replaced by a plain line that says what is going on.",
                configure: { pingFront in
                    pingFront.conversation.policy = SendPolicy.closed(.blocked)
                })
            // Each hold says what it waits for, in every appearance, at the largest text size and right to left.
            for variant in [
                Variant(), Variant(scheme: .dark), Variant(textSize: .accessibility5), Variant(locale: "ar"),
                Variant(textSize: .accessibility5, locale: "ar"),
            ] {
                try await shot(
                    base, variant: variant, state: "paused-held", title: "Paused, with a held message", fixture: .conversation, short: true,
                    notes:
                        "The app is paused: the message it refused waits with a muted line and no red mark, and the one sent after it waits behind it (each sends by itself when the chat is back; Delete is in their context menus). The notice asks nothing of the person.",
                    configure: { pingFront in
                        var held = PendingMessage(clientId: "c4", text: "Is there a family plan?", createdAt: Fixtures.at(19.5))
                        held.state = .failed
                        held.failure = "app_paused"
                        held.heldFor = .appPaused
                        let behind = PendingMessage(clientId: "c6", text: "Or a student discount?", createdAt: Fixtures.at(19.6))
                        pingFront.conversation.pending = [held, behind]
                        pingFront.conversation.policy = SendPolicy.closed(.appPaused)
                    })
                try await shot(
                    base, variant: variant, state: "signin-held", title: "Sign-in required, with a held message", fixture: .conversation,
                    short: true,
                    notes:
                        "The app accepts messages only from people who signed in: the refused message says it sends after the person signs in, and the notice says where.",
                    configure: { pingFront in
                        var held = PendingMessage(clientId: "c7", text: "Is there a family plan?", createdAt: Fixtures.at(19.5))
                        held.state = .failed
                        held.failure = "verification_required"
                        held.heldFor = .verificationRequired
                        pingFront.conversation.pending = [held]
                        pingFront.conversation.policy = SendPolicy.closed(.verificationRequired)
                    })
            }
            try await shot(
                base, state: "blocked-failed", title: "Blocked, with a refused message", fixture: .conversation, short: true,
                notes:
                    "A message refused because the person is blocked is a plain failure: the red mark and Not delivered, with Delete only and no promise that it will send.",
                configure: { pingFront in
                    var failed = PendingMessage(clientId: "c5", text: "Is there a family plan?", createdAt: Fixtures.at(19.5))
                    failed.state = .failed
                    failed.failure = "blocked"
                    pingFront.conversation.pending = [failed]
                    pingFront.conversation.policy = SendPolicy.closed(.blocked)
                })
            try await shot(
                base, state: "blocked-welcome", title: "Blocked, before any message", fixture: .welcome, short: true,
                notes:
                    "Verification required before the first message: the welcome keeps the face and name but no longer invites a message (no body, reply time or topics); the notice replaces the composer.",
                configure: { pingFront in
                    pingFront.conversation.policy = SendPolicy.closed(.verificationRequired)
                })
            try await shot(
                base, state: "bad-key", title: "Bad key, debug banner", fixture: .welcome,
                notes:
                    "A mistyped key fails the offline checksum; debug builds show the exact problem in red. Release builds log and disable quietly.",
                configure: { pingFront in
                    pingFront.setPreviewProblem(
                        ConfigurationProblem(
                            kind: .invalidKey(.checksumMismatch), message: KeyProblem.checksumMismatch.message, disablesSDK: true))
                })
            // Notices at accessibility sizes: a row of the thread, never the bar, so the thread and the
            // composer keep the screen (audit 4, B1). On the narrowest phone and right to left too.
            let notices: [(String, String, @MainActor (PingFront) -> Void)] = [
                (
                    "unreachable", "can't reach the chat",
                    { pingFront in
                        pingFront.conversation.live = .waiting(retryIn: .seconds(4), offline: true)
                        pingFront.conversation.serverUnreachable = true
                    }
                ),
                ("offline", "offline", { pingFront in pingFront.conversation.live = .waiting(retryIn: .seconds(4), offline: true) }),
                (
                    "setup", "a setup problem",
                    { pingFront in
                        pingFront.setPreviewProblem(
                            ConfigurationProblem(
                                kind: .appPaused,
                                message: "This app is paused in the dashboard. Resume it in Dashboard > App > Settings.",
                                disablesSDK: false))
                    }
                ),
            ]
            for (slug, what, stage) in notices {
                for (device, variant) in [
                    (base, Variant(textSize: .accessibility5)), (Self.iPhoneSE, Variant(textSize: .accessibility5)),
                    (base, Variant(textSize: .accessibility5, locale: "ar")),
                ] {
                    try await shot(
                        device, variant: variant, state: "banner-\(slug)", title: "Notice at the largest text size: \(what)",
                        fixture: .conversation, short: true,
                        notes:
                            "At accessibility sizes the notice is the last row of the thread, in view where the thread opens, and scrolls with it; the header stays small and the composer keeps its room, with a draft in it.",
                        configure: stage,
                        preview: { preview in preview.draft = "Is the timer fixed yet?" })
                }
            }
            // A message sent while the service is unreachable, at accessibility sizes: it lands below the notice, in
            // view above the composer, with its own line (audit 5, B1a).
            for variant in [Variant(textSize: .accessibility5), Variant(textSize: .accessibility5, locale: "ar")] {
                try await shot(
                    base, variant: variant, state: "banner-unreachable-pending", title: "Can't reach the chat, a message waiting",
                    fixture: .conversation, short: true,
                    notes:
                        "The notice sits after what was delivered and before what waits to send, so the person's new message and its line are in view; if the notice scrolls away, the line still says what it says.",
                    configure: { pingFront in
                        pingFront.conversation.live = .waiting(retryIn: .seconds(4), offline: true)
                        pingFront.conversation.serverUnreachable = true
                        var waiting = PendingMessage(clientId: "c8", text: "Is the timer fixed yet?", createdAt: Fixtures.at(19.5))
                        waiting.attempts = 1
                        pingFront.conversation.pending = [waiting]
                    })
            }
            // The composer with a long draft: it grows to five lines (three at accessibility sizes), then scrolls.
            for variant in [Variant(), Variant(scheme: .dark), Variant(textSize: .accessibility5)] {
                try await shot(
                    base, variant: variant, state: "composer-long-draft", title: "Composer with a long draft",
                    fixture: .conversation, short: true,
                    notes: "Like Messages: the field grows with the draft up to its limit, then scrolls; the + stays on the last line.",
                    preview: { preview in
                        preview.draft =
                            "The alarm didn't ring this morning. I set it for 6:30, the volume was up, and Do Not Disturb was off. It worked yesterday. Is there anything I should check before tomorrow?"
                    })
            }
            try await shot(
                base, state: "draft-look", title: "Draft look on a test device", fixture: .conversation, short: true, draft: true,
                lookOverride: Fixtures.variantA, lookName: "variant-a-draft",
                notes: "A test device previews an unpublished look; the dashed Draft look marker sits in the header.")
            try await shot(
                base, state: "unknown-content", title: "Content from a newer server", fixture: .conversation, short: true,
                notes: "A message type this SDK version does not know renders as a quiet placeholder instead of crashing.",
                configure: { pingFront in
                    pingFront.conversation.messages.append(Fixtures.unknownMessage)
                })
            try await shot(
                base, state: "unknown-content-fallback", title: "Unknown content with server fallback text",
                fixture: .conversation, short: true,
                notes: "A newer message type with the server's plain-text fallback: shown as an ordinary bubble.",
                configure: { pingFront in
                    var message = Fixtures.unknownMessage
                    message.fallback = "Poll: which widget should we build next? Reply with a number."
                    pingFront.conversation.messages.append(message)
                })
            try await shot(
                base, state: "link-screen", title: "A saved link to a screen of the app", fixture: .conversation, short: true,
                notes:
                    "A link card for a screen this build registered opens in the app: no web host, no Opens in Safari (as on Android). A web link card keeps both.",
                configure: { pingFront in
                    pingFront.registerScreens([AppScreen(id: "settings.sound", title: "Sound settings")])
                    pingFront.conversation.messages += Fixtures.screenLinkMessages
                })
            try await shot(
                base, state: "links", title: "Links and a link preview", fixture: .conversation, short: true,
                notes:
                    "Links in text are tappable and open in an in-app Safari view; a link-only message gets a preview card (fetched on the device; offline here).",
                configure: { pingFront in
                    pingFront.conversation.messages += Fixtures.linkMessages
                })
            for scheme in [ColorScheme.light, .dark] {
                try await shot(
                    base, variant: Variant(scheme: scheme), state: "plan-payment-issue", title: "Plan status: payment issue",
                    fixture: .conversation, short: true,
                    notes:
                        "The plan line from the server's entitlement (grace): red, with the in-app Update payment method button that opens Apple's sheet; a newer offer waits for Ask to Buy approval.",
                    configure: { pingFront in
                        pingFront.setPreviewStoreActions()
                        pingFront.person = PersonSummary(
                            id: "p_ada", level: .guest,
                            entitlement: Entitlement(
                                state: .grace, productId: "pro_monthly", expiresAt: Self.fixedNow.addingTimeInterval(-86_400),
                                gracePeriodEndsAt: Self.fixedNow.addingTimeInterval(86_400 * 4), source: .storekit))
                        pingFront.conversation.messages += Fixtures.offerMessages
                        pingFront.markAwaitingApproval(cardId: "card_offer_new")
                    })
                try await shot(
                    base, variant: Variant(scheme: scheme), state: "plan-renews", title: "Plan status: renews",
                    fixture: .conversation, short: true,
                    notes: "A quiet line at the end of the thread: the plan and its next renewal.",
                    configure: { pingFront in
                        pingFront.person = PersonSummary(
                            id: "p_ada", level: .guest,
                            entitlement: Entitlement(
                                state: .active, productId: "pro_monthly", renewsAt: Self.fixedNow.addingTimeInterval(86_400 * 12),
                                source: .storekit))
                    })
                try await shot(
                    base, variant: Variant(scheme: scheme), state: "plan-test-purchase", title: "Plan status: test purchase",
                    fixture: .conversation, short: true,
                    notes: "A plan from a sandbox, TestFlight or StoreKit testing purchase says so under the line.",
                    configure: { pingFront in
                        var entitlement = Entitlement(
                            state: .active, productId: "pro_monthly", renewsAt: Self.fixedNow.addingTimeInterval(86_400 * 12),
                            source: .storekit)
                        entitlement.environment = "sandbox"
                        pingFront.person = PersonSummary(id: "p_ada", level: .guest, entitlement: entitlement)
                    })
            }
            for scheme in [ColorScheme.light, .dark] {
                try await shot(
                    base, variant: Variant(scheme: scheme), state: "store-actions", title: "Store action cards",
                    fixture: .conversation, short: true,
                    notes:
                        "store_action cards open Apple's own sheets in the app (billing issue, restore), so the buttons carry an SF Symbol and no outbound arrow; a change after the sheet closes shows as a receipt.",
                    configure: { pingFront in
                        pingFront.setPreviewStoreActions()
                        pingFront.conversation.messages += Fixtures.storeActionMessages
                    })
            }
            for scheme in [ColorScheme.light, .dark] {
                try await shot(
                    base, variant: Variant(scheme: scheme), state: "store-manage", title: "Manage subscription card",
                    fixture: .conversation, short: true,
                    notes:
                        "The card's title names the subject (Your subscription), the detail says what can change, and the button says what happens (Manage subscription, Apple's own sheet).",
                    configure: { pingFront in
                        pingFront.setPreviewStoreActions()
                        pingFront.conversation.messages += Fixtures.manageSubscriptionMessages
                    })
            }
            for scheme in [ColorScheme.light, .dark] {
                try await shot(
                    base, variant: Variant(scheme: scheme), state: "ai-handoff", title: "The AI teammate hands off to the team",
                    fixture: .conversation, short: true,
                    notes:
                        "A handed_off receipt is a plain system line without the green check: nothing was done for the person, a teammate will reply.",
                    configure: { pingFront in
                        pingFront.conversation.messages += Fixtures.aiHandoffMessages
                    })
            }
            for scheme in [ColorScheme.light, .dark] {
                try await shot(
                    base, variant: Variant(scheme: scheme), state: "offer-ended", title: "An offer that is no longer available",
                    fixture: .conversation, short: true,
                    notes:
                        "The app reports the newer offer as no longer available (OfferSlot.isAvailable false): the card stays in the thread, muted, without its price, and says so in place of its button; the older offer stays collapsed.",
                    configure: { pingFront in
                        pingFront.conversation.messages += Fixtures.offerMessages
                        pingFront.offerSlots = [OfferSlot(id: "pro_monthly", title: "Clockwise Pro, monthly", isAvailable: false)]
                    })
            }
            try await shot(
                base, state: "offers-superseded", title: "A newer offer replaces an older one", fixture: .conversation, short: true,
                notes: "The older offer collapses to one line; the person already owns the newer one's product, so it shows Current plan.",
                configure: { pingFront in
                    pingFront.conversation.messages += Fixtures.offerMessages
                    pingFront.currentEntitlement = Entitlement(state: .active, productId: "pro_monthly", source: .storekit)
                })
            try await shot(
                base, state: "photo-removed", title: "Photos removed by retention", fixture: .conversation, short: true,
                notes:
                    "Photos the app's retention deleted (removed: true, no url): a quiet muted line where a single photo was, the symbol alone in a grid tile. Nothing is fetched and nothing spins.",
                configure: { pingFront in pingFront.conversation.messages += Fixtures.removedPhotoMessages })
            try await shot(
                base, state: "photo-viewer", title: "Full-screen photo", fixture: .conversation, fullScreen: true,
                statusBarHidden: false,
                notes:
                    "Like Messages: Done and the sender over the date in the navigation bar, Share in the bottom bar. Tap hides the bars; pinch or double-tap zooms; swipe down closes.",
                content: { pingFront in
                    // A photo-like fixture; the marked-up screenshot belongs to the bug-report states.
                    AnyView(
                        PhotoViewer(
                            part: ImagePart(attachmentId: "att_landscape", width: 1170, height: 1560, url: nil), pingFront: pingFront,
                            sender: "Ada", date: Self.fixedNow.addingTimeInterval(-3_600), chromeHidden: false))
                })
            try await shot(
                base, state: "photo-viewer-chrome-hidden", title: "Full-screen photo, bars hidden", fixture: .conversation,
                fullScreen: true,
                statusBarHidden: true,
                notes: "A single tap hides the bars: black background, no status bar, like Photos.",
                content: { pingFront in
                    // A photo-like fixture; the marked-up screenshot belongs to the bug-report states.
                    AnyView(
                        PhotoViewer(
                            part: ImagePart(attachmentId: "att_landscape", width: 1170, height: 1560, url: nil), pingFront: pingFront,
                            sender: "Ada", date: Self.fixedNow.addingTimeInterval(-3_600), chromeHidden: true))
                })
            try await shot(
                base, variant: Variant(scheme: .dark), state: "photo-viewer", title: "Full-screen photo, dark", fixture: .conversation,
                fullScreen: true,
                statusBarHidden: false,
                notes:
                    "Like Messages: Done and the sender over the date in the navigation bar, Share in the bottom bar. Tap hides the bars; pinch or double-tap zooms; swipe down closes.",
                content: { pingFront in
                    // A photo-like fixture; the marked-up screenshot belongs to the bug-report states.
                    AnyView(
                        PhotoViewer(
                            part: ImagePart(attachmentId: "att_landscape", width: 1170, height: 1560, url: nil), pingFront: pingFront,
                            sender: "Ada", date: Self.fixedNow.addingTimeInterval(-3_600), chromeHidden: false))
                })
            try await shot(
                base, variant: Variant(scheme: .dark), state: "photo-viewer-chrome-hidden", title: "Full-screen photo, bars hidden, dark",
                fixture: .conversation, fullScreen: true,
                statusBarHidden: true,
                notes: "A single tap hides the bars: black background, no status bar, like Photos.",
                content: { pingFront in
                    // A photo-like fixture; the marked-up screenshot belongs to the bug-report states.
                    AnyView(
                        PhotoViewer(
                            part: ImagePart(attachmentId: "att_landscape", width: 1170, height: 1560, url: nil), pingFront: pingFront,
                            sender: "Ada", date: Self.fixedNow.addingTimeInterval(-3_600), chromeHidden: true))
                })
            try await shot(
                base, state: "jump-to-latest", title: "Jump to latest with new messages", fixture: .conversation,
                notes: "Scrolled up while three new messages arrived.",
                preview: { preview in
                    preview.scrolledToTop = true
                    preview.newMessageCount = 3
                })
            try await shot(
                base, state: "typing", title: "Typing indicator", fixture: .conversation, short: true, notes: "The teammate is typing.",
                configure: { pingFront in
                    pingFront.conversation.typing = TypingIndicator(name: "Deniz", isAI: false)
                })
            try await shot(
                base, state: "load-older", title: "Load earlier messages", fixture: .conversation,
                notes: "At the top of a long thread; earlier messages load on scroll.",
                configure: { pingFront in
                    pingFront.conversation.hasOlder = true
                    pingFront.conversation.isLoadingOlder = true
                }, preview: { preview in preview.scrolledToTop = true })

            // Variations on welcome and conversation.
            for state in ["welcome", "conversation"] {
                try await shot(
                    base, variant: Variant(scheme: .dark), state: state, title: "\(title(state)), dark", notes: "Dark mode tokens.")
                for scheme in [ColorScheme.light, .dark] {
                    let name = scheme == .dark ? "dark" : "light"
                    try await shot(
                        base, variant: Variant(scheme: scheme, reduceTransparency: true), state: state,
                        title: "\(title(state)), Reduce Transparency, \(name)",
                        notes: "Reduce Transparency: the glass header controls and composer turn opaque.")
                    try await shot(
                        base, variant: Variant(scheme: scheme, increaseContrast: true), state: state,
                        title: "\(title(state)), Increase Contrast, \(name)", notes: "Increase Contrast: borders and text darken.")
                }
                for (size, name) in [(DynamicTypeSize.xxxLarge, "XXXL"), (.accessibility3, "AX3"), (.accessibility5, "AX5")] {
                    try await shot(
                        base, variant: Variant(textSize: size), state: state, title: "\(title(state)), text size \(name)",
                        notes: "Dynamic Type \(name); header and composer stack at accessibility sizes.")
                }
                // Persian (right to left), Czech (four plural forms) and Tamil (a long script) came with the 41-locale set.
                for locale in ["ar", "de", "ja", "tr", "fa", "cs", "ta"] {
                    try await shot(
                        base, variant: Variant(locale: locale), state: state,
                        title: "\(title(state)), \(Locale(identifier: "en").localizedString(forIdentifier: locale) ?? locale)",
                        notes: locale == "ar" || locale == "fa"
                            ? "\(locale == "ar" ? "Arabic" : "Persian"), right to left. Team content is in the same language, as the team would write it."
                            : locale == "de" ? "German, long strings." : "SDK copy translated; team content as the team would write it.")
                }
                for (look, name, description) in [
                    (
                        Fixtures.variantA, "variant-a",
                        "Fieldnotes: serif, square corners, compact, team header, green accent, timestamps on every message, four custom topics."
                    ),
                    (
                        Fixtures.variantB, "variant-b",
                        "Stride: rounded font, soft corners, app icon header, forced dark scheme, orange accent, no avatars, its own reply expectation and an assistant called Coach."
                    ),
                    (
                        Fixtures.variantC, "variant-c",
                        "Sprout: pale yellow accent with black text picked by contrast, photos off, custom placeholder and topics, header shows Mara with a Contacts-style monogram."
                    ),
                ] {
                    try await shot(
                        base, variant: Variant(look: name), state: state,
                        title: "\(title(state)), look \(name.replacingOccurrences(of: "variant-", with: "").uppercased())",
                        lookOverride: look, lookName: name, notes: description)
                }
                for device in [Self.iPhoneSE, Self.iPhone17ProMax, Self.iPadMini, Self.iPadPro13, Self.iPadPro13Split] {
                    try await shot(
                        device, state: state, title: "\(title(state)), \(device.name)",
                        notes: device.presentation == .formSheet
                            ? "Form sheet over the app; reading width capped at 640 pt."
                            : device.presentation == .splitDetail
                                ? "Embedded PingFrontChatView as the detail column of the host app's split view." : "Full screen.")
                }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(entries).write(to: outputDirectory.appending(path: "manifest.json"))
            print("Rendered \(entries.count) snapshots to \(outputDirectory.path)")
        }

        private func title(_ state: String) -> String { state == "welcome" ? "Welcome" : "Conversation" }

        // MARK: Rendering

        private func shot(
            _ device: Device,
            variant: Variant = Variant(),
            state: String,
            title: String,
            fixture: PreviewFixture? = nil,
            short: Bool = false,
            draft: Bool = false,
            height: CGFloat? = nil,
            lookOverride: ChatLook? = nil,
            lookName: String? = nil,
            fullScreen: Bool = false,
            statusBarHidden: Bool = false,
            notes: String,
            configure: (PingFront) -> Void = { _ in },
            preview mutate: (inout ChatPreviewState) -> Void = { _ in },
            content: ((PingFront) -> AnyView)? = nil
        ) async throws {
            let fixture = fixture ?? (state.hasPrefix("welcome") ? .welcome : .conversation)
            let app = Fixtures.app(forVariant: lookName?.replacingOccurrences(of: "-draft", with: "") ?? "default")
            // The host app's AccentColor: system blue, like an app without a custom accent.
            let host = HostAppInfo(
                appName: app.name, accent: PingFrontColor(light: "#007AFF", dark: "#0A84FF"),
                iconPNG: FixtureImages.appIcon(app.id).pngData(), appVersion: "1.0 (1)")
            let pingFront = PingFront.preview(
                fixture, look: lookOverride ?? ChatLook(), draft: draft, host: host, language: variant.locale, app: app)
            if short { pingFront.conversation.messages = Array(pingFront.conversation.messages.prefix(5)) }
            configure(pingFront)
            var preview = ChatPreviewState()
            preview.isOffline = true
            preview.now = Self.fixedNow
            mutate(&preview)
            // Conversation shots start at a natural boundary: the top of the link card.
            if state == "conversation", preview.scrollTarget == nil, !preview.scrolledToTop { preview.scrollTarget = "msg_10" }

            let isRTL = Locale.Language(identifier: variant.locale).characterDirection == .rightToLeft
            let size = CGSize(width: device.points.width, height: height ?? device.points.height)
            let screen = content?(pingFront) ?? AnyView(PingFrontChatView())
            let chat =
                screen
                .environment(\.pingFrontInstance, pingFront)
                .environment(\.chatPreview, preview)
                .environment(\.chatClose, device.presentation == .splitDetail ? nil : ChatCloseAction {})
            let root = Container(
                device: device, size: size, content: AnyView(chat),
                darkChrome: variant.scheme == .dark || lookOverride?.theme.scheme == .dark,
                fullScreen: fullScreen, statusBarHidden: statusBarHidden
            )
            .environment(\.locale, Locale(identifier: variant.locale))
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
            .environment(\.dynamicTypeSize, variant.textSize)
            .environment(\.colorScheme, variant.scheme)
            .environment(\._accessibilityReduceTransparency, variant.reduceTransparency)
            .environment(\._colorSchemeContrast, variant.increaseContrast ? .increased : .standard)
            .environment(\.timeZone, TimeZone(identifier: "Europe/Berlin") ?? .gmt)
            // This container draws the sheet's chrome itself rather than presenting a real sheet, and outside a sheet
            // the system's close button takes the app's accent. In a real sheet iOS draws its glyph in the label colour
            // (checked against the system photo picker on the simulator, round 9): the container's tint is the label
            // colour so the snapshot shows what the person sees. The chat sets its own accent on its content.
            .tint(.primary)

            let controller = UIHostingController(rootView: root)
            controller.traitOverrides.userInterfaceStyle = variant.scheme == .dark ? .dark : .light
            controller.traitOverrides.layoutDirection = isRTL ? .rightToLeft : .leftToRight
            controller.traitOverrides.preferredContentSizeCategory = UIContentSizeCategory(variant.textSize)
            if variant.increaseContrast { controller.traitOverrides.accessibilityContrast = .high }
            if device.idiom == .pad { controller.traitOverrides.horizontalSizeClass = .regular }
            // The sheet's navigation stack takes its safe area from UIKit, not from the container's padding, and this
            // window stops short of the real screen's home indicator: give it the device's bottom inset, as the
            // simulator does, so the composer sits above the home indicator.
            if device.presentation == .fullScreen, !fullScreen { controller.additionalSafeAreaInsets.bottom = device.safeArea.bottom }
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))

            let format = UIGraphicsImageRendererFormat()
            // Tall renders use 2x: at 3x they would exceed the 8192 px texture limit.
            let scale = size.height * device.scale > 8192 ? 2 : device.scale
            format.scale = scale
            format.opaque = true
            var drew = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
                drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                if !drew { window.layer.render(in: context.cgContext) }
            }
            if !drew {
                fallbackCount += 1
                print("SnapshotMatrix: drawHierarchy failed for \(state); used layer.render")
            }
            window.isHidden = true

            let schemeName = variant.scheme == .dark ? "dark" : "light"
            var parts = [device.slug, schemeName]
            if variant.textSize != .large { parts.append(Self.sizeName(variant.textSize).lowercased()) }
            if variant.locale != "en" { parts.append(variant.locale) }
            if variant.reduceTransparency { parts.append("reduce-transparency") }
            if variant.increaseContrast { parts.append("increase-contrast") }
            if let lookName, !(lookName.hasSuffix("-draft")) { parts.append(lookName) }
            parts.append(state)
            let file = parts.joined(separator: "-") + ".png"
            guard let png = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: outputDirectory.appending(path: file))
            entries.append(
                Entry(
                    file: file,
                    title: title,
                    device: device.name,
                    points: [Int(size.width), Int(size.height)],
                    scale: Int(scale),
                    scheme: (lookOverride?.theme.scheme == .dark) ? "dark" : schemeName,
                    textSize: Self.sizeName(variant.textSize),
                    locale: variant.locale,
                    direction: isRTL ? "rtl" : "ltr",
                    state: state,
                    look: lookName ?? "default",
                    notes: notes
                ))
        }

        static func sizeName(_ size: DynamicTypeSize) -> String {
            switch size {
            case .large: "default"
            case .xxxLarge: "XXXL"
            case .accessibility3: "AX3"
            case .accessibility5: "AX5"
            default: "\(size)"
            }
        }
    }

    /// Places the chat as the device presents it: full screen, a form sheet over the app, or a split-view detail.
    private struct Container: View {
        let device: SnapshotMatrix.Device
        let size: CGSize
        let content: AnyView
        var darkChrome = false
        /// A full-screen cover (the photo viewer): edge to edge, no sheet.
        var fullScreen = false
        var statusBarHidden = false

        var body: some View {
            Group {
                if fullScreen {
                    content.overlay(alignment: .top) {
                        if !statusBarHidden {
                            StatusBar(height: device.safeArea.top, compact: device.safeArea.top < 40)
                                .environment(\.colorScheme, darkChrome ? .dark : .light)
                        }
                    }
                } else {
                    switch device.presentation {
                    case .fullScreen: phone
                    case .formSheet: sheet
                    case .splitDetail: split
                    }
                }
            }
            .ignoresSafeArea()
        }

        private var insets: EdgeInsets {
            EdgeInsets(
                top: device.safeArea.top, leading: device.safeArea.left, bottom: device.safeArea.bottom, trailing: device.safeArea.right)
        }

        /// The chat as the SDK presents it on iPhone: a page sheet at the large detent with a grabber,
        /// over the dimmed host app.
        private var phone: some View {
            let top = device.safeArea.top + 10
            let sheet = UnevenRoundedRectangle(
                topLeadingRadius: device.safeArea.top > 30 ? 38 : 12, topTrailingRadius: device.safeArea.top > 30 ? 38 : 12,
                style: .continuous)
            return ZStack(alignment: .top) {
                (darkChrome ? Color.black : Color(white: 0.78))
                content
                    .safeAreaPadding(EdgeInsets(top: 0, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing))
                    .clipShape(sheet)
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(darkChrome ? Color(white: 0.45) : Color(white: 0.75))
                            .frame(width: 36, height: 5)
                            .padding(.top, 5)
                    }
                    .padding(.top, top)
                StatusBar(height: device.safeArea.top, compact: device.safeArea.top < 40)
                    .environment(\.colorScheme, darkChrome ? .dark : .light)
            }
        }

        private var sheet: some View {
            ZStack {
                HostAppBackdrop()
                Color.black.opacity(0.22).ignoresSafeArea()
                content
                    .frame(width: min(640, size.width - 80), height: min(860, size.height - 180))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color(red: 0.09, green: 0.14, blue: 0.25).opacity(0.18), radius: 32, y: 12)
            }
            .overlay(alignment: .top) { StatusBar(height: device.safeArea.top, compact: true) }
        }

        private var split: some View {
            Group {
                NavigationSplitView {
                    List {
                        Label("Timers", systemImage: "timer")
                        Label("Stats", systemImage: "chart.bar")
                        Label("Settings", systemImage: "gearshape")
                        Label("Help", systemImage: "bubble.left.and.text.bubble.right").listRowBackground(Color.accentColor.opacity(0.15))
                    }
                    .navigationTitle("Clockwise")
                } detail: {
                    content
                }
                .navigationSplitViewStyle(.balanced)
            }
            .safeAreaPadding(insets)
            .overlay(alignment: .top) { StatusBar(height: device.safeArea.top, compact: true) }
        }
    }

    /// A quiet stand-in for the system status bar, so renders read like the device.
    private struct StatusBar: View {
        let height: CGFloat
        let compact: Bool
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            HStack {
                Text("9:41").font(.system(size: compact ? 12 : 17, weight: .semibold)).monospacedDigit()
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "cellularbars")
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                }
                .font(.system(size: compact ? 11 : 15, weight: .semibold))
            }
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .padding(.horizontal, compact ? 20 : 34)
            .frame(height: height)
            .padding(.top, compact ? 0 : 4)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
        }
    }

    /// A plain stand-in for the host app behind the form sheet.
    struct HostAppBackdrop: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Timers").font(.largeTitle.bold())
                ForEach(["Focus 25:00", "Workout 45:00", "Tea 4:00", "Pasta 9:00"], id: \.self) { name in
                    RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.95)).frame(height: 76)
                        .overlay(alignment: .leading) { Text(name).font(.title3).padding(.leading, 20) }
                }
                Spacer()
            }
            .padding(.horizontal, 40)
            .padding(.top, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
        }
    }

#endif
