public import Foundation
public import Observation
internal import os

/// The pingfront SDK: in-app support chat and proactive messages ("pings").
///
/// ```swift
/// import PingFront
/// PingFront.configure("pk_live_…")
/// PingFront.shared.identify(userId: user.id, name: user.name, email: user.email)
/// PingFront.shared.openChat()
/// ```
///
/// A new install sends nothing at configure or launch (one with a session from an earlier launch may
/// check unread messages and report store lapses). A session is created lazily on the first chat open,
/// listened moment, push open, bug report or `prepare()`.
@MainActor @Observable
public final class PingFront {
    /// The shared instance.
    public static let shared = PingFront()

    /// The problem found at configure time, or `nil`.
    ///
    /// In debug builds the chat shows it in a red banner.
    public package(set) var configurationProblem: ConfigurationProblem?
    /// Unread team messages.
    ///
    /// Observable: use it for a badge.
    public package(set) var unreadCount = 0
    /// True while the chat is on screen (sheet or embedded view).
    public package(set) var isChatVisible = false
    /// The resolved chat look (remote > code > host app > defaults).
    public package(set) var look: ResolvedLook = .resolve(remote: nil, code: ChatAppearance(), codeTopics: nil, host: nil)
    /// The person, once a session exists.
    public package(set) var person: PersonSummary?
    /// True when the dashboard marked this device as a test device (it previews draft looks).
    public package(set) var isTestDevice = false
    /// The person's store account token, once a session exists.
    ///
    /// Pass it as `appAccountToken` in your own
    /// StoreKit purchases (`.appAccountToken(token)`) so App Store notifications match this person.
    /// The `.storeKit` module does this for purchases from offer cards.
    public package(set) var storeAccountToken: UUID?
    /// The entitlement last reported (by the app or a store module), for "Current plan" on offer cards.
    package var currentEntitlement: Entitlement?

    /// True when the person already owns `productIds` (an active, trial, grace, retry or lifetime entitlement).
    package func owns(anyOf productIds: [String]) -> Bool {
        guard let entitlement = currentEntitlement, let product = entitlement.productId else { return false }
        // Cancelled still owns it until the period ends.
        let owned =
            [.trial, .active, .grace, .billingRetry, .lifetime].contains(entitlement.state)
            || (entitlement.state == .cancelled && (entitlement.expiresAt.map { $0 > .now } ?? false))
        return owned && productIds.contains(product)
    }

    /// The plan for the chat's status line: the server's (from store events) first; the device's StoreKit view
    /// only when the server has none.
    package var planEntitlement: Entitlement? {
        if let server = person?.entitlement { return server }
        guard let local = currentEntitlement, local.source == .storekit else { return nil }
        return local
    }

    /// Native store views registered by the StoreKit module (the chat UI casts it).
    package var storeSurfaces: AnyObject? { registry.storeSurfaces }

    /// Records that the person opened a card whose action ran in a native view (no further handling).
    package func recordCardOpened(_ card: Card, messageId: String) { engine?.cards.report(card: card, messageId: messageId) }

    /// Shows "Waiting for approval" on an offer card (Ask to Buy, Strong Customer Authentication).
    package func markAwaitingApproval(cardId: String) { conversation.awaitingApproval.insert(cardId) }

    /// Opens Apple's sheet for a store action that isn't on a card (the plan status line's button).
    package func performStoreAction(_ card: StoreActionCard) { engine?.cards.perform(card) }

    /// The last identity problem the server reported (for the self-check); cleared by logout and erase.
    package var lastIdentityProblem: IdentityProblem?

    /// Records and announces an identity the server refused.
    package func reportIdentityProblem(_ problem: IdentityProblem) {
        lastIdentityProblem = problem
        hub.emit(.identityProblem(problem))
    }

    /// True after a successful `configure`.
    public package(set) var isConfigured = false
    /// The thread state and actions, for the built-in UI or your own.
    public let conversation = Conversation()

    /// Called for every link the person taps in the chat (message text, link cards).
    ///
    /// Return `true` when you handled it (for example a deep link into your app); otherwise web links open in an
    /// in-app Safari view and other links through the system.
    ///
    /// It may be `async` (a bridge waiting for JavaScript or Dart, a router that loads first) or a plain closure. The SDK
    /// waits for the answer at most 10 seconds, as for ``onScreen``: no answer by then counts as `false`, the handler is
    /// cancelled and its late answer ignored, and the link opens the default way. A link card reports what really
    /// happened: opened, or failed with `cannot_open` when the default way opened nothing either. A newer link tapped in
    /// a message replaces one still waiting, and `logout()` cancels a wait.
    ///
    /// ```swift
    /// PingFront.shared.onLink = { url in
    ///     guard url.scheme == "myapp" else { return false }
    ///     return await router.open(url)
    /// }
    /// ```
    @ObservationIgnored public var onLink: (@MainActor (URL) async -> Bool)?

