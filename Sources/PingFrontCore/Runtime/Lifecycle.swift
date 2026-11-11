import Foundation

/// App lifecycle as an async sequence, from `NotificationCenter.notifications(named:)`.
///
/// Observes the platform notifications by their stable names, so this file needs neither UIKit nor AppKit.
package enum AppLifecycle {
    package enum Event: Sendable {
        case foreground, background
        /// The device was unlocked: the Keychain and protected files are readable again.
        case protectedDataAvailable
    }

    #if os(macOS)
        private static let foreground = Notification.Name("NSApplicationDidBecomeActiveNotification")
        private static let background = Notification.Name("NSApplicationDidResignActiveNotification")
        private static let protectedData = Notification.Name("NSApplicationProtectedDataDidBecomeAvailableNotification")
    #else
        private static let foreground = Notification.Name("UIApplicationWillEnterForegroundNotification")
        private static let background = Notification.Name("UIApplicationDidEnterBackgroundNotification")
        private static let protectedData = Notification.Name("UIApplicationProtectedDataDidBecomeAvailable")
    #endif

    /// Foreground and background transitions.
    ///
    /// Iterate from an owned task; cancelling it ends the stream.
    package static func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await _ in NotificationCenter.default.notifications(named: foreground).map({ _ in () }) {
                            continuation.yield(.foreground)
                        }
                    }
                    group.addTask {
                        for await _ in NotificationCenter.default.notifications(named: background).map({ _ in () }) {
                            continuation.yield(.background)
                        }
                    }
                    group.addTask {
                        for await _ in NotificationCenter.default.notifications(named: protectedData).map({ _ in () }) {
                            continuation.yield(.protectedDataAvailable)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
