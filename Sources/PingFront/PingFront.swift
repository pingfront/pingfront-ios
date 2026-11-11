// The default product: `import PingFront` exposes Core, the chat UI and the opt-in modules.
@_exported public import PingFrontCore
@_exported public import PingFrontStoreKit

#if canImport(UIKit)
    @_exported public import PingFrontUI
    @_exported public import PingFrontReports
    @_exported public import PingFrontPush
#endif

extension PingFront {
    /// Configures the SDK and installs the chat UI.
    ///
    /// Pass the public app key, or nothing to read
    /// `PingFrontAppKey` from Info.plist. Validates the key offline; no network until first use.
    ///
    /// ```swift
    /// PingFront.configure("pk_live_…")
    ///
    /// PingFront.configure("pk_live_…") { config in
    ///     config.topics = [.billing, .bug, .idea]
    ///     config.appearance.accent = .indigo
    ///     config.use(.storeKit, .push, .reports)
    ///     config.logLevel = .debug
    /// }
    /// ```
    @MainActor
    public static func configure(_ appKey: String? = nil, _ build: (inout PingFrontConfiguration) -> Void = { _ in }) {
        var configuration = PingFrontConfiguration()
        #if canImport(UIKit)
            configuration.use(.chatUI)
        #endif
        build(&configuration)
        shared.start(appKey: appKey, configuration: configuration)
    }
}
