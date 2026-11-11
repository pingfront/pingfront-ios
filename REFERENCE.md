# pingfront iOS SDK: API reference

Every public symbol, generated from the compiler's symbol graphs (public symbols, Release, iOS) for each release.
Grouped by module; members are listed under their type. The guide is at https://pingfront.sh/docs/swift-api.

Public enums may gain cases in minor releases. They are `@nonexhaustive`, so from Swift 6.4 the compiler asks for `@unknown default` when you switch over one (write it on earlier compilers too); only `AppKey.Mode`, `PushEnvironment` and `PingFrontVersion` are frozen. Values that vendors or the server extend freely (`ErrorCode`, `RateScope`, `Entitlement.Source`) are structs with static members.

Types you only read (`Message`, `Author`, the cards, `TeamMember`, `PingFrontLogEntry` and the like) have no public initializer, so they can gain properties without breaking your build.

## PingFrontCore

### `Conversation`

```swift
@MainActor final class Conversation
```

The thread as observable state, plus the actions a chat UI needs. `PingFrontUI` renders it;
teams building their own UI can use it directly from `PingFront.shared.conversation`.

- `@nonexhaustive enum Phase`  
  Loading state of the thread.
- `@MainActor var awaitingApproval: Set<String> { get set }`  
  Offer cards whose purchase waits for approval (Ask to Buy, Strong Customer Authentication).
- `@MainActor func choose(_ option: ChoicesCard.Option, on card: ChoicesCard, in message: Message)`  
  Picks an option on a choices card.
- `@MainActor var composerInsertion: String? { get set }`  
  Text to put into the composer once (topic prefill, `openChat(topic:)`).  The UI clears it.
- `@MainActor func cooldownRemaining(_ scope: RateScope) -> Duration?`  
  Time left on a cooldown, or `nil`.
- `@MainActor func discard(_ message: PendingMessage)`  
  Removes a failed message from the queue.
- `@MainActor func displayAuthor(of message: Message) -> Author`  
  The author as the chat shows it now: a teammate's current name and photo from ``team`` (they can change both in the dashboard), falling back to what the message carried when it was sent.
- `@MainActor var draft: String { get set }`  
  The person's unsent text.  Persisted between launches.
- `@MainActor var hasOlder: Bool { get set }`  
  True when older messages can be loaded.
- `@MainActor init()`  
  An empty conversation.
- `@MainActor var isEmpty: Bool { get }`  
  True when the thread has no messages and nothing is pending (show the welcome).
- `@MainActor var isLoadingOlder: Bool { get set }`  
  True while older messages are loading.
- `@MainActor var isOffline: Bool { get }`  
  True when the device looks offline.
- `@MainActor var isServerUnreachable: Bool { get }`  
  True when the chat can't reach its service although the device is online.  The service is down, a firewall, a captive portal: the chat says it can't reach the chat instead of "You're offline". Messages still wait in the outbox and go when it is back. Set by a request that failed to find the host or to connect to it (`PingFrontError.isServerUnreachable`); never by a server error (a 5xx is an answer), a timeout or the live socket alone; cleared by the next request to the service that gets through, or when the live socket connects.
- `@MainActor var lastPersonItemId: String? { get set }`  
  The timeline row id of the newest message the person wrote (for "Delivered" and "Read").
- `@MainActor var lastPersonSeq: Int? { get set }`  
  The seq of the newest message the person wrote.
- `@MainActor var live: LiveState { get set }`  
  The live channel state.
- `@MainActor func loadOlder()`  
  Loads the previous page (call when the top of the list appears).  Stops at the in-memory window.
- `@MainActor func markRead()`  
  Marks every message on screen as read, for a chat UI of your own.  The SDK's own chat does this by itself while it is visible. A custom UI calls it when the person has seen the thread (for example when it appears, and when new messages arrive while it shows): the team sees Read, and `PingFront.shared.unreadCount` drops to 0. Nothing is sent when there is nothing to mark, or while the app is paused.
- `@MainActor var messages: [Message] { get set }`  
  Messages in sequence order.
- `@MainActor func open(_ card: Card, in message: Message)`  
  Opens a card's action (offer, review, link, report).
- `@MainActor var pending: [PendingMessage] { get set }`  
  Messages the person sent that the server has not acknowledged.
- `@MainActor var phase: Phase { get set }`  
  Loading state.
- `@MainActor func photoData(for photo: PendingMessage.Photo) async -> Data?`  
  The JPEG bytes of a photo that is still waiting to be sent.
- `@MainActor var policy: SendPolicy { get set }`  
  Whether the person can send.
- `@MainActor func rate(_ rating: Int, on card: RatingCard, in message: Message)`  
  Rates on a rating card, clamped to the card's scale (`1...card.scale`).
- `@MainActor func refreshedURL(for image: ImagePart) async -> URL?`  
  A fresh URL for an image whose short-lived URL expired.
- `@MainActor func reload()`  
  Reloads the thread.
- `@MainActor func reload() async`  
  Reloads the thread and returns when the reload has finished.  When it failed, `phase` says why (`.failed`) for a thread with nothing to show; a thread already on screen stays. For pull to refresh in a custom UI:  ```swift List(conversation.timeline) { … }     .refreshable { await conversation.reload() } ```
- `@MainActor var replyExpectation: String? { get set }`  
  The server's reply expectation, already localized.
- `@MainActor func retry(_ message: PendingMessage)`  
  Retries a failed message with the same idempotency key.
- `@MainActor func send(text: String, photos: [Data] = [])`  
  Sends text and photos (any image data; re-encoded as JPEG ≤ 2 MB, ≤ 2400 px).  Returns immediately; the message shows as pending and is delivered by the outbox, also after relaunch.
- `@MainActor func setTyping(_ on: Bool)`  
  Tells the team the person is typing (throttled to one event per 3 s).
- `@MainActor var status: ThreadStatus { get set }`  
  Open or resolved.
- `@MainActor var supersededOfferCardIds: Set<String> { get set }`  
  Offer cards a newer offer card replaced: shown as one line, never stacked.
- `@MainActor var team: [TeamMember] { get set }`  
  The team, for the header and welcome.
- `@MainActor var teamReadSeq: Int { get set }`  
  The highest sequence number the team has read.
- `@MainActor var timeline: [TimelineItem] { get set }`  
  The timeline the UI renders: messages and pending sends, grouped.  Rebuilt when they change, never while a view renders.
- `@MainActor var typing: TypingIndicator? { get set }`  
  Who is typing right now.
- `case failed(PingFrontError)`  
  Loading failed and nothing is cached.
- `case idle`  
  Nothing loaded yet.
- `case loading`  
  Loading the latest page.
- `case ready`  
  Loaded (possibly from cache while offline).

### `ModuleContext`

```swift
@MainActor final class ModuleContext
```

The registration surface handed to each module's `install` closure.

- `@MainActor func addEntitlementSource(_ source: any EntitlementSource)`  
  Adds an entitlement source.  Its updates are forwarded like `setEntitlement(_:)`.
- `@MainActor func addOfferSource(_ source: any OfferSource)`  
  Adds a source of offer slots.
- `@MainActor func onLocalDataWipe(_ handler: @escaping @MainActor () -> Void)`  
  Runs `handler` whenever the SDK wipes the person's local data: `logout()`, `eraseMyData()` or a revoked session.  Modules drop per-person state here (cached tokens, observers).
- `@MainActor let pingFront: PingFront`  
  The SDK.
- `@discardableResult @MainActor func reportStoreEvent(_ event: StoreEventReport) async -> MomentResult`  
  Reports a store detection.  It is sent only when a live play listens to that store event, and only once a session exists or the event creates one (`reason: moment`).
- `@MainActor func run(_ operation: @escaping @MainActor () async -> Void)`  
  Runs a long-lived operation owned by the SDK.  It is cancelled on logout-free teardown (reconfigure).
- `@MainActor func setChatPresenter(_ presenter: any ChatPresenting)`  
  Sets the chat presenter (`PingFrontUI` does this).
- `@MainActor func setHostApp(name: String, accent: PingFrontColor?, iconPNG: Data?)`  
  Reports the host app's name, AccentColor and icon (inferred look, and `hostLook` for the dashboard).
- `@MainActor func setHostIcon(_ png: Data)`  
  Adds the host app icon once it is rendered (128 px PNG).  The chat and the dashboard's `hostLook` pick it up.
- `@MainActor func setNotificationsRequest(_ request: @escaping @MainActor () async -> Bool)`  
  Lets the chat offer "Turn on notifications" after the person's first message.  The push module sets it; it should ask permission the way the host app approved.
- `@MainActor func setOfferHandler(_ handler: any OfferHandling)`  
  Sets the offer handler used when the app has not set `onOffer`.
- `@MainActor func setOfferPricing(_ pricing: any OfferPricing)`  
  Supplies store prices for offer cards (the regular price, and the offer price when there is one).
- `@MainActor func setReportContextProvider(_ provider: any ReportContextProviding)`  
  Sets the report context provider (log tail, device state).
- `@MainActor func setReportPresenter(_ presenter: any ReportPresenting)`  
  Sets the full report flow.
- `@MainActor func setReviewRequester(_ requester: any ReviewRequesting)`  
  Sets the native review prompt.
- `@MainActor func setStoreActionHandler(_ handler: any StoreActionHandling)`  
  Opens Apple's App Store sheets for store action cards.
- `@MainActor func signPromotionalOffer(productId: String, offerId: String) async throws(PingFrontError) -> PromotionalOfferSignature`  
  Asks the server to sign an App Store promotional offer for this person (`POST /offers/signature`).

### `PingFront`

```swift
@MainActor final class PingFront
```

The pingfront SDK: in-app support chat and proactive messages ("pings").

```swift
import PingFront
PingFront.configure("pk_live_…")
PingFront.shared.identify(userId: user.id, name: user.name, email: user.email)
PingFront.shared.openChat()
```

A new install sends nothing at configure or launch (one with a session from an earlier launch may
check unread messages and report store lapses). A session is created lazily on the first chat open,
listened moment, push open, bug report or `prepare()`.

- `typealias Appearance = ChatAppearance`  
  Look values set in code.
- `typealias Configuration = PingFrontConfiguration`  
  Options for `configure(_:_:)`.
- `typealias LogLevel = PingFrontLogLevel`  
  How much the SDK logs.
- `@MainActor func closeChat()`  
  Closes the SDK-presented chat.  A chat the app presents with `.pingFrontChat(isPresented:)` is the app's to close, through its binding.
