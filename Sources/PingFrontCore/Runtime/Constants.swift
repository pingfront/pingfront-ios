import Foundation

/// Every delay and interval the SDK uses, in one place.
package enum Timing {
    /// Profile changes are coalesced into one `PATCH /me`.
    package static let patchWindow: Duration = .milliseconds(250)
    /// Drafts are saved after the person pauses typing.
    package static let draftSave: Duration = .milliseconds(400)
    /// Read receipts wait for a burst of messages to settle.
    package static let readReceipt: Duration = .milliseconds(500)
    /// Typing dots disappear when no update arrives for this long.
    package static let typingTimeout: Duration = .seconds(8)
    /// Opening the chat retries the session after a failure.
    package static let openRetry: Duration = .seconds(5)
    /// The access token is refreshed this long before it expires.
    package static let tokenMargin: Duration = .seconds(60)
    /// A 429 without `retryAfter` pauses its scope this long.
    package static let defaultCooldown: Duration = .seconds(30)
    /// Unread polling: fast for two minutes after activity, slow for an hour, then stop.
    package static let unreadFast: Duration = .seconds(20)
    package static let unreadFastFor: Duration = .seconds(120)
    package static let unreadSlow: Duration = .seconds(120)
    package static let unreadSlowFor: Duration = .seconds(3600)
    /// A connection change rides on the next request at most this often.
    package static let contextConnectionInterval: Duration = .seconds(300)
    /// A memory warning this recent makes session-start health report `warning`.
    package static let contextMemoryWindow: Duration = .seconds(600)
    /// The session request waits at most this long for the first network path.
    package static let contextPathWait: Duration = .milliseconds(300)
}

/// HTTP header names.
package enum HTTPHeader {
    package static let appKey = "PF-App-Key"
    package static let sdk = "PF-SDK"
    package static let wrapper = "PF-Wrapper"
    package static let protocolVersion = "PF-Protocol"
    package static let threadRevision = "PF-Thread-Rev"
    package static let authorization = "Authorization"
    package static let userAgent = "User-Agent"
    package static let accept = "Accept"
    package static let contentType = "Content-Type"
    package static let ifNoneMatch = "If-None-Match"
    package static let eTag = "ETag"
    package static let retryAfter = "Retry-After"
    package static let json = "application/json"
}

#if DEBUG
    /// Debug launch arguments (for coding agents and previews).
    ///
    /// Compiled out of release builds.
    package enum LaunchArgument {
        /// Sends "Setup check from <app>" and prints one PASS or FAIL line.
        package static let selfCheck = "-PingFrontSelfCheck"
        /// Opens the chat with offline fixture data: `-PingFrontPreview welcome|conversation`.
        package static let preview = "-PingFrontPreview"
    }
#endif
