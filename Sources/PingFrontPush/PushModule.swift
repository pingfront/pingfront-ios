public import PingFrontCore
public import UserNotifications
internal import os

#if os(iOS)
    import UIKit
#endif

extension PingFrontModule {
    /// Push helpers: presentation options and tap routing for pingfront notifications.
    ///
    /// Installs a `UNUserNotificationCenterDelegate` only when the app has none, so it never
    /// replaces yours. If you have your own delegate, call `notificationPresentation(for:)` and
    /// `handlePush(userInfo:)` from it. Either way, forward the APNs device token from your
    /// AppDelegate with `PingFront.shared.setPushToken(_:)`; the SDK does not swizzle.
    public static var push: PingFrontModule {
        PingFrontModule(id: ModuleID.push) { context in
            PushSupport.installDelegateIfNeeded(for: context.pingFront)
            let instance = context.pingFront
            context.setNotificationsRequest { await instance.requestPushAuthorization() }
            // The icon badge is the host's unless the dashboard turned on features.appBadge.
            let pingFront = context.pingFront
            context.run {
                for await event in pingFront.events {
                    guard case .unreadChanged(let count) = event, pingFront.usesAppBadge else { continue }
                    try? await UNUserNotificationCenter.current().setBadgeCount(count)
                }
            }
        }
    }
}

extension PingFront {
    /// How to present a notification while the app is in the foreground.
    ///
    /// pingfront notifications are silent (`[]`) while the chat is visible, because the message
    /// already appears in the thread; otherwise, and for other notifications, `[.banner, .list, .sound]`.
    public func notificationPresentation(for notification: UNNotification) -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        guard isPingFrontPush(userInfo: userInfo) else { return [.banner, .list, .sound] }
        pushReceived(userInfo: userInfo)
        return PushDelegate.options(isPingFront: true, chatVisible: isChatVisible, appBadge: usesAppBadge)
    }

    /// Asks the person for notification permission (alert and sound, plus badge when the dashboard
    /// turned on the app icon badge, `usesAppBadge`) and, when granted, registers for
    /// remote notifications.
    ///
    /// Forward the device token you then receive in
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` with `setPushToken(_:)`.
    /// Returns `true` when permission was granted.
    public func requestPushAuthorization() async -> Bool {
        do {
            // Badge permission only when the dashboard turned the pingfront badge on.
            let options: UNAuthorizationOptions = usesAppBadge ? [.alert, .badge, .sound] : [.alert, .sound]
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
            #if os(iOS)
                if granted { UIApplication.shared.registerForRemoteNotifications() }
            #endif
            return granted
        } catch {
            Log.push(.error)?.error("Notification permission request failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }
}

/// Owns the delegate installed by the push module.
enum PushSupport {
    /// Retained here: `UNUserNotificationCenter.delegate` is weak.
    static var delegate: PushDelegate?

    static func installDelegateIfNeeded(for pingFront: PingFront) {
        let center = UNUserNotificationCenter.current()
        guard center.delegate == nil else {
            Log.push(.info)?.info(
                "The app has its own notification delegate; call PingFront.shared.notificationPresentation(for:) and handlePush(userInfo:) from it."
            )
            return
        }
        let delegate = PushDelegate(pingFront: pingFront)
        self.delegate = delegate
        center.delegate = delegate
    }
}

/// Routes foreground presentation and taps for pingfront notifications.
///
/// Main actor, with a `@preconcurrency` conformance (the protocol predates Swift concurrency and its
/// parameters aren't Sendable): the Objective-C bridge of the tap handler hops to the main actor, so UIKit's
/// completion handler runs on the main thread, which UIKit asserts. A nonisolated version finished on a
/// background thread, and the app aborted when a notification was tapped while it came to the foreground.
@MainActor
final class PushDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    /// The SDK instance the module was installed into.
    let pingFront: PingFront

    init(pingFront: PingFront) { self.pingFront = pingFront }

    /// Nonisolated, as before: the banner decision must not wait for the main actor (it reads the notification
    /// here and hops only for SDK state).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
        let isPingFront = PushPayload.isPingFront(notification.request.content.userInfo)
        return await Self.presentationOptions(isPingFront: isPingFront, payload: payload, pingFront: pingFront)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let payload = PushPayload(userInfo: response.notification.request.content.userInfo) else { return }
        await Self.openFromTap(payload, pingFront: pingFront)
    }

    /// Silent while the chat shows pingfront messages already; a banner otherwise; the badge only with
    /// `features.appBadge`.
    ///
    /// Safe from any executor.
    nonisolated static func presentationOptions(isPingFront: Bool, payload: PushPayload? = nil, pingFront: PingFront) async
        -> UNNotificationPresentationOptions
    {
        guard isPingFront else { return [.banner, .list, .sound] }
        return await MainActor.run {
            if let payload { pingFront.engine?.pushReceived(payload) }
            return options(isPingFront: true, chatVisible: pingFront.isChatVisible, appBadge: pingFront.usesAppBadge)
        }
    }

    nonisolated static func options(isPingFront: Bool, chatVisible: Bool, appBadge: Bool) -> UNNotificationPresentationOptions {
        guard isPingFront else { return [.banner, .list, .sound] }
        if chatVisible { return [] }
        return appBadge ? [.banner, .list, .sound, .badge] : [.banner, .list, .sound]
    }

    /// A tap on a pingfront notification opens the chat (message and ping kinds).
    ///
    /// Safe from any executor.
    nonisolated static func openFromTap(_ payload: PushPayload, pingFront: PingFront) async {
        await MainActor.run {
            guard payload.kind != .config else { return }
            pingFront.engine?.pushOpened()
            pingFront.openChat()
        }
    }
}
