#if os(iOS)
    public import PingFrontCore
    public import UIKit

    extension UIBackgroundFetchResult {
        /// The system's result for a silent pingfront push.
        ///
        /// ```swift
        /// func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        ///     -> UIBackgroundFetchResult
        /// {
        ///     if let result = await PingFront.shared.handleBackgroundPush(userInfo: userInfo) { return UIBackgroundFetchResult(result) }
        ///     return .noData  // not a pingfront push: your own handling
        /// }
        /// ```
        public init(_ result: BackgroundPushResult) {
            switch result {
            case .newData: self = .newData
            case .noData: self = .noData
            case .failed: self = .failed
            }
        }
    }
#endif