    /// Called when the person taps a link card that opens a screen of your app (a saved link the team sent).
    ///
    /// Only for screens this build registered with ``registerScreens(_:)``. Open the screen for `screen.id` with
    /// `screen.params` and return `true`; return `false` when you can't, and the team sees the link as failed. A card for
    /// a screen this build didn't register opens its URL instead, when it has one.
    ///
    /// It may be `async` (a bridge waiting for JavaScript or Dart, a router that loads first) or a plain closure. The SDK
    /// waits for the answer before it reports the tap, at most 10 seconds: no answer by then counts as `false`, as on
    /// Android.
    ///
    /// ```swift
    /// PingFront.shared.registerScreens([AppScreen(id: "settings.sound", title: "Sound settings")])
    /// PingFront.shared.onScreen = { screen in
    ///     router.open(screen.id, params: screen.params)
    /// }
    /// ```
    @ObservationIgnored public var onScreen: (@MainActor (LinkScreen) async -> Bool)?

    /// The screens registered with ``registerScreens(_:)``.
    @ObservationIgnored package let screenRegistry = ScreenRegistry()

    /// Registers the screens of your app that the team's saved links can open (https://pingfront.sh/docs/offers#saved-links).
    ///
    /// Call it once at launch, before or after `configure`, with every screen your router can open; calling it again
    /// replaces the list (`[]` says this build registers none). Ids must match `^[A-Za-z0-9][A-Za-z0-9_./:-]{0,99}$`:
    /// a debug build stops on a bad id, a release build drops it. At most 200 screens, each id once (the first wins).
    ///
    /// The list never makes a request of its own: it goes out with the next session the SDK starts, and on a refresh
    /// or profile update only when the list or the app version changed. A tap on a link card for one of these screens
    /// calls ``onScreen``.
    public func registerScreens(_ screens: [AppScreen]) {
        screenRegistry.register(screens)
    }

    /// The chat's language when your app has its own language picker: a BCP 47 tag such as `"de"` or `"pt-BR"`.
    ///
    /// `nil` (the default) follows the app's and the system's language. The chat UI, the SDK's own
    /// strings, the team's localized texts and the language the server writes in all follow it. Set it again
    /// whenever the person picks a language; an invalid tag is ignored and logged.
    public var language: String? {
        get { languageTag }
        set { setLanguage(newValue) }
    }

    private var languageTag: String?

    private func setLanguage(_ raw: String?) {
        let tag = LanguageOverride.normalized(raw)
        if raw != nil, tag == nil {
            Log.config(.error)?.error("PingFront.language must be a BCP 47 tag such as \"de\" or \"pt-BR\"; the value was ignored.")
            return
        }
        guard tag != languageTag else { return }
        languageTag = tag
        LanguageOverride.tag = tag
        engine?.languageChanged()
    }

    /// True when something can show an offer: the host's `onOffer` or a module's handler.
    package var canHandleOffers: Bool { onOffer != nil || registry.offerHandler != nil }

    /// Opens a link from the chat (message text, a review or store action fallback): the link card URL rule first, then
    /// the host's `onLink`, then the chat presenter.
    ///
    /// A URL the link card URL rule refuses never reaches `onLink`, so a bridge that forwards it never sees one.
    /// Without `onLink` the presenter opens it at once. Otherwise the wait for its answer runs in ``chatLinkTask``,
    /// which the next link replaces and `logout()`, an erase and teardown cancel: a cancelled wait opens nothing.
    package func openLink(_ url: URL) {
        guard LinkURLRule.allows(url.absoluteString) else { return }
        chatLinkTask?.cancel()
        chatLinkTask = nil
        guard onLink != nil else {
            registry.chatPresenter?.open(url)
            return
        }
        let time = engine?.time ?? .continuous
        chatLinkTask = Task { [weak self] in
            guard let self, await !self.linkHandled(url, time: time), !Task.isCancelled else { return }
            self.registry.chatPresenter?.open(url)
        }
    }

    /// The task waiting for the `onLink` answer to the last link tapped in a message, if one is running.
    @ObservationIgnored package private(set) var chatLinkTask: Task<Void, Never>?

    /// Cancels the wait for a message link's `onLink` answer (logout, erase, teardown).
    package func cancelChatLink() {
        chatLinkTask?.cancel()
        chatLinkTask = nil
    }

    /// The host's `onLink` answer for `url`: `false` without one, or when none comes within
    /// ``CardActions/handlerAnswerLimit`` on `time` (``CardActions/answer(_:_:within:time:)``).
    package func linkHandled(_ url: URL, time: TimeSource) async -> Bool {
        guard let onLink else { return false }
        return await CardActions.answer(onLink, url, within: CardActions.handlerAnswerLimit, time: time)
    }

