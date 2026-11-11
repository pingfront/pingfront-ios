import Foundation
import Network
import StoreKit
import UserNotifications

#if canImport(UIKit)
    import UIKit
#endif

// The production context readers. None of them is a required-reason API (no disk space, no boot time, no
// file timestamps, no UserDefaults), each is cheap, and none of them runs at launch: the reporter calls them
// only while a request that goes out anyway is being built. Values are never logged.

extension ContextSource {
    /// The system readers: AppTransaction, UIKit traits and accessibility, NWPathMonitor, UIDevice battery,
    /// ProcessInfo and UNUserNotificationCenter.
    package static func system() -> ContextSource {
        let installSource = InstallSourceProbe()
        return ContextSource(
            build: { await installSource.build() },
            display: { await SystemContext.display() },
            paths: { SystemContext.paths() },
            lowPower: { ProcessInfo.processInfo.isLowPowerModeEnabled },
            health: { await SystemContext.health() },
            notifications: { await SystemContext.notifications() },
            memoryWarnings: { SystemContext.memoryWarnings() }
        )
    }
}

/// Where the build came from, from `AppTransaction.environment`.
///
/// The lookup runs in an owned task the first time it is asked for; until it resolves (or if it fails) a
/// local heuristic answers, so a session request never waits for it.
actor InstallSourceProbe {
    private var resolved: BuildContext.InstallSource?
    private var lookup: Task<Void, Never>?

    deinit { lookup?.cancel() }

    func build() -> BuildContext {
        if resolved == nil, lookup == nil {
            lookup = Task { [weak self] in
                let source = await Self.fromAppTransaction()
                await self?.resolve(source)
            }
        }
        let source = resolved ?? Self.fallback()
        return BuildContext(installSource: source, debuggable: Self.isDebugBuild || source == .development)
    }

    private func resolve(_ source: BuildContext.InstallSource?) { resolved = source }

    private static func fromAppTransaction() async -> BuildContext.InstallSource? {
        guard let result = try? await AppTransaction.shared else { return nil }
        switch result.unsafePayloadValue.environment {
        case .production: return .appStore
        case .sandbox: return .testflight
        case .xcode: return .development
        default: return nil
        }
    }

    /// The install source when AppTransaction has not answered yet.
    ///
    /// A debug build or a provisioning profile in the bundle (Xcode, ad hoc) is development; otherwise
    /// unknown until AppTransaction answers. (The receipt URL heuristic is deprecated API: not used.)
    private static func fallback() -> BuildContext.InstallSource? {
        if isDebugBuild { return .development }
        if Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil { return .development }
        return nil
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }
}

enum SystemContext {
    // MARK: Display

    @MainActor static func display() -> DisplayContext {
        var context = DisplayContext(languages: DisplayContext.languages(from: Locale.preferredLanguages))
        #if canImport(UIKit)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            let traits = scene?.traitCollection ?? UITraitCollection.current
            switch traits.horizontalSizeClass {
            case .compact: context.screenClass = .compact
            case .regular: context.screenClass = .regular
            default: break
            }
            let scale = Double(traits.displayScale)
            if (1...4).contains(scale) { context.scale = scale }
            switch traits.userInterfaceStyle {
            case .dark: context.darkMode = true
            case .light: context.darkMode = false
            default: break
            }
            let category = UIApplication.shared.preferredContentSizeCategory
            if category != .unspecified {
                if category.isAccessibilityCategory {
                    context.textSize = .accessibility
                } else {
                    context.textSize = category > .large ? .large : .default
                }
            }
            context.screenReader = UIAccessibility.isVoiceOverRunning
            context.reduceMotion = UIAccessibility.isReduceMotionEnabled
            context.boldText = UIAccessibility.isBoldTextEnabled
        #endif
        return context
    }

    // MARK: Connection

    /// The network path from `NWPathMonitor`.
    ///
    /// It uses the monitor's async sequence: no dispatch queue. Cancelling the
    /// consumer cancels the monitor. `ended` runs once the monitor's iteration has stopped (tests).
    static func paths(ended: (@Sendable () -> Void)? = nil) -> AsyncStream<ConnectionContext> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await path in NWPathMonitor() { continuation.yield(connection(from: path)) }
                continuation.finish()
                ended?()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func connection(from path: NWPath) -> ConnectionContext {
        let network: ConnectionContext.Network
        if path.status != .satisfied {
            network = .none
        } else if path.usesInterfaceType(.wifi) {
            network = .wifi
        } else if path.usesInterfaceType(.cellular) {
            network = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            network = .wired
        } else {
            network = .other
        }
        return ConnectionContext(network: network, constrained: path.isConstrained, expensive: path.isExpensive)
    }

    // MARK: Health

    /// Battery (rounded down to 10), charging and thermal state.
    ///
    /// Never free disk space: Apple's required
    /// reasons for disk space (E174.1, 85F4.1) forbid sending it or anything derived from it off the device.
    @MainActor static func health() -> HealthContext {
        var context = HealthContext(thermal: thermal(ProcessInfo.processInfo.thermalState))
        #if canImport(UIKit)
            // Battery monitoring is on only for this read; the host app's own setting is restored.
            let device = UIDevice.current
            let wasMonitoring = device.isBatteryMonitoringEnabled
            if !wasMonitoring { device.isBatteryMonitoringEnabled = true }
            let level = device.batteryLevel
            let state = device.batteryState
            if !wasMonitoring { device.isBatteryMonitoringEnabled = false }
            context.battery = HealthContext.batteryBucket(level)
            switch state {
            case .charging, .full: context.charging = true
            case .unplugged: context.charging = false
            default: break
            }
        #endif
        return context
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> HealthContext.Thermal? {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: nil
        }
    }

    /// Memory warnings, by notification (no dispatch source).
    static func memoryWarnings() -> AsyncStream<Void> {
        #if canImport(UIKit)
            AsyncStream { continuation in
                let task = Task {
                    let name = UIApplication.didReceiveMemoryWarningNotification
                    for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) { continuation.yield() }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        #else
            AsyncStream { $0.finish() }
        #endif
    }

    // MARK: Notifications

    static func notifications() async -> NotificationContext? {
        // UNUserNotificationCenter needs an app bundle (it traps in a bare test process).
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let authorization: NotificationContext.Authorization? =
            switch status {
            case .authorized: .authorized
            case .provisional: .provisional
            case .denied: .denied
            case .notDetermined: .notDetermined
            #if os(iOS)
                case .ephemeral: .ephemeral
            #endif
            @unknown default: nil
            }
        return authorization.map { NotificationContext(authorization: $0) }
    }
}
