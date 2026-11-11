# pingfront for iOS

In-app support chat and proactive messages for iOS 17+. Your team talks with people inside your app,
and can reach them first ("pings") at the right moment. Swift 6, no third-party dependencies.

- [Install](#install)
- [Set up in one line](#set-up-in-one-line)
- [Options](#options)
- [Show the chat](#show-the-chat)
- [iPhone Duo and other foldables](#iphone-duo-and-other-foldables)
- [Links into the chat](#links-into-the-chat)
- [Identify the person](#identify-the-person)
- [Moments, offers, entitlements](#moments-offers-entitlements)
- [Push](#push)
- [Bug reports](#bug-reports)
- [Unread count and events](#unread-count-and-events)
- [Team actions](#team-actions)
- [Privacy, logout and erase](#privacy-logout-and-erase)
- [Build your own UI](#build-your-own-ui)
- [For coding agents](#for-coding-agents)
- [Products](#products)

See also [REFERENCE.md](REFERENCE.md) (every public symbol), [CHANGELOG.md](CHANGELOG.md), and the guides at
https://pingfront.sh/docs, starting with the [iOS quickstart](https://pingfront.sh/docs/quickstart-ios). MIT licensed
(see `LICENSE`).

## Install

In Xcode, choose File > Add Package Dependencies, enter `https://github.com/pingfront/pingfront-ios`, and add the
**PingFront** product to your app target. In a `Package.swift`, depend on
`.package(url: "https://github.com/pingfront/pingfront-ios", from: "1.0.0")` and add
`.product(name: "PingFront", package: "pingfront-ios")` to your target. iOS 17 or later, Xcode 26 or later.

Swift Package Manager is the only install path; there are no CocoaPods pods. React Native apps still run
`pod install`: the bridge's podspec pulls this package in through Swift Package Manager.

## Set up in one line

```swift
import PingFront

@main
struct MyApp: App {
    init() { PingFront.configure("pk_live_…") }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

`PingFront.configure()` with no argument reads `PingFrontAppKey` from Info.plist.

`configure` sends nothing. The key is checked offline (CRC-32 check characters). A mistyped key
never fails silently: debug builds show a red banner in the chat with the exact problem, log a fault,
and set `PingFront.shared.configurationProblem`. Release builds log the problem and disable the SDK.

What can reach the network, and when:

- A session is created lazily: on the first chat open, a moment a play listens to, a push open, a bug
  report, or `prepare()`.
- `moment()` first fetches the list of listened moments (app key only, cached 5 minutes, no session).
  Only a listened moment is sent, and only that creates a session.
- Identity, traits, entitlement, offers and the push token wait in memory until a session exists.
- Foreground unread checks run only once this install already has a session.

Apps that use `PingFrontCore` alone (their own UI) start the SDK with
`PingFront.shared.start(appKey: "pk_live_…", configuration: config)`; `PingFront.configure` is the same
plus the chat UI.

## Options

Every option has a default. Each look field is resolved on its own: the value published in the
dashboard wins, then the value set here in code, then what the SDK infers from your app (AccentColor,
name, icon), then the SDK default. The dashboard sends only the fields you set there, so anything you
leave unset in the dashboard keeps your code value.

The app icon in the chat is your app's own icon (the bundle's `CFBundleIcons`); without one (a test target, a bare
project) it is the app's icon from the dashboard (`appIconUrl`, the icon of its App Store or Google Play listing), and
without either, the first letter of the app's name. The dashboard has no icon upload.

```swift
PingFront.configure("pk_live_…") { config in
    config.topics = [.billing, .bug, .idea]          // up to 6; or ChatTopic(id:label:symbol:prefill:)
    config.appearance.accent = .indigo               // default: your AccentColor asset
    config.appearance.corners = .soft                // .round (18 pt), .soft (12), .square (6)
    config.appearance.font = .rounded                // .system, .rounded, .serif
    config.appearance.headerStyle = .team            // .person, .team, .app
    config.appearance.replyExpectation = "Usually replies within a few hours"   // default: "Usually replies within a day"
    config.use(.storeKit, .push, .reports)           // optional modules
    config.logLevel = .debug                         // .off, .error, .info (default), .debug: request
                                                     // paths and statuses, never bodies or tokens
    config.logHandler = { entry in                   // also send SDK lines to your logger; ids, names,
        AppLog.write("[pingfront/\(entry.category)] \(entry.message)")  // URLs and input arrive as <private>
    }
    config.language = "pt-BR"                        // your app's own language picker; nil follows the system
}
```

The chat feels like Messages: a centered contact header, tailed bubbles, the typing bubble,
Delivered/Read under your last message, and a capsule composer. The person's bubbles use your
AccentColor (systemBlue if you have none). Text on the accent is picked by contrast (white
whenever it reaches 3:1, with the accent deepened to AA), and colors that would make body text
unreadable are nudged until they pass WCAG AA. Use any SwiftUI color with
`PingFrontColor(Color.mint)` or hex with `PingFrontColor(light: "#3550E6", dark: "#7D91FF")`.

## Show the chat

```swift
// Anywhere: an SDK-presented sheet (form sheet on iPad).
PingFront.shared.openChat()
PingFront.shared.openChat(topic: .billing)
PingFront.shared.closeChat()

// SwiftUI sheet (large detent; pass detents: [.medium, .large] to open half height).
Button("Help") { showHelp = true }
    .pingFrontChat(isPresented: $showHelp, topic: .bug)

// Embedded in a tab or navigation stack.
PingFrontChatView()
    .tabItem { Label("Help", systemImage: "bubble.left") }
```

`PingFront.shared.isChatVisible` is observable. Each chat on screen counts once, the SDK's sheet and every embedded
`PingFrontChatView`: closing the sheet while an embedded chat shows leaves it `true`, and `.chatOpened` / `.chatClosed`
mark the first chat appearing and the last one going. While an embedded chat is on screen, `openChat`, a chat link, a
push tap and a moment that opens the chat focus it instead of presenting a second one.

**UIKit apps** call `PingFront.configure` in `application(_:didFinishLaunchingWithOptions:)` and open the chat
from any view controller; nothing else changes.

```swift
// The SDK finds the top view controller and presents its own sheet.
PingFront.shared.openChat(topic: .billing)

// Or push the chat like any other screen.
let help = UIHostingController(rootView: PingFrontChatView())
navigationController?.pushViewController(help, animated: true)
```

Links in messages are tappable and open in an in-app Safari view; a message that is only a link gets
a preview, fetched on the device with LinkPresentation (the URL is never sent to pingfront). Handle
deep links yourself with `PingFront.shared.onLink = { url in url.scheme == "myapp" ? route(url) : false }`.
Photos open full screen (pinch to zoom, swipe down to close, share).

## iPhone Duo and other foldables

The chat sizes itself from the space it gets, never from the device, idiom or orientation, so it follows a
foldable iPhone through every pose (closed, open, folded like a book, propped like a laptop), every rotation and
both halves of Split View, as it does on iPad.

What the SDK does:

- **Sheet.** `openChat()` presents a form sheet: the large-detent sheet in compact width (the outer display) and a
  centered card of at most 640 × 820 pt in regular width (the inner display, iPad). Folded like a book, the system
  moves the card beside the fold. `.pingFrontChat(isPresented:)` is a SwiftUI sheet that adapts the same way.
- **System bars.** In a sheet the close control is a `cancellationAction` item in the system's navigation bar, so on
  the outer display it moves into the vertical bar at the side with the rest of the system's controls. It is the
  system's own close button (`Button(role: .close)` on iOS 26 and later, `UIButton(type: .close)` before), so its x is
  in the label colour: your accent tints the chat's content (links, chips, the send button), never the system bar. The contact
  header stays the chat's own content and shares the bar's row, so the bar adds no height. Embedded, the chat uses
  your bars.
- **Readable column.** `PingFrontChatView` at full width keeps the thread at most 640 pt wide. When a fold runs down
  the chat, the header, thread and composer move together into the region beside it with more room, so no bubble
  straddles the fold and the composer is never in it. Propped like a laptop, the thread scrolls across the fold
  (scrolling content may), the composer is already on the lower half, and the welcome keeps its words above the
  fold and moves its topic buttons below it. Flat or closed, nothing moves.
- **State.** Folding changes only the column's padding, so the scroll position, the draft, the keyboard and an open
  photo stay as they were. Marks drawn on a bug report's screenshot stay on their spot when the sheet resizes.
- **Any Xcode.** The SDK builds with any Xcode for iOS 17 and later. It reads the system's folds (reserved regions)
  only when your app is built with the iOS 27.1 SDK (Xcode 27.1 or later) and runs on iOS 27.1 or later; otherwise
  the chat keeps its centered column, which the system's sheets still move out of the fold.

What your app should do:

- **Build with Xcode 27.1.** Built with the iOS 26 SDK or earlier, your app sits centered on the inner display with
  empty space around it; with the iOS 27.0 SDK it fills most of the display but keeps clear of the status bar's
  side. With the iOS 27.1 SDK it fills the display, its bars go vertical on the outer display and in landscape, and
  the SDK sees the folds.
- **Pass incoming URLs to `handle(_:)`** from `onOpenURL` or your scene delegate ([Links into the chat](#links-into-the-chat)),
  so a chat link opens the chat whichever display and window it arrives in.
- **Use the system containers.** Present with `openChat()` or `.pingFrontChat(isPresented:)`, or put
  `PingFrontChatView` in a `NavigationStack`, a `TabView`, a `NavigationSplitView` detail or a
  `UINavigationController`: they lay out around the fold and move their bars to the side. Don't wrap the chat in a
  hand-made bar or a scroll view.
- **Don't count on orientation locks.** The inner display rotates whatever `UISupportedInterfaceOrientations` says.

Check it on the iPhone Duo simulator (Xcode 27.1): open, close, rotate and fold it in Device Hub, and drag the app to
each side with the home indicator for Split View.

## Links into the chat

A link can open the chat: an email from your team, a "Message us" QR code, a "Chat with us in the app" button on your
website, a Shortcut, or a push you send through your own provider. Add `pingfront=chat` (or `pingfront=report` for the
bug report) to a URL your app already opens, and hand incoming URLs to `PingFront.shared.handle(_:)`:

```text
https://example.com/help?pingfront=chat            your universal link domain
myapp://support?pingfront=chat&topic=billing       your custom scheme
```

The SDK claims no domain or scheme of its own; your app's universal links and URL types stay yours. `handle(_:)`
returns `true` when the URL was a chat link (it opened the chat or the report) and `false` for anything else, so route
those as before. `topic` applies only when it is the id of one of the chat's topics; other parameters are ignored, and
a link never puts text in the composer. Handling a link is the same as `openChat(topic:)`: the session starts when the
chat appears, and the call sends nothing. Called before `configure`, it keeps the link and opens it right after.

```swift
// SwiftUI: universal links and your custom scheme both arrive in onOpenURL.
WindowGroup {
    ContentView()
        .onOpenURL { url in
            if PingFront.shared.handle(url) { return }
            router.open(url)
        }
}
```

```swift
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
```

Check it on a simulator with `xcrun simctl openurl booted 'myapp://support?pingfront=chat'` (confirm the system's
"Open in" prompt the first time): the chat opens. The exact rules are in [Chat links](https://pingfront.sh/docs/chat-links).

## Saved links into your screens

The team can send link cards that open a screen of your app (saved links, in the dashboard's Offers, Links tab).
Register the screens this build can open and handle the taps:

```swift
PingFront.shared.registerScreens([
    AppScreen(id: "settings.sound", title: "Sound settings"),   // the title is for the team's dashboard only
    AppScreen(id: "plans/yearly"),
])

PingFront.shared.onScreen = { screen in                           // main actor; may be async
    router.open(screen.id, params: screen.params)                 // params: [String: String]
    return true                                                   // false: the app can't open it now
}
```

- Ids match `^[A-Za-z0-9][A-Za-z0-9_./:-]{0,99}$`. A debug build stops on a bad id, a release build drops (and
  logs) it; each id counts once, at most 200. A later call replaces the list; `[]` registers none.
- Registering sends nothing. The list rides on `POST /v1/sessions`, and on a refresh or `PATCH /v1/me` only when it
  or the app version changed since this install last sent it.
- A tap on a card for a registered screen calls `onScreen`, awaited at most 10 seconds (no answer counts as
  `false`). A screen this build didn't register opens the card's `url` instead, when it has one (through `onLink`,
  then Safari). The chat reports each tap once, as opened or failed (`not_handled`, `unknown_screen`,
  `cannot_open`), so the team sees which links work. The rules are in
  [Saved links](https://pingfront.sh/docs/offers#saved-links).
- A link card never opens a `javascript:`, `data:`, `vbscript:`, `file:`, `blob:`, `about:`, `content:` or `intent:` URL, whatever the card says, and never hands one to `onLink`; the
  tap reports `cannot_open`. Another scheme opens through the system only when it is one of your app's own
  (`CFBundleURLSchemes` in its Info.plist); `onLink` may still take any other.
- `onLink` may be `async` (a bridge waiting for JavaScript or Dart, a router that loads first); a plain closure still
  works. The SDK awaits it at most 10 seconds: no answer counts as `false`, the handler is cancelled and its late
  answer ignored, and the link opens the default way. A link card reports what really happened, so one `onLink`
  declines and nothing else opens is `cannot_open`. A link in a message waits in a task the SDK owns: a newer link
  replaces it, and `logout()` cancels it.
- `await PingFront.shared.openLinkByDefault(url)` opens a URL the way the chat does when `onLink` declines it (the
  rule above, then Safari for `http` and `https` or the system for one of your schemes) and returns whether
  something opened it. The SDK calls it itself after `onLink`, so the React Native and Flutter bridges open no links
  and keep no timers; call it from a chat UI of your own.
- Card reports (taps, picks, ratings) are queued on disk, each with its own `clientId`, and retried until the server
  answers: no answer, 408, 429, 500, 502, 503 and 504 retry with backoff, and at once when the app returns to the
  foreground or the connection comes back. The server records a `clientId` once, so a retry never counts twice. A
  report is dropped after 24 hours or 10 attempts, and `logout()` clears the queue.

## Identify the person

```swift
PingFront.shared.identify(userId: user.id, name: user.name, email: user.email)  // named
PingFront.shared.identify(token: jwtFromYourBackend)                             // verified: one thread across devices
PingFront.shared.setTraits(["plan": "pro", "city": "Izmir"])
```

These calls return immediately. Changes are coalesced for 250 ms and sent as one `PATCH /me` with
only the changed fields, and only once a session exists. Identity and traits are kept in memory;
the install secret and verified user id live in the Keychain (this device only).

## Moments, offers, entitlements

```swift
// Report app moments. Only moments a play listens to are sent (list cached for 5 minutes).
let result = await PingFront.shared.moment("paywall_closed", props: ["screen": "plans", "seconds": 42])
// .openRequested(presented: true): the server asked to open the chat and the SDK did. With
// config.presentsChatForMoments = false it is .openRequested(presented: false): present it yourself.

// Offers the team can send as cards.
PingFront.shared.setOffers([OfferSlot(id: "yearly_winback", title: "Pro yearly", kind: .winback)])
PingFront.shared.onOffer = { request in showPaywall(request.offerId) }

// Subscription state (automatic with `.storeKit`).
PingFront.shared.setEntitlement(Entitlement(state: .trial, productId: "pro_yearly", renewsAt: trialEnd))
```

With `config.use(.storeKit(products: ["pro_monthly", "pro_yearly"]))` the SDK reads entitlements from
StoreKit 2, reports the products as offer slots, buys them from offer cards, and shows the native
review prompt for review cards. It never finishes your transactions: it only reads
`Transaction.currentEntitlements` and `Transaction.updates`. A purchase it starts from an offer card
goes to your `onPurchase` handler (`.storeKit(products:onPurchase:)`), and you finish it after unlocking;
without a handler the SDK finishes it. Store detections (trial started, renewals, cancellations,
expiry, billing problems, refunds) are sent as store moments with the signed transaction, only for
store events a play listens to. The sweep of current entitlements at launch runs only for an install that
already has a session, so a new install still sends nothing at launch; lapses while the app runs are always
reported. App Store Server Notifications stay the source of truth.

Offer cards can carry a store offer (`OfferRequest.storeOffer`):

- **promotional**: the module asks the server to sign it (`POST /offers/signature`) and buys with
  `promotionalOffer(_:compactJWS:)` plus the signed `appAccountToken`. If the offer was not sent to this person
  (404) or the app has no In-App Purchase key (409), the person still gets the regular price.
- **winback** (iOS 18+): bought with `winBackOffer` when StoreKit says the person is eligible.
- **code**: opens Apple's offer code redemption sheet.
- **intro**: the store applies it to eligible people.

The card shows the store's offer price with the regular price struck through, and "Current plan" when the
person already owns the product. With your own paywall (RevenueCat, Superwall), `onOffer` receives the same
`storeOffer` so you can show the promo there, or add a
[vendor adapter](https://pingfront.sh/docs/modules#revenuecat-superwall-and-adapty) (one package per vendor:
`pingfront-ios-revenuecat`, `pingfront-ios-superwall`, `pingfront-ios-adapty`), which reports your paywalls as offer
slots and opens them from offer cards.

`setOffers(_:)` reports your own paywalls. Modules and adapters report theirs separately, so the lists add up
instead of replacing each other; `setOffers(_:from:)` replaces one source's slots.

**StoreKit's own views in the chat** (with `.storeKit`, unless you set `onOffer` for your own paywall):

- Offer cards show StoreKit's product view: the real price, the offer price and the system buy button (iOS 26:
  `SubscriptionOfferView`; earlier: `ProductView`), preferring the card's promotional, win-back or intro offer.
  A plan in the group the person already subscribes to says "Switch to yearly"; the store handles the change.
- Ask to Buy and Strong Customer Authentication show "Waiting for approval" on the card instead of failing.
- `.storeKit(products:subscriptionStore: true)` adds "See all plans", StoreKit's `SubscriptionStoreView` for the
  product's group with your app's icon and name, for apps without a paywall of their own.
- **Plan status:** a line at the end of the thread, such as "Ledgerly Plus renews 12 Nov". A payment problem reads
  "Payment issue: update by 3 Nov" with an in-app "Update payment method" button. The server's plan (from store
  events) comes first; the device's StoreKit status only fills in when the server has none.
- **Store action cards** (`store_action`) open Apple's own sheets in the app: manage subscriptions, the billing
  issue (Apple's billing message when one is waiting), a refund request, offer code redemption, and restore
  purchases. When the sheet closes the SDK compares the App Store state and adds a receipt line, such as
  "Payment method updated", and reports it (`POST /v1/store-actions`) so the team sees it in the thread too. Without `.storeKit` they open Apple's web pages.
- StoreKit's own messages (billing issue, price-increase consent, win-back offers) wait while the chat is open and
  show when it closes; each is reported as the `store_message` moment with a `reason`, so plays can follow up.
- `.storeKit(products:shareAppTransaction: true)` sends the verified original app version and purchase date as the
  `original_app_version` and `original_purchase_date` traits. Off by default: nothing is sent without it.

Review cards ask Apple's review prompt first (Apple decides whether it shows, and may show nothing). A second
tap opens the App Store's write-a-review page in the App Store app (the card's store link, else the App Store id the
team set for the app, `AppConfig.appStoreId`).

Pass `PingFront.shared.storeAccountToken` as `appAccountToken` in your own purchases so App Store
notifications match the person:

```swift
let options: Set<Product.PurchaseOption> = PingFront.shared.storeAccountToken.map { [.appAccountToken($0)] } ?? []
let result = try await product.purchase(options: options)
```

## The composer

Like Messages: the field grows until the composer reaches the header, then scrolls; the keyboard dismisses
interactively; on an iPad keyboard Return sends and Shift-Return adds a line. The "+" menu offers the photo library,
the camera (when the app declares `NSCameraUsageDescription`), a copied photo (iOS asks the person to allow the paste
first), and a bug report. As in Messages, Paste in the field's own menu takes a copied photo too, with no prompt; on iPad you can drop photos onto the composer. Staged photos show as thumbnails you can remove. Near the 4,000 code-point limit a counter appears, and
sending stops over it. A topic's starter never replaces what the person typed, and the draft stays when the chat
closes. Offline, rate limits, a blocked person and a paused app each say what is going on. Text scales to AX5.

## Push

```swift
config.use(.push)                                   // optional: taps and foreground presentation

let granted = await PingFront.shared.requestPushAuthorization()

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
```

**With OneSignal, Braze, Expo or another push library.** When another library is the notification center's
delegate, pingfront's own pushes still go to the device token you pass to `setPushToken(_:)`: pass the raw APNs
token, not the library's own subscription id. Where the library calls your code for a tap, hand the payload to
pingfront first; `PingFront.shared.isPingFrontPush(userInfo:)` tells the payloads apart without acting:

```swift
func handleNotificationTap(_ userInfo: [AnyHashable: Any]) {
    if PingFront.shared.handlePush(userInfo: userInfo) { return }  // pingfront's: the chat opens
    // the other library's handling
}
```

A push you send yourself through that library can open the chat too: give it a chat link as its URL or deep link
(`myapp://support?pingfront=chat`) and pass the URL to `PingFront.shared.handle(_:)` when it reaches your app
([Links into the chat](#links-into-the-chat)).

When the dashboard publishes a new chat look, the server sends a silent config push (`kind: config`,
`content-available`, no alert). With the Remote notifications background mode on,
`handleBackgroundPush(userInfo:)` refetches the app config (look and settings) and returns `.newData`,
`.noData` or `.failed`, and `nil` for pushes that aren't pingfront's. It shows nothing and never starts a session; an install that never had one does nothing.

`setPushToken(nil)` clears the token when the person turns notifications off. `await PingFront.shared.closeChat()`
returns once the chat is gone, for bridges that chain presentations. `setPushToken(_:)` works without the `.push` module; the module only adds the notification delegate
(installed when your app has none) and `requestPushAuthorization()`. Payloads this SDK version does
not know (another `v`, a new kind) are ignored.

The app icon badge is yours: pingfront never sets it and asks for badge permission only when the
dashboard turned on the pingfront badge (`features.appBadge`); then pushes carry the unread count.
`PingFront.shared.unreadCount` updates when a pingfront push arrives and on foreground.

Without push, the SDK polls `GET /unread` while the app is in the foreground, once this install has a
session: every 20 s for two minutes after activity, then every two minutes for an hour, then stops.

## Bug reports

```swift
config.use(.reports)                                // shake to report, screenshot markup, log tail
config.use(.reports([.logTail]))                    // or pick: .shakeToReport, .logTail
PingFront.shared.openReport()                       // open the flow from a button
try await PingFront.shared.reportBug(text: "Sync stopped", screenshot: pngData)
```

Shake to report reads the accelerometer while your app is in the foreground. In the simulator, which has none, use
Device > Shake (Control-Command-Z).

## Unread count and events

```swift
Text("Help").badge(PingFront.shared.unreadCount)    // @Observable

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
```

The full set: `chatOpened`, `chatClosed`, `messageReceived`, `messageSent` (no text, only its length and
photo count), `cardOpened` (offer, review, link, choices, rating, report, store action), `unreadChanged`,
`sessionStarted`, `identityProblem`, `offerRequested`, `offerCompleted`, `lookChanged`,
`configurationProblem`, `reportSent` and `sessionRevoked`. Keep a `default:` case: later versions add events.

`sessionRevoked` means the install was logged out or erased elsewhere (the refresh answered `session_revoked`). The
SDK drops everything local to that install by design, messages still waiting to send included: they belonged to the
revoked session and are never sent under a new one. Nothing is shown to the person; the next chat open starts a new
session as a guest (the `auth-refresh-revoked` protocol scenario).

When the team resets the conversation from the dashboard (the live `thread_reset`), the chat empties in place with no
event: the thread, its revision and the unread count go, the draft and unsent messages stay (the next message starts a
new thread), and the socket stays open.

Set `PingFront.shared.language = "de"` whenever the person picks a language in your app's own picker; the
chat, its right-to-left layout, the team's localized texts and the server's lines follow it. `nil` goes back
to the system language.

The chat ships in [50 languages](https://pingfront.sh/docs/localization):
Arabic, Bengali, Bulgarian, Catalan, Chinese (Simplified, Traditional and Hong Kong), Croatian, Czech, Danish,
Dutch, English, Finnish, French (France and Canada), German, Greek, Gujarati, Hebrew, Hindi, Hungarian, Indonesian,
Italian, Japanese, Kannada, Korean, Malay, Malayalam, Marathi, Norwegian Bokmål, Odia, Persian, Polish, Portuguese
(Brazil and Portugal), Punjabi, Romanian, Russian, Slovak, Slovenian, Spanish (Spain and Latin America), Swedish,
Tamil, Telugu, Thai, Turkish, Ukrainian, Urdu and Vietnamese.

## Team actions

A teammate can fix something for the person from the inbox ("Fix it for them"): extend a trial,
grant access, or run one of your own actions. Your app does the work and answers:

```swift
Task {
    for await action in PingFront.shared.teamActions {
        switch action.actionId {
        case "repair_sync":
            await sync.repair(bank: action.fields["bank"])
            await action.complete()           // the receipt line posts in the thread
        case "extend_trial":
            await entitlements.extend(until: action.until)
            await action.complete()
        default:
            await action.fail(message: "This app version can't do \(action.name) yet.")
        }
    }
}
```

- Each action id arrives once. Actions you haven't answered are replayed to a new stream, so start
  listening whenever suits you.
- They arrive live while the chat is connected. After a session starts and after every reconnect,
  the SDK also reads the pending ones (`GET /v1/team-actions`), so an action sent while the app was
  closed still arrives. Nothing is read before a session exists.
- `complete()` and `fail(message:)` are stored and retried until the server has them. The first answer
  wins. The `fail` message is shown to the team, never to the person (at most 200 characters).
  Answers for expired actions, or ones that aren't this person's, are dropped.
- When `ackRequired` is true, the receipt waits for `complete()`. The same action can also reach your
  server as a signed webhook; do the work in one place.
- Logout and erase forget delivered actions and queued answers.

On pingfront's Free plan (`AppConfig.features.branding`), the chat's welcome screen carries our
one-colour lockup on its own bar above the composer: 14 pt, faded, in the chat's own muted ink, so it
follows the app's palette in light and dark instead of carrying our pink. It is artwork
(`PingFrontLockup`, a template image from `brand/logo/lockup-mono.svg`), so no font or host style can
change its letters; the localized "Chat by pingfront" stays as its accessibility label. It never
appears inside a conversation, and Pro removes it.

## Privacy, logout and erase

```swift
PingFront.shared.logout()                 // see below; tells the server (retried until it succeeds)
try await PingFront.shared.eraseMyData()  // DELETE /me, then the same local wipe
let export = try await PingFront.shared.exportMyData()  // GET /me/export: the person's data as JSON
try await PingFront.shared.prepare()      // create the session now (for example after login)
```

Logout clears, on this device: the install id and secret (Keychain), the access token, identity,
traits, entitlement and offers staged for the server, the push registration, the thread and its
cache, unsent messages and their photos, the draft, the draft look, cached images and link previews,
the unread count and `storeAccountToken`. Anything still queued for the person is never sent after
logout, including a photo still being prepared and the result of an App Store sheet that was open. The next session
is a new guest. The device's push token is not the person's: the SDK keeps the last one your app passed and registers
it for the next install, so the next person gets notifications without your app passing it again (without a token, the
SDK checks for unread messages itself). `eraseMyData()` treats an install the server already erased
as success, so a retry after a lost response still wipes locally.

`exportMyData()` returns everything pingfront stores about the person (`GET /me/export`) as the server's
JSON bytes, a `PersonExport` (`format: pingfront.person.v1`): profile, devices, the thread with every
message, moments, store events and plays, with no secrets, push tokens or team notes. Save or share it as
it is; the SDK shows no UI and keeps no copy. Like `eraseMyData()` it needs a session but no identity. It is
limited to 5 an hour per install: past that it throws a `rate_limited` `PingFrontError` with scope
`.exports`, and calls fail fast with `coolingDown` until the wait is over.

When the app's retention deletes old photos, their messages stay and the chat shows "Photo removed" where
each photo was (`ImagePart.removed`); nothing is fetched.

`PingFrontCore` and `PingFrontUI` ship privacy manifests (`PrivacyInfo.xcprivacy`). No tracking, no advertising identifiers. Collected data is for App Functionality, and Product Interaction and Purchase History also for Analytics (play lift and revenue reports); the full list is in [Data and privacy](https://pingfront.sh/docs/data-and-privacy). Queued messages and
caches live in Application Support, excluded from backup, with file protection. Teammates' avatars are
also kept in Caches, so a chat opened after a relaunch shows their faces in the first frame instead of
initials. Photos shown in the thread are cached in memory only.

### What the SDK sends about the device

Besides the device facts (OS, model, app version, locale, time zone), the SDK sends a coarse
`device.context` so the dashboard's Context card is useful ([Person context](https://pingfront.sh/docs/person-context)). It never
makes a request for it, never sends it at launch, and never logs it. It goes only with requests the SDK
makes anyway: `POST /sessions`, `POST /sessions/refresh` and `PATCH /me`.

| Group | Fields (iOS) | When |
| --- | --- | --- |
| `build` | `installSource` (`app_store`, `testflight`, `development`, from `AppTransaction.environment`), `debuggable` | session start, then when it changes |
| `display` | `screenClass`, `scale`, `darkMode`, `textSize` (`default`, `large`, `accessibility`), `screenReader`, `reduceMotion`, `boldText`, the first 3 `languages` | session start, then when it changes |
| `connection` | `network` (`wifi`, `cellular`, `wired`, `none`, `other`), `constrained` (Low Data Mode), `expensive`, `lowPower` | session start, then on change, at most every 5 minutes, riding on the next request |
| `health` | `battery` (rounded down to 10), `charging`, `thermal`, `memoryPressure` | session start only |
| `notifications` | `authorization` | session start, then when it changes |

Session start means a new session, or the first request in a process that carries context (usually its first
refresh; for a new install, the request after the first answer, see below). The iOS SDK never sends free
disk space (`freeStorage`): Apple's required reasons for disk space don't allow it to leave the device.
The server derives a coarse place (country, region, city) from the session request's address, and it
never stores the address. Each group has a switch in the app's settings on the dashboard. The session
answer tells the SDK which groups to collect (`collect`), and the SDK keeps that answer with the
install. Until the first answer arrives it sends no device context at all, so nothing goes out for a group the app
turned off; the next request after the answer is the session start.

**Crash tool link.** To link a person to your crash reporter from the dashboard, set the trait
`crashReporterUserId` to the id you give that tool, and set the crash reporter's URL template in the
app's settings:

```swift
PingFront.shared.setTraits(["crashReporterUserId": crashUserId])
```

## Build your own UI

Add only **PingFrontCore** and use `PingFront.shared.conversation` (`@Observable`): `messages`,
`pending`, `timeline` (grouped rows), `team`, `policy`, `typing`, `live`, `draft`, and actions
`send(text:photos:)`, `retry(_:)`, `discard(_:)`, `loadOlder()`, `choose(_:on:in:)`, `rate(_:on:in:)`,
`open(_:in:)`, `markRead()` and `reload()`. `PingFront.shared.look` is the resolved look from the dashboard.

- `markRead()` marks the messages on screen as read (the team sees Read, `unreadCount` drops to 0). The SDK's chat
  does it by itself while visible; a custom UI calls it when the person has seen the thread. It sends nothing when
  there is nothing to mark or the app is paused.
- `await conversation.reload()` returns once the reload finished, for `.refreshable`; on failure a thread already on
  screen stays, and `phase` is `.failed` only when there is nothing to show.
- `PendingMessage.heldFor` (`.appPaused`, `.verificationRequired`) and `isHeld`: a message the server refused because
  the app is paused or wants a sign-in is held, not failed. It goes by itself, first, once sending reopens (even after
  a relaunch), and the messages behind it wait. The SDK's chat says "Not sent yet. It will send when the chat is
  back." or "… after you sign in." A blocked person's message is never held; it fails.
- `isServerUnreachable` is true when the device has a network but can't reach the service (it is down, a firewall, a
  captive portal); the SDK's chat then says "Can't reach the chat right now" instead of offline, and messages wait.

## For coding agents

Debug builds understand two launch arguments:

- `-PingFrontSelfCheck`: creates a session, sends "Setup check from <app>", waits for the server and
  prints one line: `PingFront self-check: PASS` or `PingFront self-check: FAIL <code>: <what to do>`
  (`key_invalid`, `key_unknown`, `network`, `app_paused`, `timeout`, …).
- `-PingFrontPreview welcome|conversation`: opens the chat with offline fixture data that shows
  every message part.

The same check is a public API, in every build, for tests and bridges (React Native, Flutter):
`let result = await PingFront.shared.selfCheck()` returns `SetupCheckResult` (`passed`, a stable `code`, `advice`,
and the one-line `line`). It carries no personal data.

## Products

| Product | Use it when |
| --- | --- |
| `PingFront` | Almost always. Core + chat UI, with the opt-in modules available through `config.use(...)`. |
| `PingFrontCore` | You build your own chat UI (also builds for macOS). |
| `PingFrontUI` | You assemble modules yourself. |
| `PingFrontPush`, `PingFrontStoreKit`, `PingFrontReports` | Opt-in modules, also re-exported by `PingFront`. |

## Enums and future versions

Public enums (`MomentResult`, `OfferOutcome`, `PingFrontEvent`, `MessagePart`, `Card`, `SendPolicy.Reason`, …)
may gain cases in minor releases. They are `@nonexhaustive`: from Swift 6.4 the compiler asks for an
`@unknown default` when you switch over one, and you should write it on earlier compilers too. Only `AppKey.Mode`,
`PushEnvironment` and `PingFrontVersion` can never grow. Values that vendors or the server extend freely are structs
with static members instead (`ErrorCode`, `RateScope`, `Entitlement.Source`), so unknown values are kept as is.

Types the SDK hands you to read (`Message`, `Author`, the parts and cards, `TeamMember`, `TypingIndicator`,
`PingFrontLogEntry`, …) have no public initializer, so they can gain properties in a minor release without breaking your
build. You build only what you hand the SDK: the configuration and look, entitlements, offer slots, store event
reports and report context.