    /// Opens a link card's URL and says whether something opened it.
    ///
    /// The host's `onLink` first (awaited, at most 10 seconds on `time`), then ``openLinkByDefault(_:)``. A cancelled
    /// tap (logout) opens nothing and returns `false`.
    package func openLinkReportingOutcome(_ url: URL, time: TimeSource) async -> Bool {
        if await linkHandled(url, time: time) { return true }
        guard !Task.isCancelled else { return false }
        return await openLinkByDefault(url)
    }

    /// Opens a link the way the chat does when `onLink` declines it, and says whether something opened it.
    ///
    /// The SDK calls it itself after `onLink` declines a link card's URL; apps with their own chat UI on
    /// ``conversation`` can call it too. The link card URL rule first (https://pingfront.sh/docs/chat-links), then Safari for
    /// `http` and `https`, or the system for one of the app's own schemes (`CFBundleURLSchemes`). Any other URL, and a
    /// `javascript:`, `data:`, `vbscript:`, `file:`, `blob:`, `about:`, `content:` or `intent:` one, opens nothing and
    /// returns `false`.
    public func openLinkByDefault(_ url: URL) async -> Bool {
        let cleaned = LinkURLRule.clean(url.absoluteString)
        guard LinkURLRule.allows(cleaned), let url = URL(string: cleaned) else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        guard LinkURLRule.webSchemes.contains(scheme) || appURLSchemes.contains(scheme) else { return false }
        guard let presenter = registry.chatPresenter else { return false }
        return await presenter.openLink(url)
    }

    /// Called when the person taps an offer card.
    ///
    /// Show your paywall or promo for `request.offerId`.
    /// When unset, a registered offer module (for example `.storeKit`) handles it.
    @ObservationIgnored public var onOffer: (@MainActor (OfferRequest) -> Void)?

    @ObservationIgnored package var engine: Engine?
    @ObservationIgnored let registry = ModuleRegistry()
    @ObservationIgnored let hub = EventHub()
    @ObservationIgnored let teamActionHub = TeamActionHub()
    @ObservationIgnored package internal(set) var configuration = PingFrontConfiguration()
    /// The offers last reported with `setOffers(_:)`, for prices on offer cards and whether they are still offered
    /// (observed: a card already in the thread updates when its offer ends).
    package var offerSlots: [OfferSlot] = []
    /// The app's own URL schemes (Info.plist `CFBundleURLSchemes`), the only non-web schemes a link card opens.
    @ObservationIgnored package var appURLSchemes: Set<String> = LinkURLRule.appSchemes()
    /// A fixed "now" for staged marketing captures (timestamps and the teammate's local time).
    @ObservationIgnored package var demoNow: Date?
    /// Staged captures and audits: the thread opens at its top instead of its newest message.
    @ObservationIgnored package var demoScrolledToTop = false
    /// Look used by previews and snapshots when there is no engine.
    @ObservationIgnored package var previewConfig: AppConfig?

    init() {}

    // MARK: Configure

    /// Starts the SDK with an app key and a configuration: the one setup entry point.
    ///
    /// Apps on the `PingFront` product call `PingFront.configure(_:_:)`, which adds the chat UI and calls
    /// this. Apps that use `PingFrontCore` alone (their own UI on `conversation`) call it directly:
    ///
    /// ```swift
    /// var config = PingFrontConfiguration()
    /// config.logLevel = .debug
    /// PingFront.shared.start(appKey: "pk_live_…", configuration: config)
    /// ```
    ///
    /// Pass `nil` to read `PingFrontAppKey` from Info.plist. The key is checked offline; nothing is sent.
    public func start(appKey rawKey: String? = nil, configuration: PingFrontConfiguration = PingFrontConfiguration()) {
        Log.currentLevel = configuration.logLevel
        Log.handler = configuration.logHandler
        if let language = configuration.language { setLanguage(language) }
        if engine != nil {
            Log.config(.info)?.notice("PingFront.configure was called again; restarting with the new configuration.")
            teardown()
        }
        self.configuration = configuration
        configurationProblem = nil

        let keyString = rawKey ?? (Bundle.main.object(forInfoDictionaryKey: "PingFrontAppKey") as? String)
        guard let keyString else {
            report(
                ConfigurationProblem(
                    kind: .missingKey,
                    message: "No app key. Pass it to PingFront.configure(\"pk_live_…\") or add PingFrontAppKey to Info.plist.",
                    disablesSDK: true))
            installModules()
            applyPendingLink()
            return
        }
        let key: AppKey
        switch AppKey.parse(keyString) {
        case .success(let parsed): key = parsed
        case .failure(let error):
            report(ConfigurationProblem(kind: .invalidKey(error.problem), message: error.problem.message, disablesSDK: true))
            installModules()
            applyPendingLink()
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains(LaunchArgument.selfCheck) {
                    SetupCheck.emit(SetupCheck.result(forKeyProblem: error.problem).line)
                }
            #endif
            return
        }
        for problem in Self.optionProblems(configuration) { report(problem) }

        let dependencies = configuration.dependencies ?? .live(namespace: Dependencies.namespace(for: key))
        let engine = Engine(facade: self, key: key, configuration: configuration, dependencies: dependencies)
        self.engine = engine
        isConfigured = true
        installModules()
        engine.start()
        Log.config(.info)?.info("pingfront configured with \(key.description, privacy: .public) (\(key.mode.rawValue, privacy: .public))")
        #if DEBUG
            engine.runLaunchArguments()
        #endif
        applyPendingLink()
    }

