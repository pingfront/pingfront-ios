# Changelog

## 1.0.0

- First release, through Swift Package Manager. iOS 17 or later, Swift 6, no third-party dependencies.
- The in-app chat in SwiftUI: an SDK-presented sheet (`openChat`), `.pingFrontChat(isPresented:)`, or
  `PingFrontChatView` embedded in your own navigation. UIKit apps present or push it the same way.
- Setup in one line (`PingFront.configure`), with the app key checked offline. A new install sends nothing until the
  chat opens or a listened moment fires.
- Identity (`identify`, `identify(token:)`), traits, moments, entitlements and offer slots.
- Optional modules: `.storeKit` (entitlements, offers and the review prompt), `.push` and `.reports` (shake to
  report a bug with a screenshot and log tail).
- Chat links (`handle(_:)`), saved links into your screens (`registerScreens`, `onScreen`), unread count, events and
  team actions.
- `PingFrontCore` alone for a chat UI of your own (`PingFront.shared.conversation`).
- 50 languages with right-to-left layout, Dynamic Type, iPad and foldable iPhones.
- Privacy manifests for `PingFrontCore` and `PingFrontUI`; `logout()` and `eraseMyData()`.
