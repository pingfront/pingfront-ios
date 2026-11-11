// swift-format-ignore-file
// The snippets stay exactly as README.md shows them (ReadmeSnippetTests checks every line).

// Every Swift block in README.md, compiled. `ReadmeSnippetTests` in PingFrontCoreTests fails when a README
// line is missing here, so the README cannot drift from the API. Placeholders (your app's own types and
// values) are declared at the bottom.
#if canImport(UIKit)
    import PingFront
    import StoreKit
    import SwiftUI
    import UIKit
    import UserNotifications

    // Block 0 (without @main, which a test target cannot declare)
    struct MyApp: App {
        init() { PingFront.configure("pk_live_…") }
        var body: some Scene { WindowGroup { ContentView() } }
    }

    @MainActor
    enum ReadmeSnippets {
        static func options() {
            PingFront.configure("pk_live_…") { config in
                config.topics = [.billing, .bug, .idea]  // up to 6; or ChatTopic(id:label:symbol:prefill:)
                config.appearance.accent = .indigo  // default: your AccentColor asset
                config.appearance.corners = .soft  // .round (18 pt), .soft (12), .square (6)
                config.appearance.font = .rounded  // .system, .rounded, .serif
                config.appearance.headerStyle = .team  // .person, .team, .app
                config.appearance.replyExpectation = "Usually replies within a few hours"  // default: "Usually replies within a day"
                config.use(.storeKit, .push, .reports)  // optional modules
                config.logLevel = .debug  // .off, .error, .info (default), .debug: request
                // paths and statuses, never bodies or tokens
                config.logHandler = { entry in  // also send SDK lines to your logger; ids, names,
                    AppLog.write("[pingfront/\(entry.category)] \(entry.message)")  // URLs and input arrive as <private>
                }
                config.language = "pt-BR"  // your app's own language picker; nil follows the system
            }
        }

        static func showChat() {
            // Anywhere: an SDK-presented sheet (form sheet on iPad).
            PingFront.shared.openChat()
            PingFront.shared.openChat(topic: .billing)
            PingFront.shared.closeChat()
        }

        final class UIKitHelp: UIViewController {
            func showHelp() {
                // The SDK finds the top view controller and presents its own sheet.
                PingFront.shared.openChat(topic: .billing)

                // Or push the chat like any other screen.
                let help = UIHostingController(rootView: PingFrontChatView())
                navigationController?.pushViewController(help, animated: true)
            }
        }

        struct HelpButton: View {
            @State var showHelp = false
            var body: some View {
                // SwiftUI sheet (large detent; pass detents: [.medium, .large] to open half height).
                Button("Help") { showHelp = true }
                    .pingFrontChat(isPresented: $showHelp, topic: .bug)
            }
        }

        struct HelpTab: View {
            var body: some View {
                TabView {
                    // Embedded in a tab or navigation stack.
                    PingFrontChatView()
                        .tabItem { Label("Help", systemImage: "bubble.left") }
                }
            }
        }

        static func identify() {
            PingFront.shared.identify(userId: user.id, name: user.name, email: user.email)  // named
            PingFront.shared.identify(token: jwtFromYourBackend)  // verified: one thread across devices
            PingFront.shared.setTraits(["plan": "pro", "city": "Izmir"])
        }

        static func moments() async {
            // Report app moments. Only moments a play listens to are sent (list cached for 5 minutes).
            let result = await PingFront.shared.moment("paywall_closed", props: ["screen": "plans", "seconds": 42])
            // .openRequested(presented: true): the server asked to open the chat and the SDK did. With
            // config.presentsChatForMoments = false it is .openRequested(presented: false): present it yourself.
            _ = result

            // Offers the team can send as cards.
            PingFront.shared.setOffers([OfferSlot(id: "yearly_winback", title: "Pro yearly", kind: .winback)])
            PingFront.shared.onOffer = { request in showPaywall(request.offerId) }

            // Subscription state (automatic with `.storeKit`).
            PingFront.shared.setEntitlement(Entitlement(state: .trial, productId: "pro_yearly", renewsAt: trialEnd))
        }

        static func purchase(_ product: Product) async throws {
            let options: Set<Product.PurchaseOption> = PingFront.shared.storeAccountToken.map { [.appAccountToken($0)] } ?? []
            let result = try await product.purchase(options: options)
            _ = result
        }

        static func push(config: inout PingFrontConfiguration) async {
            config.use(.push)  // optional: taps and foreground presentation

            let granted = await PingFront.shared.requestPushAuthorization()
            _ = granted
        }

        final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
            // AppDelegate: forward the token (the SDK never swizzles).
            func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
                PingFront.shared.setPushToken(token)
            }

            // Silent pushes (a new chat look) refresh in the background.
            func application(_ app: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
                await PingFront.shared.handleBackgroundPush(userInfo: userInfo).map(UIBackgroundFetchResult.init) ?? .noData
            }

            // If you have your own UNUserNotificationCenterDelegate:
            func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
                PingFront.shared.notificationPresentation(for: n)
            }
            func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
                PingFront.shared.handlePush(userInfo: r.notification.request.content.userInfo)
            }
        }

        static func reports(config: inout PingFrontConfiguration) async throws {
            config.use(.reports)  // shake to report, screenshot markup, log tail
            config.use(.reports([.logTail]))  // or pick: .shakeToReport, .logTail
            PingFront.shared.openReport()  // open the flow from a button
            try await PingFront.shared.reportBug(text: "Sync stopped", screenshot: pngData)
        }

        struct Badge: View {
            var body: some View {
                Text("Help").badge(PingFront.shared.unreadCount)  // @Observable
            }
        }

        static func events() async {
            for await event in PingFront.shared.events {
                switch event {
                case let .messageReceived(message): showBanner(message.preview)
                case let .unreadChanged(count): updateBadge(count)
                case let .messageSent(message): analytics.log("support_message_sent", ["photos": message.photoCount])
                case let .cardOpened(card): analytics.log("support_card_opened", ["kind": card.kind.rawValue])
                case let .configurationProblem(problem): print(problem.message)
                default: break
                }
            }
        }

        static func teamActions() {
            Task {
                for await action in PingFront.shared.teamActions {
                    switch action.actionId {
                    case "repair_sync":
                        await sync.repair(bank: action.fields["bank"])
                        await action.complete()  // the receipt line posts in the thread
                    case "extend_trial":
                        await entitlements.extend(until: action.until)
                        await action.complete()
                    default:
                        await action.fail(message: "This app version can't do \(action.name) yet.")
                    }
                }
            }
        }

        struct SyncService { func repair(bank: String?) async {} }
        struct EntitlementStore { func extend(until: Date?) async {} }
        static let sync = SyncService()
        static let entitlements = EntitlementStore()

        static func privacy() async throws {
            PingFront.shared.logout()  // see below; tells the server (retried until it succeeds)
            try await PingFront.shared.eraseMyData()  // DELETE /me, then the same local wipe
            let export = try await PingFront.shared.exportMyData()  // GET /me/export: the person's data as JSON
            _ = export
            try await PingFront.shared.prepare()  // create the session now (for example after login)
        }

        static func crashReporter(_ crashUserId: String) {
            PingFront.shared.setTraits(["crashReporterUserId": crashUserId])
        }

        static func links() {
            PingFront.shared.onLink = { url in url.scheme == "myapp" ? route(url) : false }
        }

        // Saved links into your screens
        static func screens() {
            PingFront.shared.registerScreens([
                AppScreen(id: "settings.sound", title: "Sound settings"),   // the title is for the team's dashboard only
                AppScreen(id: "plans/yearly"),
            ])

            PingFront.shared.onScreen = { screen in                           // main actor; may be async
                router.open(screen.id, params: screen.params)                 // params: [String: String]
                return true                                                   // false: the app can't open it now
            }
        }

        // Placeholders for your app's own code.
        struct User {
            let id = "u_1"
            let name = "Ada"
            let email = "ada@example.com"
        }
        static let user = User()
        static let jwtFromYourBackend = "header.payload.signature"
        static let trialEnd = Date.now
        static let pngData = Data()
        static func showPaywall(_ id: String) {}
        static func showBanner(_ text: String) {}
        static func updateBadge(_ count: Int) {}
        static func route(_ url: URL) -> Bool { true }
        nonisolated enum AppLog { static func write(_ line: String) {} }
        enum analytics { static func log(_ name: String, _ values: [String: Any]) {} }
    }

    struct ContentView: View {
        var body: some View { Text("Clockwise") }
    }

    // Links into the chat (SwiftUI)
    struct LinkedApp: App {
        var body: some Scene {
            // SwiftUI: universal links and your custom scheme both arrive in onOpenURL.
            WindowGroup {
                ContentView()
                    .onOpenURL { url in
                        if PingFront.shared.handle(url) { return }
                        router.open(url)
                    }
            }
        }
    }

    /// Your app's own router (a placeholder).
    @MainActor enum router {
        static func open(_ url: URL) {}
        static func open(_ id: String, params: [String: String]) {}
    }

    // Links into the chat (UIKit)
    // UIKit: the scene delegate gets links at a cold start and while running.
    final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
        var window: UIWindow?

        func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
            if let url = connectionOptions.urlContexts.first?.url ?? connectionOptions.userActivities.first?.webpageURL {
                if !PingFront.shared.handle(url) { router.open(url) }
            }
        }

        func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
            guard let url = URLContexts.first?.url, !PingFront.shared.handle(url) else { return }
            router.open(url)
        }

        func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
            guard let url = userActivity.webpageURL, !PingFront.shared.handle(url) else { return }
            router.open(url)
        }
    }

    // Push: another library owns the notification delegate.
    extension SceneDelegate {
        func handleNotificationTap(_ userInfo: [AnyHashable: Any]) {
            if PingFront.shared.handlePush(userInfo: userInfo) { return }  // pingfront's: the chat opens
            // the other library's handling
        }
    }
#endif