    private func installModules() {
        for module in configuration.modules where !registry.installed.contains(module.id) {
            registry.installed.append(module.id)
            module.install(ModuleContext(pingFront: self))
        }
        engine?.modulesInstalled()
        refreshLook()
    }

    package func teardown() {
        cancelChatLink()
        engine?.stop()
        engine = nil
        registry.cancelAll()
        registry.reset()
        wipeHandlers = []
        isConfigured = false
    }

    /// Runs when local person data is wiped (logout, erase, revoked): UI caches register here.
    @ObservationIgnored package var wipeHandlers: [@MainActor () -> Void] = []

    /// Registers a handler that clears local caches on logout, erase or a revoked session.
    package func onLocalDataWipe(_ handler: @escaping @MainActor () -> Void) { wipeHandlers.append(handler) }

    package func runWipeHandlers() { wipeHandlers.forEach { $0() } }

    static func optionProblems(_ configuration: PingFrontConfiguration) -> [ConfigurationProblem] {
        var problems: [ConfigurationProblem] = []
        if let topics = configuration.topics {
            if topics.count > 6 {
                problems.append(
                    .init(
                        kind: .option,
                        message: "config.topics has \(topics.count) topics; the chat shows at most 6. Remove \(topics.count - 6).",
                        disablesSDK: false))
            }
            let ids = topics.map(\.id)
            if Set(ids).count != ids.count {
                problems.append(
                    .init(kind: .option, message: "config.topics has duplicate ids. Give every topic a unique id.", disablesSDK: false))
            }
            for topic in topics where !Self.isValidTopicId(topic.id) {
                problems.append(
                    .init(
                        kind: .option, message: "Topic id \"\(topic.id)\" must be 1–32 characters of a-z, 0-9, _ or -.", disablesSDK: false)
                )
            }
        }
        let scheme = configuration.baseURL.scheme ?? ""
        if scheme != "https" && scheme != "http" {
            problems.append(
                .init(
                    kind: .option, message: "config.baseURL must be an http(s) URL, for example https://api.pingfront.sh/v1.",
                    disablesSDK: false))
        }
        #if !DEBUG
            if scheme == "http" {
                problems.append(
                    .init(kind: .option, message: "config.baseURL uses http in a release build. Use https.", disablesSDK: false))
            }
        #endif
        return problems
    }

    private static func isValidTopicId(_ id: String) -> Bool {
        (1...32).contains(id.utf8.count) && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }

    /// Clears a reported problem that no longer holds (the app was resumed).
    package func clearConfigurationProblem() { configurationProblem = nil }

    package func report(_ problem: ConfigurationProblem) {
        if configurationProblem == nil || problem.disablesSDK { configurationProblem = problem }
        #if DEBUG
            Log.config(.error)?.fault("pingfront setup problem: \(problem.message, privacy: .public)")
        #else
            Log.config(.error)?.error("pingfront setup problem: \(problem.message, privacy: .public)")
        #endif
        hub.emit(.configurationProblem(problem))
    }

    // MARK: Identity and profile (fire-and-forget into the actors, in call order)

    /// Names the person.
    ///
    /// Unverified: the person keeps one thread per install until verified.
    public func identify(userId: String, name: String? = nil, email: String? = nil) {
        guard let engine else { return notConfigured("identify") }
        // Too long is refused, never truncated: a cut id would name a different person.
        guard !userId.isEmpty, TextLimit.count(userId) <= Limits.userIdChars else {
            Log.config(.error)?.error("identify(userId:) needs 1 to \(Limits.userIdChars, privacy: .public) characters; it was ignored.")
            return
        }
        let id = userId
        var cleanEmail = email
        if let email, !ProfileValidation.isEmail(email) {
            Log.config(.error)?.error("identify: the email is not valid and was not sent.")
            cleanEmail = nil
        }
        engine.submit(
            .stage(.identity(Identity(userId: id, name: Self.checkedName(name), email: cleanEmail, token: nil))))
    }