- `@MainActor func closeChat() async`  
  Closes the chat the SDK presented and returns once it is gone.  Returns at once when the SDK presented no chat, even while the app shows an embedded `PingFrontChatView` or a chat it presents with `.pingFrontChat(isPresented:)`: the app closes those itself (removing the view, or setting the binding to false). With the SDK's own sheet it returns when the sheet's dismissal has finished, the sheet and anything over it (a photo picker, a bug report). A custom presenter (`ChatPresenting`) is asked to dismiss whenever it says it presents a chat (`isPresentingChat`, true unless it says otherwise); then the call waits for the chat's `.chatClosed`, at most two seconds. For bridges (React Native, Flutter) that chain presentations. Android's equivalent is `closeChatAndWait()` (Kotlin can't overload on `suspend` alone).
- `@MainActor var configurationProblem: ConfigurationProblem? { get set }`  
  The problem found at configure time, or `nil`.  In debug builds the chat shows it in a red banner.
- `@MainActor let conversation: Conversation`  
  The thread state and actions, for the built-in UI or your own.
- `@MainActor func eraseMyData() async throws(PingFrontError)`  
  Erases the person's data on the server (`DELETE /me`) and on this device.
- `@MainActor var events: AsyncStream<PingFrontEvent> { get }`  
  Events: chat opened/closed, messages, unread changes, offers, problems.  Each access returns a new stream.
- `@MainActor func exportMyData() async throws(PingFrontError) -> Data`  
  Everything pingfront stores about this person (`GET /me/export`), as the server's JSON.  The result is a `PersonExport` (`format: pingfront.person.v1`): profile, devices, the thread with every message, moments, store events and plays. It carries no secrets, push tokens or the team's notes. Save or share the bytes as they are (for example as `pingfront-export.json`); the SDK shows no UI and keeps no copy. Image parts carry short-lived `url`s.  Needs a session but no identity, so it may start one. Works for a blocked person. Limited to 5 an hour per install: past that it throws a rate-limited ``PingFrontError`` with scope ``RateScope/exports``, and further calls throw `coolingDown` until the wait is over.  ```swift let json = try await PingFront.shared.exportMyData() try json.write(to: .documentsDirectory.appending(path: "pingfront-export.json")) ```
- `@discardableResult @MainActor func handle(_ url: URL) -> Bool`  
  Opens the chat, or the bug report, from a chat link your app received; returns `true` when it was one.  A chat link is any URL your app routes here whose query has `pingfront=chat` or `pingfront=report`, on your own universal link domain or custom scheme (`https://example.com/help?pingfront=chat`, `myapp://support?pingfront=chat&topic=billing`). The SDK claims no domain or scheme of its own. `topic` is used only when it is the id of one of the chat's topics; other parameters are ignored, and a link never puts text in the composer. Returns `false` for every other URL, so route those yourself.  Handling a link is the same as ``openChat(topic:)`` or ``openReport(prefill:)``: the session starts when the chat appears, and this call sends nothing. Before `configure` the link is kept in memory (the last one wins) and applied once, right after `configure`.  ```swift WindowGroup { ContentView() }     .onOpenURL { url in         if PingFront.shared.handle(url) { return }         router.open(url)     } ```
- `@MainActor func handleBackgroundPush(userInfo: [AnyHashable : Any]) async -> BackgroundPushResult?`  
  Handles a silent pingfront push (`content-available: 1`, no alert) in the background.  For example a new chat look (`kind: config`). Call it from `application(_:didReceiveRemoteNotification:)` and return its result to the system (the push module maps it to `UIBackgroundFetchResult`).  Shows nothing and never starts a session: it refreshes only for an install that already has one. Returns `nil` for pushes that aren't pingfront's.
- `@discardableResult @MainActor func handlePush(userInfo: [AnyHashable : Any]) -> Bool`  
  Handles a notification tap.  Returns `true` when it was a pingfront notification. Message and ping notifications open the chat; payload versions or kinds this SDK does not know are ignored.
- `@MainActor func identify(token: String)`  
  Verifies the person with an HS256 token signed by your backend (claims: `sub`, `iat`, `exp` at most 24 hours after `iat`, optional `name`/`email`).  Verified people get one thread across devices and reinstalls.
- `@MainActor func identify(userId: String, name: String? = nil, email: String? = nil)`  
  Names the person.  Unverified: the person keeps one thread per install until verified.
- `@MainActor var isChatVisible: Bool { get set }`  
  True while the chat is on screen (sheet or embedded view).
- `@MainActor var isConfigured: Bool { get set }`  
  True after a successful `configure`.
- `@MainActor func isPingFrontPush(userInfo: [AnyHashable : Any]) -> Bool`  
  True for pingfront notification payloads.
- `@MainActor var isTestDevice: Bool { get set }`  
  True when the dashboard marked this device as a test device (it previews draft looks).
- `@MainActor var language: String? { get set }`  
  The chat's language when your app has its own language picker: a BCP 47 tag such as `"de"` or `"pt-BR"`.  `nil` (the default) follows the app's and the system's language. The chat UI, the SDK's own strings, the team's localized texts and the language the server writes in all follow it. Set it again whenever the person picks a language; an invalid tag is ignored and logged.
- `@MainActor func logout()`  
  Logs the person out: forgets identity, traits and the thread on this device.  The server is told (`POST /me/logout`, retried until it succeeds). The next session is a new guest.
- `@MainActor var look: ResolvedLook { get set }`  
  The resolved chat look (remote > code > host app > defaults).
- `@discardableResult @MainActor func moment(_ name: String, props: [String : MomentValue] = [:]) async -> MomentResult`  
  Reports an app moment (`paywall_closed`, `trial_cancelled`, …).  Only moments a play listens to are sent (the list is cached for 5 minutes). When the server answers `open`, the chat is presented.
- `@MainActor var onLink: (@MainActor (URL) async -> Bool)?`  
  Called for every link the person taps in the chat (message text, link cards).  Return `true` when you handled it (for example a deep link into your app); otherwise web links open in an in-app Safari view and other links through the system.  It may be `async` (a bridge waiting for JavaScript or Dart, a router that loads first) or a plain closure. The SDK waits for the answer at most 10 seconds, as for ``onScreen``: no answer by then counts as `false`, the handler is cancelled and its late answer ignored, and the link opens the default way. A link card reports what really happened: opened, or failed with `cannot_open` when the default way opened nothing either. A newer link tapped in a message replaces one still waiting, and `logout()` cancels a wait.  ```swift PingFront.shared.onLink = { url in     guard url.scheme == "myapp" else { return false }     return await router.open(url) } ```
- `@MainActor var onOffer: (@MainActor (OfferRequest) -> Void)?`  
  Called when the person taps an offer card.  Show your paywall or promo for `request.offerId`. When unset, a registered offer module (for example `.storeKit`) handles it.
- `@MainActor var onScreen: (@MainActor (LinkScreen) async -> Bool)?`  
  Called when the person taps a link card that opens a screen of your app (a saved link the team sent).  Only for screens this build registered with ``registerScreens(_:)``. Open the screen for `screen.id` with `screen.params` and return `true`; return `false` when you can't, and the team sees the link as failed. A card for a screen this build didn't register opens its URL instead, when it has one.  It may be `async` (a bridge waiting for JavaScript or Dart, a router that loads first) or a plain closure. The SDK waits for the answer before it reports the tap, at most 10 seconds: no answer by then counts as `false`, as on Android.  ```swift PingFront.shared.registerScreens([AppScreen(id: "settings.sound", title: "Sound settings")]) PingFront.shared.onScreen = { screen in     router.open(screen.id, params: screen.params) } ```
- `@MainActor func openChat(topic: ChatTopic? = nil)`  
  Presents the chat sheet.  With a topic, its prefill goes into the composer (or it starts the thread on that topic). While an embedded `PingFrontChatView` is on screen, there is never a second chat: it focuses that one's composer instead (so do chat links, push taps and moments, which open the chat this way).
- `@MainActor func openLinkByDefault(_ url: URL) async -> Bool`  
  Opens a link the way the chat does when `onLink` declines it, and says whether something opened it.  The SDK calls it itself after `onLink` declines a link card's URL; apps with their own chat UI on ``conversation`` can call it too. The link card URL rule first (https://pingfront.sh/docs/chat-links), then Safari for `http` and `https`, or the system for one of the app's own schemes (`CFBundleURLSchemes`). Any other URL, and a `javascript:`, `data:`, `vbscript:`, `file:`, `blob:`, `about:`, `content:` or `intent:` one, opens nothing and returns `false`.
- `@MainActor func openReport(prefill: String? = nil)`  
  Opens the bug report flow (screenshot and markup with the reports module, text otherwise).
- `@MainActor var person: PersonSummary? { get set }`  
  The person, once a session exists.
- `@MainActor func prepare() async throws(PingFrontError)`  
  Creates the session now instead of lazily (for example right after login, to receive pings sooner).
- `@MainActor func pushReceived(userInfo: [AnyHashable : Any])`  
  Updates the unread count from a pingfront notification that arrived while the app is open.  The push module and `notificationPresentation(for:)` call this for you.
- `@MainActor func registerScreens(_ screens: [AppScreen])`  
  Registers the screens of your app that the team's saved links can open (https://pingfront.sh/docs/offers#saved-links).  Call it once at launch, before or after `configure`, with every screen your router can open; calling it again replaces the list (`[]` says this build registers none). Ids must match `^[A-Za-z0-9][A-Za-z0-9_./:-]{0,99}$`: a debug build stops on a bad id, a release build drops it. At most 200 screens, each id once (the first wins).  The list never makes a request of its own: it goes out with the next session the SDK starts, and on a refresh or profile update only when the list or the app version changed. A tap on a link card for one of these screens calls ``onScreen``.
- `@MainActor func reportBug(text: String, screenshot: Data? = nil) async throws(PingFrontError)`  
  Sends a bug report with an optional screenshot (PNG/JPEG/HEIC data).  Adds the log tail and device state when the reports module is installed.
- `@MainActor func selfCheck(timeout: Duration = .seconds(20)) async -> SetupCheckResult`  
  Checks the setup end to end: creates the session if needed, sends "Setup check from <app>" to your inbox, and waits for the server (at most `timeout`).  The result says what to fix; it carries no personal data.  The `-PingFrontSelfCheck` launch argument (debug builds) runs the same check and logs its line.
- `@MainActor func setEntitlement(_ entitlement: Entitlement)`  
  Reports the person's subscription state.
- `@MainActor func setOffers(_ offers: [OfferSlot])`  
  Reports the offers the app can show, so the team can send offer cards for them.  Slots are grouped by `source` (`.app` when unset): each group replaces that source's earlier slots, and other sources' slots (`.storeKit(products:)`, vendor adapters) stay. An empty list clears the app's own slots. To withdraw a module's slots, use `setOffers(_:from:)` with an empty list.
- `@MainActor func setOffers(_ offers: [OfferSlot], from source: OfferSlot.Source)`  
  Reports the offers one source can show, replacing only that source's earlier slots.  Modules and vendor adapters call this; every slot is stamped with `source`. Pass an empty list to withdraw the source's slots.
- `@MainActor func setPushToken(_ token: Data?)`  
  Forwards the APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.  Pass `nil` to clear it (the person turned notifications off, or the app unregistered): the server stops sending pushes to this install.
- `@MainActor func setTraits(_ traits: [String : String])`  
  Adds or updates traits (merged; at most 30, keys ≤ 64, values ≤ 512 characters).
- `@MainActor static let shared: PingFront`  
  The shared instance.
- `@MainActor func start(appKey rawKey: String? = nil, configuration: PingFrontConfiguration = PingFrontConfiguration())`  
  Starts the SDK with an app key and a configuration: the one setup entry point.  Apps on the `PingFront` product call `PingFront.configure(_:_:)`, which adds the chat UI and calls this. Apps that use `PingFrontCore` alone (their own UI on `conversation`) call it directly:  ```swift var config = PingFrontConfiguration() config.logLevel = .debug PingFront.shared.start(appKey: "pk_live_…", configuration: config) ```  Pass `nil` to read `PingFrontAppKey` from Info.plist. The key is checked offline; nothing is sent.
- `@MainActor var storeAccountToken: UUID? { get set }`  
  The person's store account token, once a session exists.  Pass it as `appAccountToken` in your own StoreKit purchases (`.appAccountToken(token)`) so App Store notifications match this person. The `.storeKit` module does this for purchases from offer cards.
- `@MainActor var teamActions: AsyncStream<TeamAction> { get }`  
  Team actions your app has to do ("Fix it for them"): a teammate ran one from the inbox, for example to extend a trial or repair a sync.  Each access returns a new stream. Actions not answered yet are replayed to it, and each action id arrives once per stream. Do the work, then call ``TeamAction/complete()`` or ``TeamAction/fail(message:)``. Pending actions are fetched after a session starts and whenever the live connection comes back, so one sent while the app was closed still arrives.  ```swift for await action in PingFront.shared.teamActions {     switch action.actionId {     case "repair_sync":         await sync.repair()         await action.complete()     default:         await action.fail(message: "This version of the app can't do \(action.name).")     } } ```
- `@MainActor var unreadCount: Int { get set }`  
  Unread team messages.  Observable: use it for a badge.
- `@MainActor var usesAppBadge: Bool { get }`  
  True when the dashboard turned on the app icon badge (`features.appBadge`).  Off by default: the badge belongs to your app, and pingfront never touches it unless you opt in.

### `AppKey`

```swift
struct AppKey
```

A public app key that passed the offline checksum.

- `enum Mode`  
  Whether the key belongs to the live or the test environment.
- `var description: String { get }`  
  The key with its body masked, safe to show in logs and banners.
- `let mode: Mode`  
  `live` or `test`.
- `static func parse(_ key: String) -> Result<AppKey, KeyCheckError>`  
  Validates `key` offline with the CRC-32 check characters.  No network.
- `let rawValue: String`  
  The full key string, for example `pk_live_…`.
- `case live`
- `case test`

### `AppScreen`

```swift
struct AppScreen
```

A screen of your app that a saved link can open (`AppScreen` in the protocol).

Register them with `PingFront.registerScreens(_:)`. The team picks one in the dashboard and sends it as a link
card; the person's tap reaches your `onScreen` handler with the id and the link's parameters.

- `var id: String`  
  Your app's own route id: `^[A-Za-z0-9][A-Za-z0-9_./:-]{0,99}$` (`"settings.sound"`, `"plans/yearly"`).
- `init(id: String, title: String? = nil)`  
  Creates a screen.
- `var title: String?`  
  What the team sees in the dashboard ("Sound settings").  At most 60 characters; never shown to the person.

### `Author`

```swift
struct Author
```

Who wrote a message.

- `@nonexhaustive enum Kind`  
  The kind of author.
- `var avatarURL: URL?`  
  Avatar image URL.
- `var id: String?`  
  Team member id.
- `var kind: Kind`  
  Person, team, AI or system.
- `var name: String?`  
  Display name.
- `case ai`
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.unknown`.
- `case person`
- `case system`
- `case team`
- `case unknown`  
  The server sent a kind this SDK does not know; shown like a team message.

### `CardKind`

```swift
struct CardKind
```

A card kind, as on the wire (`offer`, `review`, …).

Open: kinds added later keep their wire name.

- `static let choices: CardKind`  
  Quick choices.
- `var description: String { get }`  
  The wire name.
- `init(rawValue: String)`  
  A kind from its wire name.
- `static let link: CardKind`  
  A link or deep link.
- `static let offer: CardKind`  
  An offer card.
- `static let rating: CardKind`  
  A rating (CSAT).
- `let rawValue: String`  
  The wire name.
- `static let report: CardKind`  
  Report a problem.
- `static let review: CardKind`  
  A review ask.
- `static let storeAction: CardKind`  
  One of Apple's App Store sheets.

### `CardPart`

```swift
struct CardPart
```

A card part: the card plus its result once acted on.

- `var card: Card`  
  The card.
- `var result: CardResult?`  
  Set once the person acted.

### `CardResult`

```swift
struct CardResult
```

The final state of a card the person acted on, filled by the server.

- `var answer: CardAnswer?`  
  The answer, for choices and rating cards.
- `var at: Date`  
  When the person acted.
- `var choiceId: String? { get }`  
  The chosen option id, for choices cards.
- `func encode(to encoder: any Encoder) throws`  
  Encodes `{ at, choiceId?, rating? }`.
- `init(from decoder: any Decoder) throws`  
  Decodes `{ at, choiceId?, rating? }`.
- `var rating: Int? { get }`  
  The rating, for rating cards.

### `ChatAppearance`

```swift
struct ChatAppearance
```

Look values set in code with `config.appearance`.

Every field is optional; unset fields fall
through to values inferred from the host app, then SDK defaults. The published remote look wins over these.

- `var accent: PingFrontColor?`  
  Person's bubbles and buttons.  Default: the app's AccentColor asset.
- `var aiName: String?`  
  The assistant's display name.
- `var allowsPhotos: Bool?`  
  Allow photos.
- `var allowsReports: Bool?`  
  Allow bug reports.
- `var background: PingFrontColor?`  
  Chat background.
- `var composerPlaceholder: String?`  
  Composer placeholder.
- `var corners: ChatLook.Corners?`  
  Bubble corners.
- `var density: ChatLook.Density?`  
  Spacing density.
- `var font: ChatLook.FontStyle?`  
  System, rounded or serif.
- `var headerMemberId: String?`  
  Which teammate the person header shows.
- `var headerStyle: ChatLook.HeaderStyle?`  
  Header style.
- `var headerTitle: String?`  
  Header title for team and app styles.
- `init()`  
  Nothing set.
- `var replyExpectation: String?`  
  For example "Usually replies within a few hours".
- `var scheme: ChatLook.Scheme?`  
  Force light or dark, or follow the system.
- `var showsAvatars: Bool?`  
  Show team avatars beside messages.
- `var showsLocalTime: Bool?`  
  Show the teammate's local time.
- `var showsNames: Bool?`  
  Show author names.
- `var showsReplyExpectation: Bool?`  
  Show the reply expectation line.
- `var showsWelcomeFaces: Bool?`  
  Show team faces on the welcome screen.
- `var teamBubble: PingFrontColor?`  
  Team bubble fill.
- `var timestamps: ChatLook.Timestamps?`  
  Timestamps per group or per message.
- `var welcomeBody: String?`  
  Welcome body.
- `var welcomeTitle: String?`  
  Welcome title.

### `ChatLook`

```swift
struct ChatLook
```

The chat look as configured in the dashboard (the protocol's `ChatLook`).

Fields keep "unset" as `nil` so code configuration can fill them; `ResolvedLook` applies defaults.

- `struct Composer`  
  Composer options.
- `struct Header`  
  Header options.
- `struct Messages`  
  Message list options.
- `struct Theme`  
  Colors and type.
- `struct Topic`  
  A topic chip.
- `struct Welcome`  
  Welcome (empty state) options.
- `@nonexhaustive enum Corners`  
  Bubble corners: round 18, soft 12, square 6 pt.
- `@nonexhaustive enum Density`  
  Spacing density.
- `@nonexhaustive enum FontStyle`  
  Font design.
- `@nonexhaustive enum HeaderStyle`  
  Header style: one face, stacked team faces, or the app icon.
- `@nonexhaustive enum Scheme`  
  Color scheme preference.
- `@nonexhaustive enum Timestamps`  
  Timestamps under each group or under every message.
- `var aiName: String?`  
  The assistant's display name.  AI replies are always labelled.
- `var composer: ChatLook.Composer`  
  Composer options.
- `var header: ChatLook.Header`  
  Header options.
- `init()`  
  A look with nothing set.
- `init(from decoder: any Decoder) throws`  
  Decodes the wire format; values this SDK version does not know are kept as unknown.
- `var messages: ChatLook.Messages`  
  Message list options.
- `var replyExpectation: LocalizedText?`  
  For example "Usually replies within a few hours".
- `var theme: ChatLook.Theme`  
  Colors and type.
- `var topics: [Topic]`  
  Up to six topics.  An empty list counts as unset.
- `var welcome: ChatLook.Welcome`  
  Welcome options.
- `init()`  
  Nothing set.
- `init(from decoder: any Decoder) throws`  
  Decodes each field on its own; a bad value drops only that field.
- `var photos: Bool?`  
  Allow photos.
- `var placeholder: LocalizedText?`  
  Placeholder text.
- `var reports: Bool?`  
  Allow bug reports.
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.round`.
- `case round`
- `case soft`
- `case square`
- `case comfortable`
- `case compact`
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.comfortable`.
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.system`.
- `case rounded`
- `case serif`
- `case system`
- `init()`  
  Nothing set.
- `init(from decoder: any Decoder) throws`  
  Decodes each field on its own; a bad value drops only that field.
- `var memberId: String?`  
  The teammate the person header shows.
- `var showLocalTime: Bool?`  
  Show the teammate's local time.
- `var showReplyExpectation: Bool?`  
  Show the reply expectation.
- `var style: HeaderStyle?`  
  One face, the team, or the app icon.
- `var title: LocalizedText?`  
  Title for the team and app styles.
- `case app`
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.person`.
- `case person`
- `case team`
- `init()`  
  Nothing set.
- `init(from decoder: any Decoder) throws`  
  Decodes each field on its own; a bad value drops only that field.
- `var showAvatars: Bool?`  
  Show team avatars beside messages.
- `var showNames: Bool?`  
  Show author names.
- `var timestamps: Timestamps?`  
  Timestamps per group or per message.
- `case auto`
- `case dark`
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.auto`.
- `case light`
- `var accent: PingFrontColor?`  
  Person's bubbles and buttons.
- `var background: PingFrontColor?`  
  Chat background.
- `var corners: Corners?`  
  Bubble corners.
- `var density: Density?`  
  Spacing density.
- `var font: FontStyle?`  
  Font design.
- `init()`  
  Nothing set.
- `init(from decoder: any Decoder) throws`  
  Decodes each field on its own; a bad value drops only that field.
- `var scheme: Scheme?`  
  Light, dark or automatic.
- `var teamBubble: PingFrontColor?`  
  Team bubble fill.
- `case always`
- `case grouped`
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.grouped`.
- `var id: String`  
  Topic id.
- `var label: LocalizedText`  
  Chip label.
- `var prefill: LocalizedText?`  
  Composer prefill; without one the chip starts the thread.
- `var symbol: TopicSymbol`  
  Chip symbol.
- `var body: LocalizedText?`  
  Welcome body.
- `init()`  
  Nothing set.
- `init(from decoder: any Decoder) throws`  
  Decodes each field on its own; a bad value drops only that field.
- `var showFaces: Bool?`  
  Show team faces.
- `var title: LocalizedText?`  
  Welcome title.

### `ChatTopic`

```swift
struct ChatTopic
```

A topic chip on the welcome screen.

Use a preset (`.billing`, `.bug`, `.idea`, …) or `init(id:label:symbol:prefill:)`.

- `static let account: ChatTopic`  
  "Get help with my account".
- `static let billing: ChatTopic`  
  "Ask about billing".
- `static let bug: ChatTopic`  
  "Report a bug".
- `static let defaults: [ChatTopic]`  
  The default topics: Ask about billing, Report a bug, Share an idea.
- `static let feedback: ChatTopic`  
  "Send feedback".
- `static let gift: ChatTopic`  
  "Ask about gifts".
- `var id: String`  
  Stable id (`[a-z0-9_-]{1,32}`).
- `static let idea: ChatTopic`  
  "Share an idea".
- `init(id: String, label: LocalizedText?, symbol: TopicSymbol, prefill: LocalizedText? = nil)`  
  Creates a custom topic.
- `init(id: String, label: String, symbol: TopicSymbol = .other, prefill: String? = nil)`  
  Creates a custom topic with a single-language label (localize it yourself with `String(localized:)`).
- `var label: LocalizedText?`  
  The label. `nil` uses the SDK's built-in, translated label for the preset id.
- `var prefill: LocalizedText?`  
  With a prefill, tapping the chip fills the composer.  Without one, tapping starts the thread on that topic.
- `static let privacy: ChatTopic`  
  "Ask about privacy".
- `static let question: ChatTopic`  
  "Ask a question".
- `static let restore: ChatTopic`  
  "Restore purchases".
- `var symbol: TopicSymbol`  
  The chip symbol.

### `ChoicesCard`

```swift
struct ChoicesCard
```

A choices card: the person picks one option.

- `struct Option`  
  One option.
- `var id: String`  
  Card id.
- `var options: [Option]`  
  Two to six options.
- `var id: String`  
  Option id.
- `var label: String`  
  Label.

### `ConfigurationProblem`

```swift
struct ConfigurationProblem
```

A configuration problem found at configure time.

In debug builds the chat shows it in a red banner.

- `@nonexhaustive enum Kind`  
  What kind of problem.
- `var description: String { get }`  
  The message.
- `let disablesSDK: Bool`  
  True when the SDK disabled itself because of it.
- `let kind: Kind`  
  What kind of problem.
- `let message: String`  
  The exact problem and what to do, in plain words.
- `case appPaused`  
  The app is paused in the dashboard.
- `case invalidKey(KeyProblem)`  
  The app key failed the offline check.
- `case keychain`  
  The Keychain refused to store the install (usually an unsigned build or a missing entitlement): every launch starts a new guest and the thread looks empty.
- `case missingKey`  
  No key was passed and `PingFrontAppKey` is not in Info.plist.
- `case offerHandler`  
  An offer card arrived but nothing can show offers (no `onOffer`, no store module).
- `case option`  
  Another option is wrong.
- `case unknownKey`  
  The server does not know the key (found later, at the first request).

### `Entitlement`

```swift
struct Entitlement
```

The person's subscription state, as the app or a store module knows it.

- `struct Source`  
  Where the entitlement came from.  A struct, so vendor adapters can name their own source without an SDK update.
- `@nonexhaustive enum State`  
  Subscription lifecycle states.
- `var environment: String?`  
  The store environment of the purchase behind it ("production", "sandbox", "xcode"); `nil` when the store did not say or the app set it.
- `var expiresAt: Date?`  
  The end of the current period: when access ends (cancelled) or ended (expired).
- `var gracePeriodEndsAt: Date?`  
  The day access ends unless the payment is fixed (grace, billing retry).
- `var hasPaymentIssue: Bool { get }`  
  True when the plan has a payment problem the person can fix (grace or billing retry).
- `init(state: State, productId: String? = nil, renewsAt: Date? = nil, expiresAt: Date? = nil, gracePeriodEndsAt: Date? = nil, source: Source? = .app)`  
  Creates an entitlement value.
- `var isTestPurchase: Bool { get }`  
  True for a test purchase (TestFlight, a sandbox account, StoreKit testing): any environment other than production.
- `var productId: String?`  
  The product that grants it.
- `var renewsAt: Date?`  
  The next renewal while it auto-renews (trial, active).
- `var source: Source?`  
  Which system reported it.
- `var state: State`  
  Current state.
- `static let adapty: Entitlement.Source`  
  Adapty.
- `static let app: Entitlement.Source`  
  Your app, through `setEntitlement(_:)`.
- `var description: String { get }`  
  The source name.
- `init(rawValue: String)`  
  Wraps a source name.
- `static let play: Entitlement.Source`  
  Google Play Billing.
- `let rawValue: String`  
  The source name.
- `static let revenuecat: Entitlement.Source`  
  RevenueCat.
- `static let storekit: Entitlement.Source`  
  StoreKit 2.
- `static let stripe: Entitlement.Source`  
  Stripe.
- `static let superwall: Entitlement.Source`  
  Superwall.
- `case active`
- `case billingRetry`
- `case cancelled`
- `case expired`
- `case grace`
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.unknown`.
- `case lifetime`
- `case none`
- `case trial`
- `case unknown`  
  A state this SDK version does not know. Never sent.

### `ErrorCode`

```swift
struct ErrorCode
```

A server error code: the `ErrorCode` the API returns (https://pingfront.sh/docs/errors).

Unknown codes are kept verbatim.

- `static let appPaused: ErrorCode`  
  403: the app is paused in the dashboard.
- `static let blocked: ErrorCode`  
  403: the person is blocked.
- `static let conflict: ErrorCode`  
  409: a conflicting state (for example a promotional offer for an app without an In-App Purchase key).
- `var description: String { get }`  
  The raw code.
- `static let identityUserMismatch: ErrorCode`  
  409: the identity token belongs to a different user.
- `init(rawValue: String)`  
  Wraps a raw code string.
- `static let invalidAppKey: ErrorCode`  
  401: the server does not know this app key.
- `static let invalidRequest: ErrorCode`  
  422: the request did not match the schema.
- `static let notFound: ErrorCode`  
  404.
- `static let rateLimited: ErrorCode`  
  429: see `scope` and `retryAfter`.
- `let rawValue: String`  
  The code as sent by the server.
- `static let sessionRevoked: ErrorCode`  
  401: the install secret was revoked; local state must be wiped.
- `static let threadReset: ErrorCode`  
  409: the thread was reset; reload it.
- `static let tooLarge: ErrorCode`  
  413.
- `static let unauthorized: ErrorCode`  
  401: the access token is missing or expired.
- `static let unavailable: ErrorCode`  
  503.
- `static let uploadIncomplete: ErrorCode`  
  409: an upload was referenced before it finished.
- `static let verificationRequired: ErrorCode`  
  403: the app accepts messages only from verified people (`identify(token:)` first).

### `ImagePart`

```swift
struct ImagePart
```

An image attachment in a message.

- `var attachmentId: String`  
  Attachment id; resolve an expired `url` with `GET /attachments/:id`.
- `func encode(to encoder: any Encoder) throws`  
  Encodes the wire format; `removed` is written only when true.
- `var height: Int`  
  Pixel height.
- `init(from decoder: any Decoder) throws`  
  Decodes the wire format; `removed` is absent unless retention deleted the photo.
- `var removed: Bool`  
  The app's retention deleted the photo: there is no `url`, and the chat shows a "Photo removed" placeholder instead of fetching it.
- `var url: URL?`  
  Short-lived download URL.
- `var width: Int`  
  Pixel width.

### `KeyCheckError`

```swift
struct KeyCheckError
```

An offline key check failure.

- `let problem: KeyProblem`  
  What is wrong with the key.

### `LinkCard`

```swift
struct LinkCard
```

A link or deep-link card.

- `var button: String`  
  Button label.
- `var id: String`  
  Card id.
- `init(from decoder: any Decoder) throws`  
  Decodes the wire format; a `screen` this SDK version can't read is left out (the card keeps its `url`).
- `var savedLinkId: String?`  
  The saved link the card was made from.  Only the server sets it.
- `var screen: LinkScreen?`  
  A screen of your app to open instead of `url` (a saved link): it reaches `PingFront.onScreen`.
- `var title: String`  
  Card title.
- `var url: String`  
  A web URL or app deep link.  With `screen`, the fallback for builds that didn't register it, or `""`.

### `LinkScreen`

```swift
struct LinkScreen
```

A screen of your app that a link card opens, and the parameters to open it with (`LinkScreen`).

- `func encode(to encoder: any Encoder) throws`  
  Encodes `{ id, params? }`.
- `var id: String`  
  The screen's id, one your app registered (`AppScreen.id`).
- `init(from decoder: any Decoder) throws`  
  Decodes `{ id, params? }`; parameters that aren't strings are left out.
- `var params: [String : String]`  
  String parameters for the screen (`"tab": "yearly"`), as the team set them.

### `LocalizedText`

```swift
struct LocalizedText
```

Text the customer wrote, keyed by BCP-47 tag plus a required `"default"`.

Lookup: exact tag, then base language, then `"default"`.

- `func encode(to encoder: any Encoder) throws`  
  Encodes the wire format.
- `init(_ values: [String : String])`  
  Creates localized text from a dictionary.  Include a `"default"` entry.
- `init(default text: String)`  
  The same text for every language.
- `init(from decoder: any Decoder) throws`  
  Decodes the wire format; values this SDK version does not know are kept as unknown.
- `func resolve(for languageTag: String) -> String?`  
  Resolves for a language tag such as `pt-BR`: exact tag, then base language, then `"default"`.
- `var values: [String : String]`  
  Values by language tag.

### `Message`

```swift
struct Message
```

A message in the thread.

- `var author: Author`  
  Who wrote it.
- `var clientId: String?`  
  The sender's idempotency key (person messages sent from an SDK).
- `var createdAt: Date`  
  When the server accepted it.
- `func encode(to encoder: any Encoder) throws`  
  Encodes the wire format.
- `var fallback: String?`  
  Plain-text rendering of the whole message, shown for parts or cards this SDK does not know.
- `var id: String`  
  Server id.
- `init(from decoder: any Decoder) throws`  
  Decodes the wire format; values this SDK version does not know are kept as unknown.
- `var isFromPerson: Bool { get }`  
  True for messages written by the person on this or another device.
- `var parts: [MessagePart]`  
  Text, images, cards and receipts.
- `var ping: PingOrigin?`  
  Set when the team reached out before the person wrote.
- `var plainText: String { get }`  
  The plain text of all text parts, joined by newlines.
- `var seq: Int`  
  Position in the thread.
- `var translation: Translation?`  
  Machine translation, when enabled.

### `OfferCard`

```swift
struct OfferCard
```

An offer card: opens the app's offer (paywall or promo) named by `offerId`.

- `var body: String?`  
  Optional body text.
- `var button: String`  
  Button label.
- `var id: String`  
  Card id.
- `var offer: StoreOffer?`  
  The store offer the button redeems (promotional, win-back, offer code, intro), if any.
- `var offerId: String`  
  The `OfferSlot.id` to show.
- `var title: String`  
  Card title.

### `OfferPrice`

```swift
struct OfferPrice
```

A product's price for an offer card.

- `var discounted: String?`  
  The offer price, shown with the regular price struck through.
- `var displayName: String?`  
  The product's display name in the store ("Ledgerly Plus Yearly").
- `init(regular: String, discounted: String? = nil, displayName: String? = nil, switchPeriod: String? = nil)`  
  Creates a price.
- `var regular: String`  
  The regular price ("€29.99").
- `var switchPeriod: String?`  
  Set when the person subscribes to another plan in the same subscription group: the ISO-8601 period of this product (`P1Y`), so the card can say "Switch to yearly".  The store handles the crossgrade.

### `OfferRequest`

```swift
struct OfferRequest
```

An offer card the person tapped.

- `let cardId: String`  
  The card id.
- `let messageId: String`  
  The message id.
- `let offerId: String`  
  The `OfferSlot.id` from the card.
- `let slot: OfferSlot?`  
  The matching slot from `setOffers(_:)` or an offer source, if any.
- `var storeOffer: StoreOffer?`  
  The store offer the card redeems (promotional, win-back, offer code), for hosts with their own paywall (RevenueCat, Superwall) to show the promo.

### `OfferSlot`

```swift
struct OfferSlot
```

An offer the app can show, reported so the team (and plays) can reference it in offer cards.

- `struct Product`  
  One purchasable product in the slot.
- `@nonexhaustive enum Kind`  
  Offer flavours.
- `@nonexhaustive enum Source`  
  Where the paywall behind a slot is built.
- `func encode(to encoder: any Encoder) throws`  
  Encodes the wire format; an unknown source is left out.
- `var id: String`  
  Stable id referenced by offer cards (`[A-Za-z0-9_.-]{1,64}`).
- `init(from decoder: any Decoder) throws`  
  Decodes the wire format; values this SDK version does not know are kept as unknown.
- `init(id: String, title: String, kind: Kind = .standard, isAvailable: Bool = true, products: [Product] = [], source: Source? = nil)`  
  Creates an offer slot.
- `var isAvailable: Bool`  
  Whether the app can show it right now.
- `var kind: Kind`  
  The flavour of offer.
- `var products: [Product]`  
  Products inside the offer.
- `var source: Source?`  
  Where the paywall is built. `setOffers(_:)` fills in `.app` and modules their own source.
- `var title: String`  
  Short title, at most 60 characters.
- `case discount`
- `case standard`
- `case winback`
- `var id: String`  
  Store product id.
- `init(id: String, price: String, period: String? = nil, trial: String? = nil)`  
  Creates a product entry.
- `var period: String?`  
  ISO-8601 period such as "P1M".
- `var price: String`  
  Localized display price, for example "€4.99".
- `var trial: String?`  
  ISO-8601 trial period such as "P1W".
- `case adapty`  
  Adapty paywalls (`PingFrontAdapty`).
- `case app`  
  The app's own paywall (`setOffers(_:)`).
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.unknown`.
- `case play`  
  Google Play (Android SDK).
- `case revenuecat`  
  RevenueCat paywalls (`PingFrontRevenueCat`).
- `case storekit`  
  StoreKit products (`.storeKit(products:)`).
- `case superwall`  
  Superwall paywalls (`PingFrontSuperwall`).
- `case unknown`  
  A source this SDK version does not know. Never sent.

### `OpenedCard`

```swift
struct OpenedCard
```

A card the person tapped or answered.

- `let cardId: String`  
  The card id.
- `let kind: CardKind`  
  What kind of card.
- `let messageId: String`  
  The message the card is in.

### `PendingMessage`

```swift
struct PendingMessage
```

A message the person wrote that the server has not acknowledged yet.

- `struct Photo`  
  A photo staged for upload.
- `@nonexhaustive enum State`  
  Delivery state.
- `var attempts: Int`  
  Delivery attempts so far.
- `var clientId: String`  
  The idempotency key.
- `var createdAt: Date`  
  When the person tapped Send.
- `var failure: String?`  
  Why it failed, in plain words.
- `var heldFor: SendPolicy.Reason? { get }`  
  Why a closed policy refused it (the app paused, verification required), kept across relaunches.  It goes again by itself when sending reopens, and the messages behind it wait for it. A blocked person's message is never held.
- `var id: String { get }`  
  The idempotency key.  A retry reuses it, so the server never stores a message twice.
- `var isHeld: Bool { get }`  
  Refused by a closed policy and waiting to go by itself (`heldFor` says why).
- `var photos: [Photo]`  
  Photos, if any.
- `var state: State`  
  Current state.
- `var text: String?`  
  Text, if any.
- `var attachmentId: String?`  
  Set once uploaded, so a retry never uploads twice.
- `var bytes: Int`  
  Byte count.
- `var height: Int`  
  Pixel height.
- `var sha256: String`  
  Hex SHA-256 of the JPEG.
- `var width: Int`  
  Pixel width.
- `case failed`  
  The server rejected it; the person can retry or discard.
- `case queued`  
  Waiting to be sent (also while offline or rate limited).
- `case sending`  
  Being uploaded or sent right now.

### `PersonSummary`

```swift
struct PersonSummary
```

A summary of the person this install belongs to.

- `@nonexhaustive enum Level`  
  Identity levels.
- `var entitlement: Entitlement?`  
  The plan as the server knows it from store events, for the chat's plan status line (absent until a store event was recorded for the person).
- `let id: String`  
  Server id of the person.
- `let level: Level`  
  Guest, named or verified.
- `let name: String?`  
  Display name, if known.
- `case guest`
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.guest`.
- `case named`
- `case verified`

### `PingFrontColor`

```swift
struct PingFrontColor
```

A color with a light and a dark variant (`PerMode` on the wire).

- `static let blue: PingFrontColor`  
  System blue.
- `static let brown: PingFrontColor`  
  System brown.
- `var dark: RGBColor`  
  Dark mode value.
- `static let green: PingFrontColor`  
  System green.
- `static let indigo: PingFrontColor`  
  System indigo.
- `init?(hex: String)`  
  The same `#RRGGBB` in both modes, or `nil` when the text is not a valid hex color.
- `init(light: RGBColor, dark: RGBColor)`  
  A color with explicit light and dark values.
- `init(light: String, dark: String)`  
  A color from two `#RRGGBB` literals.  For colors written in code. Invalid hex is a programming error: debug builds stop with an assertion; release builds use the brand reply blue. For values from elsewhere use `init?(hex:)`.
- `var light: RGBColor`  
  Light mode value.
- `static let mint: PingFrontColor`  
  System mint.
- `static let orange: PingFrontColor`  
  System orange.
- `static let pink: PingFrontColor`  
  System pink.
- `static let purple: PingFrontColor`  
  System purple.
- `static let red: PingFrontColor`  
  System red.
- `static let reply: PingFrontColor`  
  pingfront reply blue (#3550E6 / #7D91FF).
- `static let teal: PingFrontColor`  
  System teal.
- `func value(in mode: ColorMode) -> RGBColor`  
  The value in light or dark mode.

### `PingFrontConfiguration`

```swift
struct PingFrontConfiguration
```

Options for `PingFront.configure(_:_:)`.

Every field has a sensible default.

```swift
PingFront.configure("pk_live_…") { config in
    config.topics = [.billing, .bug, .idea]
    config.appearance.accent = .indigo
    config.use(.storeKit, .push, .reports)
    config.logLevel = .debug
}
```

- `var appearance: ChatAppearance`  
  Look values set in code.  The published remote look wins; unset values come from the host app, then defaults.
- `var baseURL: URL`  
  The API base URL.  Leave the default, pingfront's API. Another value is only for testing against a different server.
- `init()`  
  Defaults.
- `var language: String?`  
  The chat's language, for apps with their own language picker (a BCP 47 tag such as `"de"` or `"pt-BR"`).  Default `nil`: follow the app's and the system's language. Change it later with `PingFront.shared.language`.
- `var logHandler: PingFrontLogHandler?`  
  Routes SDK log lines into your own logger, in addition to unified logging.  Lines are already redacted: ids, names, emails, URLs, tokens, server text and user input appear as `<private>`. Called from any thread, for lines at or above `logLevel`.  ```swift config.logHandler = { entry in AppLog.info("[pingfront/\(entry.category)] \(entry.message)") } ```
- `var logLevel: PingFrontLogLevel`  
  How much the SDK logs.  Default `.info`.
- `var modules: [PingFrontModule] { get }`  
  Optional modules, in the order they were added.
- `var presentsChatForMoments: Bool`  
  Present the chat when the server answers a moment with `open`.  Default `true`.
- `static var productionURL: URL { get }`  
  The production API.
- `var pushEnvironment: PushEnvironment?`  
  The APNs environment for push tokens.  Default: sandbox in debug builds, production otherwise.
- `var topics: [ChatTopic]?`  
  Topic chips on the welcome screen (up to six).  Default: Billing, Report a bug, Ideas. A published remote look with topics replaces these.
- `mutating func use(_ modules: PingFrontModule...)`  
  Adds optional modules, for example `config.use(.storeKit, .push, .reports)`.
- `var wrapper: PingFrontWrapper?`  
  The cross-platform bridge this SDK runs inside, sent as `PF-Wrapper` on every request.  Set only by the React Native and Flutter bridges; a native app leaves it `nil` and sends nothing.

### `PingFrontLogEntry`

```swift
struct PingFrontLogEntry
```

One SDK log line, as passed to `PingFrontConfiguration.logHandler`.

The message is safe to store and upload: values that could identify a person or grant access
(ids, names, emails, URLs, tokens, server text, user input) are already replaced by `<private>`.

- `let category: String`  
  The SDK area, for example `session`, `network` or `live`.
- `let level: PingFrontLogLevel`  
  `.error`, `.info` or `.debug`.
- `let message: String`  
  The redacted line.

### `PingFrontModule`

```swift
struct PingFrontModule
```

An optional module.

Modules register through `ModuleContext`, so Core never imports them.

The modules in this package add static members: `.chatUI`, `.push`, `.storeKit`, `.reports`. The vendor
adapters, one package per vendor (`pingfront-ios-revenuecat`, `-superwall`, `-adapty`), add `.revenueCat`,
`.superwall(…)` and `.adapty(…)` (`config.use(.revenueCat)`). Your own module registers through the same context:
```swift
extension PingFrontModule {
    static var myOffers: PingFrontModule {
        PingFrontModule(id: "com.example.offers") { context in
            context.setOfferHandler(MyOfferHandler())  // your type conforming to OfferHandling
        }
    }
}
```

- `let id: String`  
  A unique id.  Adding the same id twice has no effect.
- `init(id: String, install: @escaping @MainActor @Sendable (ModuleContext) -> Void)`  
  Creates a module. `install` runs once, on the main actor, during `configure`.

### `PingFrontWrapper`

```swift
struct PingFrontWrapper
```

The cross-platform bridge the SDK runs inside (`PF-Wrapper: react-native/1.0.0`).

- `init(name: String, version: String)`  
  Creates a wrapper value.
- `var name: String`  
  The bridge, for example `react-native` or `flutter`.
- `var version: String`  
  The bridge's version, for example `1.0.0`.

### `PingOrigin`

```swift
struct PingOrigin
```

Why a team or AI message arrived before the person wrote.

Shown to the person, never configurable.

- `@nonexhaustive enum Kind`  
  Manual (a teammate wrote it) or play (a rule sent it).
- `var explanation: String`  
  For example "Sent automatically after you closed Plans", localized by the server.
- `var kind: Kind`  
  Manual or play.
- `var playId: String?`  
  The play that sent it.
- `var reason: PingReason?`  
  A structured reason (`manual`, `moment`, `store_event`, `scheduled`) with optional parameters.
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.manual`.
- `case manual`
- `case play`

### `PingReason`

```swift
struct PingReason
```

Why a ping was sent, machine-readable.

- `@nonexhaustive enum Code`  
  Reason codes.
- `var code: Code`  
  The reason code.
- `var params: [String : String]?`  
  Parameters such as the moment name.
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.unknown`.
- `case manual`
- `case moment`
- `case scheduled`
- `case storeEvent`
- `case unknown`  
  A code this SDK version does not know.

### `PromotionalOfferSignature`

```swift
struct PromotionalOfferSignature
```

What StoreKit needs to buy a product with a promotional offer (`OfferSignatureResponse`).

- `struct Legacy`  
  The pre-iOS 26 signature parts.
- `var appAccountToken: String`  
  Pass as `appAccountToken` with the purchase.
- `var jws: String`  
  The compact JWS for `promotionalOffer(_:compactJWS:)`.
- `var legacy: Legacy`  
  The legacy signature.
- `var offerId: String`  
  The promotional offer id.
- `var productId: String`  
  The product.
- `var keyId: String`  
  The In-App Purchase key id.
- `var nonce: String`  
  The nonce (a UUID).
- `var signature: String`  
  Base64 DER ECDSA signature.
- `var timestamp: Int64`  
  Milliseconds since the epoch.

### `RGBColor`

```swift
struct RGBColor
```

An sRGB color with components from 0 to 1.

Platform-independent, so Core can merge looks and check contrast.

- `static let black: RGBColor`  
  Black.
- `var blue: Double`  
  Blue, 0...1.
- `static func contrast(_ a: RGBColor, _ b: RGBColor) -> Double`  
  WCAG contrast ratio between two colors (1...21).
- `var description: String { get }`  
  The hex string.
- `func encode(to encoder: any Encoder) throws`  
  Encodes the wire format.
- `var green: Double`  
  Green, 0...1.
- `var hex: String { get }`  
  `#RRGGBB`, uppercase.
- `init(from decoder: any Decoder) throws`  
  Decodes the wire format; values this SDK version does not know are kept as unknown.
- `init?(hex: String)`  
  Parses `#RRGGBB`.
- `init(red: Double, green: Double, blue: Double)`  
  Creates a color from sRGB components in 0...1.
- `init(rgb: UInt32)`  
  A color from a `0xRRGGBB` literal, for constants.
- `var luminance: Double { get }`  
  WCAG 2.x relative luminance.
- `func mixed(with other: RGBColor, amount: Double) -> RGBColor`  
  Mixes toward `other` by `amount` (0 = self, 1 = other).
- `var red: Double`  
  Red, 0...1.
- `static let white: RGBColor`  
  White.

### `RateScope`

```swift
struct RateScope
```

The part of the API a rate limit applies to.

Only that scope pauses.

A struct, not an enum: the server may add scopes in a minor version, and existing code keeps compiling.

- `var description: String { get }`  
  The raw scope.
- `static let exports: RateScope`  
  The person's data export (`exportMyData()`): 5 an hour per install.
- `init(rawValue: String)`  
  Wraps a raw scope.
- `static let known: [RateScope]`  
  The scopes this SDK version knows.
- `static let live: RateScope`  
  The live socket.
- `static let messages: RateScope`  
  Sending messages.
- `static let moments: RateScope`  
  Reporting moments.
- `static let offers: RateScope`  
  Promotional offer signatures.
- `let rawValue: String`  
  The scope as sent by the server.
- `static let sessions: RateScope`  
  Creating or refreshing sessions.
- `static let uploads: RateScope`  
  Photo and screenshot uploads.

### `RatingCard`

```swift
struct RatingCard
```

A 1–5 rating card.

- `var id: String`  
  Card id.
- `init(from decoder: any Decoder) throws`  
  Decodes a rating card, clamping `scale` into the protocol's range so a bad value never draws a row of stars that cannot fit (or traps on an empty range).
- `var question: String`  
  The question.
- `var scale: Int`  
  Always 5.  A value outside 1...5 from the server is clamped into it when the card is decoded.

### `ReceiptPart`

```swift
struct ReceiptPart
```

A centered system line recording something done for the person.

- `@nonexhaustive enum Action`  
  What was done.
- `var action: Action`  
  What was done.
- `var text: String`  
  The line to show, for example "Trial extended to 14 Nov".
- `case custom`
- `case dataExported`
- `case handedOff`  
  The AI teammate handed the conversation to the team. Nothing was done for the person, so the chat shows it without the check.
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.custom`.
- `case promoGranted`
- `case purchasesRestored`
- `case reportFiled`
- `case trialExtended`

### `ReceivedMessage`

```swift
struct ReceivedMessage
```

A summary of a received message, safe to show in an in-app banner.

- `let authorName: String?`  
  Author display name.
- `let id: String`  
  Message id.
- `let isAI: Bool`  
  True when written by the assistant.
- `let isPing: Bool`  
  True when the team reached out before the person wrote.
- `let preview: String`  
  The first text part, truncated.

### `ReportCard`

```swift
struct ReportCard
```

A bug report card: opens the report flow.

- `var button: String`  
  Button label.
- `var id: String`  
  Card id.
- `var title: String`  
  Card title.

### `ReportContext`

```swift
struct ReportContext
```

Extra context attached to a bug report.

- `init(logTail: String? = nil, state: [String : String] = [:])`  
  Creates a report context.
- `var logTail: String?`  
  Recent log lines.
- `var state: [String : String]`  
  Device state, for example `["screen": "Settings", "battery": "45%"]`.

### `ResolvedLook`

```swift
struct ResolvedLook
```

The single resolved look the chat renders.

Precedence for every field:
published remote look, then `config.appearance`, then values inferred from the host app, then SDK defaults.
Colors are adjusted toward WCAG AA when a configured value would make body text unreadable.

- `var accent: PingFrontColor`  
  Person's bubbles and buttons (contrast-adjusted).
- `var aiName: String`  
  The assistant's display name.
- `var allowsPhotos: Bool`  
  Photos allowed.
- `var allowsReports: Bool`  
  Bug reports allowed.
- `var appIconPNG: Data?`  
  The app icon read from the bundle.
- `var appIconURL: URL?`  
  The app icon URL from the dashboard.
- `var appName: String`  
  The app name.
- `var background: PingFrontColor`  
  Chat background.
- `var bubbleRadius: Double { get }`  
  Bubble radius: 18, 12 or 6 pt.
- `var cardRadius: Double { get }`  
  Card radius: 16, 12 or 6 pt with the corners token.
- `var composerPlaceholder: LocalizedText?`  
  Composer placeholder (nil: built-in).
- `var corners: ChatLook.Corners`  
  Bubble corners.
- `var density: ChatLook.Density`  
  Spacing density.
- `var font: ChatLook.FontStyle`  
  Font design.
- `var headerMemberId: String?`  
  The teammate the person header shows.
- `var headerStyle: ChatLook.HeaderStyle`  
  Header style.
- `var headerTitle: LocalizedText?`  
  Header title for team and app styles.
- `var isDraft: Bool`  
  The look is an unpublished draft (test devices only).
- `var muted: PingFrontColor`  
  Secondary text.
- `var onAccent: PingFrontColor`  
  Text on the accent, picked by contrast (never configured).
- `var replyExpectation: LocalizedText?`  
  The reply expectation.
- `var revision: Int`  
  Remote revision, 0 when none.
- `var scheme: ChatLook.Scheme`  
  Light, dark or automatic.
- `var showsAvatars: Bool`  
  Show team avatars beside messages.
- `var showsLocalTime: Bool`  
  Show the teammate's local time.
- `var showsNames: Bool`  
  Show author names.
- `var showsReplyExpectation: Bool`  
  Show the reply expectation.
- `var showsWelcomeFaces: Bool`  
  Show team faces on the welcome screen.
- `var team: [TeamMember]`  
  The team from the config.
- `var teamBubble: PingFrontColor`  
  Team bubble fill.
- `var text: PingFrontColor`  
  Body text on background and team bubbles.
- `var timestamps: ChatLook.Timestamps`  
  Timestamps per group or per message.
- `var topics: [ChatTopic]`  
  Topic chips, at most six.
- `var welcomeBody: LocalizedText?`  
  Welcome body (nil: built-in).
- `var welcomeTitle: LocalizedText?`  
  Welcome title (nil: built-in).

### `ReviewCard`

```swift
struct ReviewCard
```

A review card: native prompt or the store page.

- `@nonexhaustive enum Mode`  
  How the review is requested.
- `var button: String`  
  Button label.
- `var id: String`  
  Card id.
- `var mode: Mode`  
  Native prompt or store page.
- `var storeURL: URL?`  
  Store page URL.
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.storePage`.
- `case nativePrompt`
- `case storePage`

### `SentMessage`

```swift
struct SentMessage
```

A summary of a message the person sent, for the host's analytics.

It carries no message text.

- `let id: String`  
  Message id.
- `let photoCount: Int`  
  Photos attached.
- `let repliesToPing: Bool`  
  True when the latest team message before it is a ping (the person is answering a ping).
- `let textLength: Int`  
  Characters of text (0 for a photo-only message).

### `ServerError`

```swift
struct ServerError
```

An error returned by the pingfront API.

- `let code: ErrorCode`  
  Machine-readable code.
- `let docs: URL?`  
  The docs page that explains the fix.
- `var fields: [String]`  
  For 422s: the fields that failed, as dotted paths ("identity.email").
- `let message: String`  
  Human-readable explanation from the server.
- `let retryAfter: Duration?`  
  How long to wait before retrying, when the server says.
- `let scope: RateScope?`  
  For 429s: which part of the API is paused.
- `let status: Int`  
  HTTP status.

### `SetupCheckResult`

```swift
struct SetupCheckResult
```

The result of `PingFront.selfCheck()`: whether a real message reached the server, and if not, a stable code and
what to do.

Nothing in it is personal: codes and advice are the SDK's own.

- `let advice: String?`  
  What to do about the failure, in English. `nil` when passed.
- `let code: String?`  
  A stable failure code, such as `key_unknown`, `network`, `timeout`, `app_paused` or `identity_user_mismatch`. `nil` when passed.
- `var line: String { get }`  
  The one-line form: `PingFront self-check: PASS` or `PingFront self-check: FAIL <code>: <advice>`.
- `static let pass: SetupCheckResult`  
  A passing result.
- `let passed: Bool`  
  True when the setup message reached the server.

### `StoreActionCard`

```swift
struct StoreActionCard
```

A card that opens one of Apple's own App Store sheets inside the app: manage subscriptions, fix a billing
issue, request a refund, redeem a code or restore purchases (`store_action` on the wire).

- `@nonexhaustive enum Action`  
  The App Store sheet the card opens.
- `@nonexhaustive enum Store`  
  Which store the card was written for (a hint; the SDK uses the platform's store either way).
- `var action: Action`  
  The sheet the card opens.
- `var body: String?`  
  Card text (at most 280 characters); the SDK's own line for the action when absent.
- `var button: String?`  
  Button label (at most 40 characters); the SDK's own label for the action when absent.
- `var fallbackURL: URL? { get }`  
  Apple's web page for the action, used when the app has no StoreKit module (`nil` for restore, which has no web page).
- `var id: String`  
  Card id.
- `var productId: String?`  
  The product the action is about.
- `var store: Store?`  
  The store the card was written for, a hint.
- `var subscriptionGroupId: String?`  
  The subscription group the manage sheet opens on.
- `var title: String?`  
  Card title (at most 80 characters); the SDK's own title for the action when absent.
- `var transactionId: String?`  
  The transaction a refund request is for (set by the server only).
- `case billingIssue`  
  Apple's billing-issue message when one is pending, otherwise the manage-subscriptions sheet.
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.unknown`.
- `case manageSubscriptions`  
  Apple's manage-subscriptions sheet.
- `case redeemCode`  
  Apple's offer code redemption sheet.
- `case requestRefund`  
  Apple's refund request sheet for a transaction.
- `case restorePurchases`  
  Syncs purchases with the App Store.
- `case unknown`  
  An action this SDK version does not know: the card opens Apple's subscriptions page.
- `case appStore`
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.unknown`.
- `case play`
- `case unknown`  
  A store this SDK version does not know.

### `StoreActionRequest`

```swift
struct StoreActionRequest
```

A store action card the person tapped.

- `let card: StoreActionCard`  
  The card.
- `let messageId: String`  
  The id of the message that carries the card.

### `StoreEventReport`

```swift
struct StoreEventReport
```

A purchase or subscription change a store module detected on the device.

- `var clientId: String`  
  Idempotency key; the same transaction and event always report once.
- `var currency: String?`  
  ISO 4217 currency code.
- `init(name: String, productId: String, transactionId: String? = nil, originalTransactionId: String? = nil, price: String? = nil, currency: String? = nil, signedTransaction: String? = nil, occurredAt: Date, dedupeKey: String? = nil)`  
  Creates a store event report.
- `var name: String`  
  The normalized event: `trial_started`, `trial_converted`, `trial_cancelled`, `trial_expired`, `subscription_started`, `subscription_renewed`, `subscription_cancelled`, `billing_issue`, `subscription_expired` or `refunded`.
- `var occurredAt: Date`  
  When it happened.
- `var originalTransactionId: String?`  
  The first transaction of the subscription.
- `var price: String?`  
  Decimal price in `currency`, for example `"9.99"`.
- `var productId: String`  
  The store product id.
- `var signedTransaction: String?`  
  StoreKit 2 `jwsRepresentation`.  Without it the server never links the transaction to the person.
- `var transactionId: String?`  
  The store transaction id.

### `StoreOffer`

```swift
struct StoreOffer
```

A store offer an offer card redeems on top of opening the paywall (the protocol's `StoreOffer`).

- `@nonexhaustive enum Kind`  
  The kind of store offer.
- `var id: String`  
  The offer identifier (App Store Connect).
- `init(kind: Kind, id: String, productId: String? = nil)`  
  Creates a store offer.
- `var kind: Kind`  
  The kind.
- `var productId: String?`  
  The product the offer applies to.
- `case code`  
  An offer code: the redemption sheet opens.
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.unknown`.
- `case intro`  
  An introductory offer the store applies to eligible people.
- `case promotional`  
  An App Store promotional offer (signed by the server).
- `case unknown`  
  A kind this SDK version does not know: the paywall opens without an offer.
- `case winback`  
  An App Store win-back offer (iOS 18+).

### `TeamAction`

```swift
struct TeamAction
```

An action a teammate ran from the inbox that your app has to do ("Fix it for them"), such as extending a trial
or repairing a sync.

Read them from ``PingFront/teamActions``. Do the work once per ``id``, then call ``complete()`` or
``fail(message:)``. When ``ackRequired`` is true the receipt line in the thread waits for `complete()`.
The same action may also reach your server as a signed webhook; do it in one place.

- `let ackRequired: Bool`  
  True when the receipt line in the thread waits for ``complete()``.
- `let actionId: String`  
  Which action: `extend_trial`, `grant_access`, or the id of one of your own actions.
- `func complete() async`  
  Tells the team the action is done; the receipt line posts in the thread.  Stored and retried until the server has it. The first answer wins.
- `let createdAt: Date`  
  When the teammate ran it.
- `let days: Int?`  
  Days, for `extend_trial` and `grant_access`.
- `let expiresAt: Date`  
  After this the action expires and nothing is posted.
- `func fail(message: String) async`  
  Tells the team the action could not be done.  - Parameter message: What went wrong, shown to the team and never to the person (at most 200   characters).
- `let fields: [String : String]`  
  The values the teammate filled in, by field key.
- `let id: String`  
  This run's id.  Do the work once per id.
- `let name: String`  
  The action's name, as your team sees it.
- `let until: Date?`  
  The new end of access, for `extend_trial` and `grant_access`.

### `TeamMember`

```swift
struct TeamMember
```

A member of the app's team, shown in the header and welcome.

- `var avatarURL: URL?`  
  Avatar URL.
- `var id: String`  
  Member id.
- `var name: String`  
  Display name.
- `var role: String?`  
  For example "Maker of Clockwise".
- `var timeZone: String?`  
  IANA time zone, used for "It's 21:40 for Deniz".

### `TimelineItem`

```swift
struct TimelineItem
```

One row of the timeline with its grouping.

- `@nonexhaustive enum Content`  
  What the row shows.
- `@nonexhaustive enum Side`  
  Which side of the thread a row sits on.
- `var authorName: String?`  
  The author's display name.
- `var content: Content`  
  The content.
- `var date: Date`  
  When it was written.
- `var endsGroup: Bool`  
  Last row of a group (show the timestamp, avatar, hand-off line).
- `var id: String`  
  Stable id (message id or clientId).
- `var isAI: Bool`  
  Written by the assistant (always labelled).
- `var side: Side`  
  Which side.
- `var startsGroup: Bool`  
  First row of a group from the same author (show the author name).
- `var startsPing: Bool`  
  First row of a run of pings (show the ping mark and its line).
- `var startsTimeSection: Bool`  
  First row after a pause of more than 5 minutes (or the first row): show a centered time caption.
- `case message(Message)`  
  A delivered message.
- `case pending(PendingMessage)`  
  A message waiting for the server.
- `case person`  
  Right: the person.
- `case system`  
  Centered: receipts and system lines.
- `case team`  
  Left: team and AI.

### `Translation`

```swift
struct Translation
```

A machine translation of a message's text parts.

- `func encode(to encoder: any Encoder) throws`  
  Encodes the wire format.
- `var from: String?`  
  The language the message was written in (a language tag), when the server knows it.
- `init(from decoder: any Decoder) throws`  
  Decodes the wire format; values this SDK version does not know are kept as unknown.
- `var language: String`  
  Target language tag.
- `var texts: [String]`  
  Translated text parts.

### `TypingIndicator`

```swift
struct TypingIndicator
```

Who is typing.

- `var isAI: Bool`  
  True when the assistant is typing.
- `var name: String?`  
  The teammate or assistant name.

### `BackgroundPushResult`

```swift
@nonexhaustive enum BackgroundPushResult
```

What a silent push did, for the system's background-fetch result.

- `case failed`  
  The fetch failed (offline, server error).
- `case newData`  
  Something changed (a new chat look was fetched).
- `case noData`  
  Nothing to do, or nothing changed.

### `Card`

```swift
@nonexhaustive enum Card
```

A structured card inside a message.

Unknown kinds decode as `.unknown` and are skipped by the UI.

- `case choices(ChoicesCard)`
- `func encode(to encoder: any Encoder) throws`  
  Encodes the wire format.
- `var id: String { get }`  
  The card id.
- `init(from decoder: any Decoder) throws`  
  Decodes the wire format; values this SDK version does not know are kept as unknown.
- `var kind: CardKind { get }`  
  The card's kind.
- `case link(LinkCard)`
- `case offer(OfferCard)`
- `case rating(RatingCard)`
- `case report(ReportCard)`
- `case review(ReviewCard)`
- `case storeAction(StoreActionCard)`  
  Opens one of Apple's App Store sheets (`store_action`).
- `case unknown(kind: String, id: String?)`  
  A card kind this SDK version does not know.

### `CardAnswer`

```swift
@nonexhaustive enum CardAnswer
```

What the person answered on a card.

- `case choice(id: String)`  
  An option of a choices card.
- `case rating(Int)`  
  A value on a rating card's scale.

### `ColorMode`

```swift
@nonexhaustive enum ColorMode
```

Light or dark appearance.

- `case dark`  
  Dark appearance.
- `case light`  
  Light appearance.

### `IdentityProblem`

```swift
@nonexhaustive enum IdentityProblem
```

A problem with the identity token, reported by the server without failing the request.

- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.unknown`.
- `case tokenExpired`  
  The token expired.
- `case tokenInvalid`  
  The signature did not verify.
- `case unknown`  
  A problem this SDK version does not know.
- `case userMismatch`  
  The token belongs to a different user id.

### `KeyProblem`

```swift
@nonexhaustive enum KeyProblem
```

Why an app key was rejected offline.

Mirrors the key problems of the protocol's shared `keys.json` cases.

- `case badCharacters`  
  The key contains characters outside base62.
- `case checksumMismatch`  
  The two check characters do not match the rest of the key (a typo).
- `case empty`  
  The key is an empty string.
- `var message: String { get }`  
  The exact, actionable explanation shown in debug banners and logs.
- `case whitespace`  
  The key has leading or trailing whitespace or line breaks.
- `case wrongLength`  
  The key is longer or shorter than a public key.
- `case wrongPrefix`  
  The key does not start with `pk_live_` or `pk_test_`.

### `LiveState`

```swift
@nonexhaustive enum LiveState
```

The state of the live channel.

- `case connecting`  
  Opening the socket.
- `case live`  
  Receiving events.
- `case stopped`  
  Not connected (chat closed).
- `case waiting(retryIn: Duration, offline: Bool)`  
  Disconnected; retrying after `retryIn`.

### `MessagePart`

```swift
@nonexhaustive enum MessagePart
```

One part of a message.

Unknown part types decode as `.unknown` so new server content never crashes old SDKs.

- `case card(CardPart)`
- `func encode(to encoder: any Encoder) throws`  
  Encodes the wire format.
- `case image(ImagePart)`
- `init(from decoder: any Decoder) throws`  
  Decodes the wire format; values this SDK version does not know are kept as unknown.
- `case receipt(ReceiptPart)`
- `case text(String)`
- `case unknown(type: String)`  
  A part type this SDK version does not know.

### `MomentResult`

```swift
@nonexhaustive enum MomentResult
```

The outcome of `PingFront.shared.moment(_:props:)`.

- `case delivered`  
  A ping was delivered now.
- `case failed(PingFrontError)`  
  Sending failed.
- `case heldOut`  
  The person is in a holdout group for this play.
- `case ignored`  
  Sent; no play reacted.
- `case invalidName`  
  The moment name is invalid (`[a-z0-9][a-z0-9_.-]{0,63}`).
- `case notListened`  
  The moment is not listened to by any play, so nothing was sent.
- `case openRequested(presented: Bool)`  
  The server asked to open the chat. `presented` is `true` when the SDK presented it, and `false` when `presentsChatForMoments` is off (present it yourself when it suits the screen).
- `case scheduled`  
  A play scheduled a ping.

### `MomentValue`

```swift
@nonexhaustive enum MomentValue
```

A moment property value: string, number or boolean.

- `case bool(Bool)`  
  A boolean.
- `func encode(to encoder: any Encoder) throws`  
  Encodes the wire format.
- `init(booleanLiteral value: Bool)`  
  A Boolean value.
- `init(floatLiteral value: Double)`  
  A number value.
- `init(integerLiteral value: Int)`  
  An integer value.
- `init(stringLiteral value: String)`  
  A string value.
- `case number(Double)`  
  A number.
- `case string(String)`  
  A string, at most 256 characters.

### `OfferError`

```swift
@nonexhaustive enum OfferError
```

Why an offer could not be bought.

- `case network`  
  The store could not be reached.
- `case notAllowed`  
  Purchases are not allowed here (restrictions, storefront, parental controls).
- `case notVerified`  
  The store could not verify the transaction.
- `case productNotFound`  
  No product matches the offer.
- `case store`  
  Any other store failure.

### `OfferOutcome`

```swift
@nonexhaustive enum OfferOutcome
```

What happened when an offer was shown.

- `case cancelled`  
  The person closed the offer.
- `case failed(OfferError)`  
  Something failed.
- `case pending`  
  The purchase waits for approval (Ask to Buy, Strong Customer Authentication). The entitlement arrives later through the store.
- `case purchased`  
  The person bought it.
- `case unavailable`  
  The offer is not available.

### `PingFrontError`

```swift
@nonexhaustive enum PingFrontError
```

Every error the SDK surfaces.

The SDK's APIs throw only this type (typed throws). It may gain cases in a minor release: switch over it with
`@unknown default`.

- `case cancelled`  
  The operation was cancelled.
- `var code: ErrorCode? { get }`  
  The server error code, when there is one.
- `case coolingDown(scope: RateScope, remaining: Duration)`  
  A rate limit is active for `scope`; try again after `remaining`.
- `var errorDescription: String? { get }`  
  A developer-facing sentence (English).  Show your own copy to people.
- `var failureReason: String? { get }`  
  The server's explanation, when there is one.
- `case invalidInput(String)`  
  The input was rejected before sending (for example an empty message).
- `case invalidKey(KeyProblem)`  
  The app key failed the offline check.
- `case invalidResponse(String)`  
  The server answered with something the SDK could not read. The associated text describes the decoding failure for debugging; it is never shown to people.
- `var isOffline: Bool { get }`  
  True when the device appears to be offline.
- `var isServerUnreachable: Bool { get }`  
  True when the device has a network but could not reach the service: the host could not be found or would not accept the connection (the service is down, a firewall, a captive portal).  No network at all (`notConnectedToInternet`, data or roaming off) is offline, not this; a timeout or a dropped connection says nothing about which. Part of `isOffline`.
- `var isTransient: Bool { get }`  
  True for failures that a later retry can fix without changing the request: no answer, a rate limit, a 408 or a 5xx.  A 401 is not: the client already refreshed the session once and retried, so a second 401 is final. Nor is a 409 `thread_reset`, which reloads the thread and retries once, not with a backoff.
- `var logDescription: String { get }`  
  A description that is safe to log publicly by construction: the case, the HTTP status, the error code, the rate scope and the docs anchor.  Never the server message, URLs, ids or user input.
- `case network(URLError.Code)`  
  The request did not reach the server.
- `case notConfigured`  
  `PingFront.configure` was not called yet.
- `case protectedDataUnavailable`  
  The device has not been unlocked since it restarted, so the Keychain and protected files are unreadable. The SDK tries again once protected data becomes available.
- `var recoverySuggestion: String? { get }`  
  Where to read about the fix.
- `case server(ServerError)`  
  The server answered with an error envelope.

### `PingFrontEvent`

```swift
@nonexhaustive enum PingFrontEvent
```

Events from `PingFront.shared.events`.

- `case cardOpened(OpenedCard)`  
  The person tapped a card (offer, review, link, report, store action) or answered one (choices, rating).
- `case chatClosed`  
  The chat was closed.
- `case chatOpened`  
  The chat became visible.
- `case configurationProblem(ConfigurationProblem)`  
  A configuration problem was found.
- `case identityProblem(IdentityProblem)`  
  The server reported a problem with the identity token.
- `case lookChanged(revision: Int, draft: Bool)`  
  The chat look changed (published or draft).
- `case messageReceived(ReceivedMessage)`  
  A team or assistant message arrived.
- `case messageSent(SentMessage)`  
  The server accepted a message the person wrote (after any queueing and photo uploads).
- `case offerCompleted(OfferRequest, OfferOutcome)`  
  An offer module finished showing an offer (purchased, pending approval, cancelled, …).
- `case offerRequested(OfferRequest)`  
  The person tapped an offer card.
- `case reportSent`  
  A bug report was sent.
- `case sessionRevoked`  
  The server revoked this install; the SDK started over as a guest.  By design, everything local to the revoked install is dropped with it: its credentials, the cached thread and any messages still waiting in the outbox. The protocol requires this: queued sends are wiped and never sent under a new session. The person starts a new conversation; the next chat open creates a new session (`auth-refresh-revoked` in the protocol scenarios).
- `case sessionStarted(PersonSummary)`  
  A session started (lazily, on first use).
- `case unreadChanged(Int)`  
  The unread count changed.

### `PingFrontLogLevel`

```swift
@nonexhaustive enum PingFrontLogLevel
```

How much the SDK logs (unified logging, subsystem `dev.pingfront.sdk`).

- `static func < (lhs: PingFrontLogLevel, rhs: PingFrontLogLevel) -> Bool`  
  Orders levels from quietest to most verbose.
- `case debug`  
  Everything, including request paths and statuses (never bodies or tokens).
- `case error`  
  Errors and setup problems only.
- `case info`  
  Errors plus notable events: sessions, live state, look revisions (default).
- `case off`  
  Nothing at all.

### `PingFrontVersion`

```swift
enum PingFrontVersion
```

SDK version reported in `Device.sdk` and the `PF-SDK` header.

- `static let current: String`  
  The SDK version.
- `static let name: String`  
  The SDK name sent to the server.
- `static let protocolVersion: String`  
  The wire protocol this SDK speaks (`PF-Protocol`).

### `Platform`

```swift
@nonexhaustive enum Platform
```

The platform an install runs on.

- `case android`
- `case ios`
- `case macos`
- `case web`

### `PushEnvironment`

```swift
enum PushEnvironment
```

The APNs environment.

- `case production`  
  TestFlight and App Store builds.
- `case sandbox`  
  Development builds.

### `SendPolicy`

```swift
@nonexhaustive enum SendPolicy
```

Whether the person can send, and why not.

An enum, so "can send" and "why not" can never disagree.

- `@nonexhaustive enum Reason`  
  Why sending is off.
- `var canSend: Bool { get }`  
  True when the composer is enabled.
- `case closed(Reason)`  
  Sending is off, for a reason the chat explains.
- `func encode(to encoder: any Encoder) throws`  
  Encodes `{ canSend, reason? }`.
- `init(from decoder: any Decoder) throws`  
  Decodes `{ canSend, reason? }`.
- `case open`  
  The person can send.
- `var reason: Reason? { get }`  
  Why sending is off; `nil` when it is not.
- `case appPaused`
- `case blocked`
- `var code: String { get }`  
  The reason's stable wire code.  `blocked`, `app_paused` or `verification_required` (`unknown` for a reason this SDK version doesn't know): the same strings as Android's `SendPolicy.Reason.code`.
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.unknown`.
- `case unknown`
- `case verificationRequired`  
  The app accepts messages only from verified people: the person must sign in to the host app.

### `StoreActionOutcome`

```swift
@nonexhaustive enum StoreActionOutcome
```

What happened when a store action ran.

- `case cancelled`  
  The person closed the sheet without doing anything.
- `case completed(StoreChange?)`  
  Apple's sheet closed; `change` is what changed, if anything.
- `case failed`  
  The App Store returned an error.
- `case unavailable`  
  The action can't run here (no window, no matching transaction).

### `StoreChange`

```swift
@nonexhaustive enum StoreChange
```

What changed in the App Store while Apple's sheet was open; the chat shows it as a receipt.

- `case autoRenewOff`  
  Auto-renew was turned off.
- `case autoRenewOn`  
  Auto-renew was turned back on.
- `case codeRedeemed(product: String?)`  
  An offer code was redeemed, with the product's display name when known.
- `case paymentUpdated`  
  A subscription in billing retry or grace is active again.
- `case planChanged(product: String)`  
  Another plan in the same subscription group.
- `case purchasesRestored`  
  Purchases were synced with the App Store.
- `case refundRequested`  
  Apple accepted a refund request for review.
- `case subscribed(product: String)`  
  A new subscription or purchase, with the product's display name.

### `ThreadStatus`

```swift
@nonexhaustive enum ThreadStatus
```

Open or resolved.

- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.open`.
- `case open`
- `case resolved`

### `TopicSymbol`

```swift
@nonexhaustive enum TopicSymbol
```

The symbol shown on a topic chip.

Mapped to SF Symbols by the UI.

- `case account`
- `case billing`
- `case bug`
- `case feedback`
- `case gift`
- `case idea`
- `init(from decoder: any Decoder) throws`  
  Decodes the raw value; values this SDK version does not know become `.other`.
- `case other`
- `case privacy`
- `case question`
- `case restore`

### `ChatPresenting`

```swift
@MainActor protocol ChatPresenting : AnyObject
```

Presents and dismisses the chat.

Provided by `PingFrontUI`.

- `@MainActor func dismissChat()`  
  Dismisses the SDK-presented chat.
- `@MainActor func dismissChatAndWait() async`  
  Dismisses the SDK-presented chat and returns once the dismissal finished. By default, dismisses and returns at once (for presenters without an animation to wait for).
- `@MainActor var isPresentingChat: Bool { get }`  
  Whether this presenter has a chat on screen, or one about to open. Without one, `PingFront.closeChat()` returns at once: a chat the app embeds (`PingFrontChatView`) is the app's to remove. By default, true: `closeChat()` asks a presenter that doesn't say to dismiss.
- `@MainActor func open(_ url: URL)`  
  Opens a web URL or deep link from a card.
- `@MainActor func openLink(_ url: URL) async -> Bool`  
  Opens a web URL or deep link from a card, and returns whether something opened it (a link card reports a link that didn't open). By default, calls `open(_:)` and counts the link as opened.
- `@MainActor func presentChat(topic: ChatTopic?)`  
  Presents the chat sheet, optionally prefilled for a topic.
- `@MainActor func presentSimpleReport()`  
  Presents a plain text bug report form (used when the reports module is not installed).

### `EntitlementSource`

```swift
protocol EntitlementSource : Sendable
```

Streams the person's entitlement (StoreKit 2, RevenueCat, …).

- `func entitlementUpdates() -> AsyncStream<Entitlement>`  
  Entitlement updates, starting with the current value.

### `OfferHandling`

```swift
@MainActor protocol OfferHandling : AnyObject
```

Handles offer cards.

Vendor adapters implement this to show their paywall.

- `@MainActor func handle(_ request: OfferRequest) async -> OfferOutcome`  
  Shows the offer and reports what happened.

### `OfferPricing`

```swift
protocol OfferPricing : Sendable
```

Prices for offer cards, from the store.

- `func price(productId: String, offer: StoreOffer?) async -> OfferPrice?`  
  The regular price and, for a store offer, its price, formatted for display.

### `OfferSource`

```swift
protocol OfferSource : Sendable
```

Produces offer slots (for example from StoreKit products) so the team can reference them in cards.

Each source owns its slots: what it reports replaces its earlier slots and leaves the app's own
(`setOffers(_:)`) and other modules' slots alone.

- `func offerUpdates() -> AsyncStream<[OfferSlot]>`  
  The offers now and whenever they change. Defaults to `offers()` once.
- `func offers() async -> [OfferSlot]`  
  The current offers.
- `var slotSource: OfferSlot.Source { get }`  
  Where these slots are built; stamped on every slot. Defaults to `.app`.

### `ReportContextProviding`

```swift
protocol ReportContextProviding : Sendable
```

Adds the log tail and device state to bug reports.

- `func reportContext() async -> ReportContext`  
  Recent log lines (at most 64 KB) and state such as screen, battery, network.

### `ReportPresenting`

```swift
@MainActor protocol ReportPresenting : AnyObject
```

Presents the full bug report flow (screenshot, markup).

- `@MainActor func presentReport(prefill: String?)`  
  Presents the report flow.

### `ReviewRequesting`

```swift
@MainActor protocol ReviewRequesting : AnyObject
```

Shows the native review prompt.

- `@MainActor func requestReview() async -> Bool`  
  Requests a review. Returns `false` if the prompt could not be shown.

### `StoreActionHandling`

```swift
@MainActor protocol StoreActionHandling : AnyObject
```

Opens Apple's App Store sheets for store action cards (the StoreKit module provides one).

- `@MainActor func perform(_ request: StoreActionRequest) async -> StoreActionOutcome`  
  Opens the sheet for `request` and returns once it closes.

### `PingFrontLogHandler`

```swift
typealias PingFrontLogHandler = @Sendable (PingFrontLogEntry) -> Void
```

Receives every SDK log line at or above `logLevel`, from any thread.

Keep it fast; hand off to your logger.

## PingFrontUI

### `PingFrontChatView`

```swift
@MainActor struct PingFrontChatView
```

The chat as a SwiftUI view, for a tab or a navigation destination.

```swift
TabView {
    PingFrontChatView().tabItem { Label("Help", systemImage: "bubble.left") }
}
```
Marks the chat visible while on screen (live updates, read receipts, no unread polling).

- `@MainActor var body: some View { get }`  
  The chat screen.
- `@MainActor init(topic: ChatTopic? = nil)`  
  Creates the embedded chat.  With a topic, its prefill goes into the composer.

### `PingFrontColor`

```swift
extension PingFrontColor
```

- `@MainActor init(_ color: Color)`  
  Resolves a SwiftUI color for light and dark mode, for `config.appearance.accent = PingFrontColor(myColor)`.

### `PingFrontModule`

```swift
extension PingFrontModule
```

- `@MainActor static var chatUI: PingFrontModule { get }`  
  The SwiftUI chat UI: SDK-presented sheet, `openChat()`, host app inference (AccentColor, name, icon).  Installed automatically by the `PingFront` product's `configure`.

### `View`

```swift
extension View
```

- `@MainActor func pingFrontChat(isPresented: Binding<Bool>, topic: ChatTopic? = nil, detents: Set<PresentationDetent> = [.large]) -> some View
`  
  Presents the chat as a sheet (form sheet on iPad, reading width capped at 640 pt).  Opens at the large detent by default; pass `[.medium, .large]` to open half height first.  ```swift Button("Help") { showChat = true }     .pingFrontChat(isPresented: $showChat, topic: .billing) ```

## PingFrontPush

### `PingFront`

```swift
extension PingFront
```

- `@MainActor func notificationPresentation(for notification: UNNotification) -> UNNotificationPresentationOptions`  
  How to present a notification while the app is in the foreground.  pingfront notifications are silent (`[]`) while the chat is visible, because the message already appears in the thread; otherwise, and for other notifications, `[.banner, .list, .sound]`.
- `@MainActor func requestPushAuthorization() async -> Bool`  
  Asks the person for notification permission (alert and sound, plus badge when the dashboard turned on the app icon badge, `usesAppBadge`) and, when granted, registers for remote notifications.  Forward the device token you then receive in `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` with `setPushToken(_:)`. Returns `true` when permission was granted.

### `PingFrontModule`

```swift
extension PingFrontModule
```

- `@MainActor static var push: PingFrontModule { get }`  
  Push helpers: presentation options and tap routing for pingfront notifications.  Installs a `UNUserNotificationCenterDelegate` only when the app has none, so it never replaces yours. If you have your own delegate, call `notificationPresentation(for:)` and `handlePush(userInfo:)` from it. Either way, forward the APNs device token from your AppDelegate with `PingFront.shared.setPushToken(_:)`; the SDK does not swizzle.

### `UIBackgroundFetchResult`

```swift
extension UIBackgroundFetchResult
```

- `@MainActor init(_ result: BackgroundPushResult)`  
  The system's result for a silent pingfront push.  ```swift func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async     -> UIBackgroundFetchResult {     if let result = await PingFront.shared.handleBackgroundPush(userInfo: userInfo) { return UIBackgroundFetchResult(result) }     return .noData  // not a pingfront push: your own handling } ```

## PingFrontStoreKit

### `PingFrontModule`

```swift
extension PingFrontModule
```

- `static var storeKit: PingFrontModule { get }`  
  StoreKit 2: reports the person's entitlement automatically, handles offer cards with a purchase sheet, opens Apple's App Store sheets for store action cards (manage subscriptions, billing issue, refund, offer code, restore), and shows the native review prompt for review cards.
- `static func storeKit(products: [String], onPurchase: (@MainActor @Sendable (Transaction) async -> Void)? = nil, subscriptionStore: Bool = false, shareAppTransaction: Bool = false) -> PingFrontModule`  
  StoreKit 2 with the product ids the team can offer in offer cards.  Each product becomes an `OfferSlot` whose id is the product id (characters outside `A-Z a-z 0-9 _ . -` become `_`).  The module never finishes your transactions: it only reads `Transaction.currentEntitlements` and `Transaction.updates`, so your own transaction handling keeps working unchanged.  Purchases from offer cards pass `PingFront.shared.storeAccountToken` as `appAccountToken`. Do the same in your own purchases so App Store notifications match the person.  - Parameters:   - products: Product ids the team can offer.   - onPurchase: Receives every verified transaction from an offer card purchase (which the SDK     started). Unlock the content, then call `transaction.finish()`; you own finishing it. Without     this handler the SDK finishes the transaction itself after it is verified, and your app sees     the new entitlement through `Transaction.currentEntitlements`.   - subscriptionStore: Offer cards for subscriptions also offer StoreKit's subscription store     (`SubscriptionStoreView` with your app's icon and name, tinted with the chat's accent) for apps     without a paywall of their own. Off by default.   - shareAppTransaction: Sends the verified `AppTransaction` (the original app version and purchase date)     as person traits `original_app_version` and `original_purchase_date`, for the team. Off by default:     nothing is sent without it. - Returns: The module, for `config.use(_:)`.

## PingFrontReports

### `ReportOptions`

```swift
@MainActor struct ReportOptions
```

What the reports module does.

- `@MainActor static let all: ReportOptions`  
  Everything.
- `@MainActor init(rawValue: Int)`  
  Wraps raw bits.
- `@MainActor static let logTail: ReportOptions`  
  Attach the last 10 minutes of this app's log (at most 64 KB).  Values your app logs as `.private` stay redacted.
- `@MainActor let rawValue: Int`  
  The raw bits.
- `@MainActor static let shakeToReport: ReportOptions`  
  Open the report flow when the person shakes the device (foreground only).

### `PingFrontModule`

```swift
extension PingFrontModule
```

- `@MainActor static var reports: PingFrontModule { get }`  
  Shake to report, a screenshot with markup, the log tail and device state.
- `@MainActor static func reports(_ options: ReportOptions) -> PingFrontModule`  
  Bug reports with options.  - Parameter options: What the module does; both by default. - Returns: The module, for `config.use(_:)`.

## PingFront (umbrella)

Re-exports every module above (`@_exported import`), so `import PingFront` is enough.

### `PingFront.configure(_:_:)`

```swift
@MainActor static func configure(_ appKey: String? = nil, _ build: (inout PingFrontConfiguration) -> Void = { _ in })
```

The one configure entry point: installs the chat UI (`.chatUI`) before your modules, then calls `PingFront.shared.start(appKey:configuration:)` (which Core-only apps call directly). Pass the public app key, or nothing to read `PingFrontAppKey` from Info.plist. Validates the key offline; configure sends nothing.