    /// Verifies the person with an HS256 token signed by your backend (claims: `sub`, `iat`, `exp` at most 24 hours after
    /// `iat`, optional `name`/`email`).
    ///
    /// Verified people get one thread across devices and reinstalls.
    public func identify(token: String) {
        guard let engine else { return notConfigured("identify") }
        guard token.count <= Limits.identityTokenChars, let claims = IdentityToken.claims(token) else {
            report(
                .init(
                    kind: .option,
                    message:
                        "identify(token:) got something that is not a JWT with a `sub` claim. Sign an HS256 token with the app's identity secret.",
                    disablesSDK: false))
            return
        }
        engine.submit(.stage(.identity(Identity(userId: claims.sub, name: claims.name, email: claims.email, token: token))))
    }

    /// Adds or updates traits (merged; at most 30, keys ≤ 64, values ≤ 512 characters).
    public func setTraits(_ traits: [String: String]) {
        guard let engine else { return notConfigured("setTraits") }
        let (clean, problems) = ProfileValidation.clean(traits)
        for problem in problems { Log.config(.error)?.error("setTraits: \(problem, privacy: .public)") }
        engine.submit(.stage(.traits(clean)))
    }

    /// Reports the person's subscription state.
    public func setEntitlement(_ entitlement: Entitlement) {
        guard let engine else { return notConfigured("setEntitlement") }
        engine.submit(.stage(.entitlement(entitlement)))
    }

    /// Reports the offers the app can show, so the team can send offer cards for them.
    ///
    /// Slots are grouped by `source` (`.app` when unset): each group replaces that source's earlier slots,
    /// and other sources' slots (`.storeKit(products:)`, vendor adapters) stay. An empty list clears the
    /// app's own slots. To withdraw a module's slots, use `setOffers(_:from:)` with an empty list.
    public func setOffers(_ offers: [OfferSlot]) {
        var buckets: [OfferSlot.Source: [OfferSlot]] = offers.isEmpty ? [.app: []] : [:]
        for slot in offers { buckets[slot.source ?? .app, default: []].append(slot) }
        for (source, slots) in buckets { replaceSlots(slots, from: source) }
        publishSlots()
    }

    /// Reports the offers one source can show, replacing only that source's earlier slots.
    ///
    /// Modules and vendor adapters call this; every slot is stamped with `source`. Pass an empty list to
    /// withdraw the source's slots.
    public func setOffers(_ offers: [OfferSlot], from source: OfferSlot.Source) {
        replaceSlots(offers, from: source)
        publishSlots()
    }

    /// Each source's slots, merged into `offerSlots`.
    @ObservationIgnored package var slotsBySource: [OfferSlot.Source: [OfferSlot]] = [:]

    private func replaceSlots(_ offers: [OfferSlot], from source: OfferSlot.Source) {
        slotsBySource[source] = offers.map { slot in
            var slot = slot
            slot.source = source
            return slot
        }
    }

    private func publishSlots() {
        guard let engine else { return notConfigured("setOffers") }
        let merged = Self.mergedSlots(slotsBySource)
        engine.offers = merged
        offerSlots = merged
        engine.submit(.stage(.offers(merged)))
    }

    /// The app's slots first, then each source's in `OfferSlot.Source` order; the first slot with an id wins;
    /// at most 20 (the protocol's limit).
    package static func mergedSlots(_ buckets: [OfferSlot.Source: [OfferSlot]]) -> [OfferSlot] {
        let order: [OfferSlot.Source] = [.app] + OfferSlot.Source.allCases.filter { $0 != .app }
        var seen = Set<String>()
        var merged: [OfferSlot] = []
        for source in order {
            for slot in buckets[source] ?? [] where seen.insert(slot.id).inserted { merged.append(slot) }
        }
        return Array(merged.prefix(20))
    }

    /// Forwards the APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    ///
    /// Pass `nil` to clear it (the person turned notifications off, or the app unregistered): the server stops
    /// sending pushes to this install.
    public func setPushToken(_ token: Data?) {
        guard let engine else { return notConfigured("setPushToken") }
        guard let token else { return engine.clearPush() }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        engine.setPush(hex: hex)
    }

    /// Handles a notification tap.
    ///
    /// Returns `true` when it was a pingfront notification. Message and ping
    /// notifications open the chat; payload versions or kinds this SDK does not know are ignored.
    @discardableResult
    public func handlePush(userInfo: [AnyHashable: Any]) -> Bool {
        guard PushPayload.isPingFront(userInfo) else { return false }
        guard let payload = PushPayload(userInfo: userInfo) else { return true }
        switch payload.kind {
        case .message, .ping:
            engine?.pushOpened()
            openChat()
        case .config:
            engine?.pushReceived(payload)
        }
        return true
    }

    /// Handles a silent pingfront push (`content-available: 1`, no alert) in the background.
    ///
    /// For example a new chat look (`kind: config`). Call it from `application(_:didReceiveRemoteNotification:)` and
    /// return its result to the system (the push module maps it to `UIBackgroundFetchResult`).
    ///
    /// Shows nothing and never starts a session: it refreshes only for an install that already has one. Returns
    /// `nil` for pushes that aren't pingfront's.
    public func handleBackgroundPush(userInfo: [AnyHashable: Any]) async -> BackgroundPushResult? {
        guard PushPayload.isPingFront(userInfo) else { return nil }
        guard let engine, let payload = PushPayload(userInfo: userInfo) else { return .noData }
        return await engine.backgroundPush(payload)
    }

    /// Updates the unread count from a pingfront notification that arrived while the app is open.
    ///
    /// The push module and `notificationPresentation(for:)` call this for you.
    public func pushReceived(userInfo: [AnyHashable: Any]) {
        guard let payload = PushPayload(userInfo: userInfo) else { return }
        engine?.pushReceived(payload)
    }

    /// True for pingfront notification payloads.
    public func isPingFrontPush(userInfo: [AnyHashable: Any]) -> Bool { PushPayload.isPingFront(userInfo) }

    /// True when the dashboard turned on the app icon badge (`features.appBadge`).
    ///
    /// Off by default:
    /// the badge belongs to your app, and pingfront never touches it unless you opt in.
    public var usesAppBadge: Bool { engine?.remoteConfig?.features.appBadge ?? false }

    /// Reports an app moment (`paywall_closed`, `trial_cancelled`, …).
    ///
    /// Only moments a play listens to are sent
    /// (the list is cached for 5 minutes). When the server answers `open`, the chat is presented.
    @discardableResult
    public func moment(_ name: String, props: [String: MomentValue] = [:]) async -> MomentResult {
        guard let engine else { return .failed(.notConfigured) }
        return await engine.moment(name, props: props)
    }

    /// Creates the session now instead of lazily (for example right after login, to receive pings sooner).
    public func prepare() async throws(PingFrontError) {
        guard let engine else { throw .notConfigured }
        try await engine.prepare()
    }

    // MARK: Chat

    /// Presents the chat sheet.
    ///
    /// With a topic, its prefill goes into the composer (or it starts the thread on that topic). While an embedded
    /// `PingFrontChatView` is on screen, there is never a second chat: it focuses that one's composer instead (so do
    /// chat links, push taps and moments, which open the chat this way).
    public func openChat(topic: ChatTopic? = nil) {
        if let topic {
            conversation.composerInsertion = topic.prefill?.resolve(for: DeviceInfo.languageTag) ?? conversation.composerInsertion
        }
        if isEmbeddedChatVisible {
            conversation.requestComposerFocus()
            return
        }
        guard let presenter = registry.chatPresenter else {
            Log.config(.error)?.error("openChat: no chat UI is installed. Use the PingFront product, or config.use(.chatUI).")
            return
        }
        presenter.presentChat(topic: topic)
    }

    /// Opens the chat, or the bug report, from a chat link your app received; returns `true` when it was one.
    ///
    /// A chat link is any URL your app routes here whose query has `pingfront=chat` or `pingfront=report`, on your
    /// own universal link domain or custom scheme (`https://example.com/help?pingfront=chat`,
    /// `myapp://support?pingfront=chat&topic=billing`). The SDK claims no domain or scheme of its own. `topic` is
    /// used only when it is the id of one of the chat's topics; other parameters are ignored, and a link never puts
    /// text in the composer. Returns `false` for every other URL, so route those yourself.
    ///
    /// Handling a link is the same as ``openChat(topic:)`` or ``openReport(prefill:)``: the session starts when the
    /// chat appears, and this call sends nothing. Before `configure` the link is kept in memory (the last one wins)
    /// and applied once, right after `configure`.
    ///
    /// ```swift
    /// WindowGroup { ContentView() }
    ///     .onOpenURL { url in
    ///         if PingFront.shared.handle(url) { return }
    ///         router.open(url)
    ///     }
    /// ```
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        switch ChatLink.parse(url) {
        case .failure(let refusal):
            if refusal != .notALink { Log.config(.info)?.info("A chat link was refused (\(refusal.rawValue, privacy: .public)).") }
            return false
        case .success(let link):
            guard hasStarted else {
                pendingLink = link
                return true
            }
            apply(link)
            return true
        }
    }

    /// A chat link handled before `configure`, applied once when it runs.
    @ObservationIgnored private var pendingLink: ChatLink?
    /// True once `configure` (or `start`) ran, whatever its outcome: the chat UI is installed from then on.
    @ObservationIgnored var hasStarted = false

    private func apply(_ link: ChatLink) {
        switch link {
        case .chat(let topicId):
            openChat(topic: topicId.flatMap { id in look.topics.first { $0.id == id } })
        case .report:
            openReport()
        }
    }

    private func applyPendingLink() {
        hasStarted = true
        guard let link = pendingLink else { return }
        pendingLink = nil
        apply(link)
    }

    /// Closes the SDK-presented chat.
    ///
    /// A chat the app presents with `.pingFrontChat(isPresented:)` is the app's to close, through its binding.
    public func closeChat() { registry.chatPresenter?.dismissChat() }

    /// Closes the chat the SDK presented and returns once it is gone.
    ///
    /// Returns at once when the SDK presented no chat, even while the app shows an embedded `PingFrontChatView` or a
    /// chat it presents with `.pingFrontChat(isPresented:)`: the app closes those itself (removing the view, or setting
    /// the binding to false). With the SDK's own sheet it returns when the sheet's dismissal has finished, the
    /// sheet and anything over it (a photo picker, a bug report). A custom presenter (`ChatPresenting`) is asked to
    /// dismiss whenever it says it presents a chat (`isPresentingChat`, true unless it says otherwise); then the call
    /// waits for the chat's `.chatClosed`, at most two seconds. For bridges (React Native, Flutter) that chain
    /// presentations. Android's equivalent is `closeChatAndWait()` (Kotlin can't overload on `suspend` alone).
    public func closeChat() async {
        guard let presenter = registry.chatPresenter, presenter.isPresentingChat else { return }
        // Subscribed before the dismissal, so a `.chatClosed` sent while it runs is not missed.
        let events = hub.stream()
        await presenter.dismissChatAndWait()
        guard !(presenter is any ReportsChatDismissal), isChatVisible else { return }
        // The chat reports its own disappearance; wait for it, at most two seconds (a chat the app presents
        // itself may stay up). Cancelling the caller ends the wait at once.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events where event == .chatClosed { return }
            }
            // On the injected clock (tests use a manual one), like every SDK delay.
            let time = engine?.time ?? TimeSource(ContinuousClock())
            group.addTask { _ = await time.pause(.seconds(2)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Checks the setup end to end: creates the session if needed, sends "Setup check from <app>" to your inbox,
    /// and waits for the server (at most `timeout`).
    ///
    /// The result says what to fix; it carries no personal data.
    ///
    /// The `-PingFrontSelfCheck` launch argument (debug builds) runs the same check and logs its line.
    public func selfCheck(timeout: Duration = .seconds(20)) async -> SetupCheckResult {
        if let problem = configurationProblem, case .invalidKey(let key) = problem.kind { return SetupCheck.result(forKeyProblem: key) }
        guard let engine else { return SetupCheckResult(code: "not_configured", advice: "Call PingFront.configure before selfCheck().") }
        return await engine.setupCheck(timeout: timeout)
    }

    /// Sends a bug report with an optional screenshot (PNG/JPEG/HEIC data).
    ///
    /// Adds the log tail and device state
    /// when the reports module is installed.
    public func reportBug(text: String, screenshot: Data? = nil) async throws(PingFrontError) {
        guard let engine else { throw .notConfigured }
        try await engine.reportBug(text: text, screenshots: screenshot.map { [$0] } ?? [])
    }

    /// Opens the bug report flow (screenshot and markup with the reports module, text otherwise).
    public func openReport(prefill: String? = nil) {
        if let reports = registry.reportPresenter {
            reports.presentReport(prefill: prefill)
        } else {
            registry.chatPresenter?.presentSimpleReport()
        }
    }

    // MARK: Lifecycle

    /// Logs the person out: forgets identity, traits and the thread on this device.
    ///
    /// The server is told
    /// (`POST /me/logout`, retried until it succeeds). The next session is a new guest.
    public func logout() {
        guard let engine else { return notConfigured("logout") }
        engine.submit(.logout)
    }

    /// Erases the person's data on the server (`DELETE /me`) and on this device.
    public func eraseMyData() async throws(PingFrontError) {
        guard let engine else { throw .notConfigured }
        try await engine.erase()
    }

    /// Everything pingfront stores about this person (`GET /me/export`), as the server's JSON.
    ///
    /// The result is a `PersonExport` (`format: pingfront.person.v1`): profile, devices, the thread with every
    /// message, moments, store events and plays. It carries no secrets, push tokens or the team's notes. Save or
    /// share the bytes as they are (for example as `pingfront-export.json`); the SDK shows no UI and keeps no copy.
    /// Image parts carry short-lived `url`s.
    ///
    /// Needs a session but no identity, so it may start one. Works for a blocked person. Limited to 5 an hour per
    /// install: past that it throws a rate-limited ``PingFrontError`` with scope ``RateScope/exports``, and further
    /// calls throw `coolingDown` until the wait is over.
    ///
    /// ```swift
    /// let json = try await PingFront.shared.exportMyData()
    /// try json.write(to: .documentsDirectory.appending(path: "pingfront-export.json"))
    /// ```
    public func exportMyData() async throws(PingFrontError) -> Data {
        guard let engine else { throw .notConfigured }
        return try await engine.exportMyData()
    }

    /// Events: chat opened/closed, messages, unread changes, offers, problems.
    ///
    /// Each access returns a new stream.
    public var events: AsyncStream<PingFrontEvent> { hub.stream() }

    /// Team actions your app has to do ("Fix it for them"): a teammate ran one from the inbox, for example to
    /// extend a trial or repair a sync.
    ///
    /// Each access returns a new stream. Actions not answered yet are replayed to it, and each action id arrives
    /// once per stream. Do the work, then call ``TeamAction/complete()`` or ``TeamAction/fail(message:)``.
    /// Pending actions are fetched after a session starts and whenever the live connection comes back, so one
    /// sent while the app was closed still arrives.
    ///
    /// ```swift
    /// for await action in PingFront.shared.teamActions {
    ///     switch action.actionId {
    ///     case "repair_sync":
    ///         await sync.repair()
    ///         await action.complete()
    ///     default:
    ///         await action.fail(message: "This version of the app can't do \(action.name).")
    ///     }
    /// }
    /// ```
    public var teamActions: AsyncStream<TeamAction> { teamActionHub.stream() }

    // MARK: UI hooks (package)

    /// The UI calls this when a chat appears or disappears: the SDK's sheet, or an embedded `PingFrontChatView`.
    ///
    /// Counted per presentation, so closing the sheet while an embedded chat shows leaves the chat visible (and
    /// `.chatOpened` / `.chatClosed` mark the first one appearing and the last one going).
    package func chatVisibilityChanged(_ visible: Bool, embedded: Bool = false) {
        if embedded {
            embeddedChats = max(embeddedChats + (visible ? 1 : -1), 0)
        } else {
            presentedChats = max(presentedChats + (visible ? 1 : -1), 0)
        }
        let nowVisible = embeddedChats + presentedChats > 0
        guard nowVisible != isChatVisible else { return }
        isChatVisible = nowVisible
        hub.emit(nowVisible ? .chatOpened : .chatClosed)
        if nowVisible { engine?.chatDidAppear() } else { engine?.chatDidDisappear() }
    }

    /// Chats on screen: the SDK's sheet (or a custom presenter's), and embedded `PingFrontChatView`s.
    @ObservationIgnored private var presentedChats = 0
    @ObservationIgnored private var embeddedChats = 0

    /// An embedded chat is on screen: opening the chat focuses it instead of presenting a second one.
    package var isEmbeddedChatVisible: Bool { embeddedChats > 0 }

    package func refreshLook() {
        let remote = engine?.remoteConfig ?? previewConfig
        let resolved = ResolvedLook.resolve(
            remote: remote, code: configuration.appearance, codeTopics: configuration.topics, host: registry.host)
        if resolved != look { look = resolved }
    }

    package func emit(_ event: PingFrontEvent) { hub.emit(event) }

    package var chatPresenter: (any ChatPresenting)? { registry.chatPresenter }
    package var offerHandler: (any OfferHandling)? { registry.offerHandler }
    package var reviewRequester: (any ReviewRequesting)? { registry.reviewRequester }
    /// The App Store id from the remote config, for review cards without a store URL.
    package var appStoreID: String? { engine?.remoteConfig?.appStoreId }
    package var storeActionHandler: (any StoreActionHandling)? { registry.storeActionHandler }
    /// Whether store action cards open Apple's sheets in the app (the StoreKit module is installed).
    package var canHandleStoreActions: Bool { registry.storeActionHandler != nil }
    /// The receipt line for a store change; the chat UI replaces it with its translations.
    @ObservationIgnored package var storeChangeText: @MainActor (StoreChange) -> String = StoreChange.englishText
    package var offerPricing: (any OfferPricing)? { registry.offerPricing }
    package var notificationsRequest: (@MainActor () async -> Bool)? { registry.notificationsRequest }
    package var reportPresenterForCapture: (any ReportPresenting)? { registry.reportPresenter }
    package var reportContextProvider: (any ReportContextProviding)? { registry.reportContext }
    package var entitlementSources: [any EntitlementSource] { registry.entitlementSources }
    package var offerSources: [any OfferSource] { registry.offerSources }
    package var hostApp: HostAppInfo? { registry.host }

    /// Names over the limit are refused with a log line, never cut silently.
    private static func checkedName(_ name: String?) -> String? {
        guard let name, TextLimit.count(name) > Limits.nameChars else { return name }
        Log.config(.error)?.error("identify: the name is longer than \(Limits.nameChars, privacy: .public) characters and was not sent.")
        return nil
    }

    private func notConfigured(_ call: String) {
        Log.config(.error)?.error(
            "\(call, privacy: .public) was called before PingFront.configure, or with a configuration problem. It was ignored.")
    }
}
