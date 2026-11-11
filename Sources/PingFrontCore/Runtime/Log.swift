package import os

/// Loggers for the SDK, gated by `PingFrontConfiguration.logLevel`.
///
/// Call sites ask for a logger at a level: `Log.network(.info)?.info("…")`. Below the configured level
/// the logger is `nil` and nothing is evaluated or written. Values that could identify a person or
/// grant access are interpolated `.private`; errors are logged through `PingFrontError.logDescription`.
///
/// A message is rendered once, with every `.private` value replaced by `<private>`, and that one safe
/// string goes to unified logging and to the host's `logHandler`. Private values never leave the call site.
package enum Log {
    package static let subsystem = "dev.pingfront.sdk"

    /// Log categories, one per area.
    package enum Category: String, CaseIterable, Sendable {
        case setup, session, network, live, outbox, look, storage, decoding, push, storekit
        case selfCheck = "self-check"
    }

    private struct State {
        var level = PingFrontLogLevel.info
        var handler: PingFrontLogHandler?
    }

    // A lock, not an actor: loggers are read synchronously at every call site, where awaiting an actor isn't possible.
    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let loggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })

    /// The configured level (set by `configure`).
    package static var currentLevel: PingFrontLogLevel {
        get { state.withLock { $0.level } }
        set { state.withLock { $0.level = newValue } }
    }

    /// The host's handler (set by `configure`); `nil` writes to unified logging only.
    package static var handler: PingFrontLogHandler? {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }

    /// The category's logger when `wanted` is enabled, else `nil`.
    package static func logger(_ category: Category, _ wanted: PingFrontLogLevel) -> SDKLogger? {
        let (level, handler) = state.withLock { ($0.level, $0.handler) }
        guard wanted != .off, level >= wanted, let logger = loggers[category] else { return nil }
        return SDKLogger(category: category, logger: logger, handler: handler)
    }

    package static func config(_ wanted: PingFrontLogLevel) -> SDKLogger? { logger(.setup, wanted) }
    package static func session(_ wanted: PingFrontLogLevel) -> SDKLogger? { logger(.session, wanted) }
    package static func network(_ wanted: PingFrontLogLevel) -> SDKLogger? { logger(.network, wanted) }
    package static func live(_ wanted: PingFrontLogLevel) -> SDKLogger? { logger(.live, wanted) }
    package static func outbox(_ wanted: PingFrontLogLevel) -> SDKLogger? { logger(.outbox, wanted) }
    package static func look(_ wanted: PingFrontLogLevel) -> SDKLogger? { logger(.look, wanted) }
    package static func storage(_ wanted: PingFrontLogLevel) -> SDKLogger? { logger(.storage, wanted) }
    package static func decoding(_ wanted: PingFrontLogLevel) -> SDKLogger? { logger(.decoding, wanted) }
    package static func push(_ wanted: PingFrontLogLevel) -> SDKLogger? { logger(.push, wanted) }
    package static func storekit(_ wanted: PingFrontLogLevel) -> SDKLogger? { logger(.storekit, wanted) }
    package static func selfCheck(_ wanted: PingFrontLogLevel) -> SDKLogger? { logger(.selfCheck, wanted) }
}

/// A category's logger: writes one redacted line to unified logging and to the host's handler.
package struct SDKLogger: Sendable {
    let category: Log.Category
    let logger: Logger
    let handler: PingFrontLogHandler?

    package func error(_ message: LogMessage) { write(.error, .error, message) }
    package func fault(_ message: LogMessage) { write(.fault, .error, message) }
    package func notice(_ message: LogMessage) { write(.default, .info, message) }
    package func info(_ message: LogMessage) { write(.info, .info, message) }
    package func debug(_ message: LogMessage) { write(.debug, .debug, message) }

    private func write(_ type: OSLogType, _ level: PingFrontLogLevel, _ message: LogMessage) {
        let text = message.rendered
        logger.log(level: type, "\(text, privacy: .public)")  // guard:allow: already redacted by LogMessage
        handler?(PingFrontLogEntry(level: level, category: category.rawValue, message: text))
    }
}

/// Whether an interpolated value may appear in a log line.
package enum LogPrivacy: Sendable {
    /// Constant-like values: codes, statuses, counts, endpoint names.
    case `public`
    /// Anything that could identify a person or grant access; written as `<private>`.
    case `private`
}

/// A log line built by string interpolation, with a privacy for every value (as with `os.Logger`):
/// integers default to public, everything else to private.
package struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    package let rendered: String

    package init(stringLiteral value: String) { rendered = value }
    package init(stringInterpolation: Interpolation) { rendered = stringInterpolation.text }

    package struct Interpolation: StringInterpolationProtocol {
        var text = ""

        package init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity + interpolationCount * 8) }
        package mutating func appendLiteral(_ literal: String) { text += literal }

        package mutating func appendInterpolation(_ value: some BinaryInteger, privacy: LogPrivacy = .public) {
            append(String(value), privacy)
        }
        package mutating func appendInterpolation(_ value: some BinaryFloatingPoint, privacy: LogPrivacy = .public) {
            append(String(describing: Double(value)), privacy)
        }
        package mutating func appendInterpolation(_ value: Bool, privacy: LogPrivacy = .public) {
            append(value ? "true" : "false", privacy)
        }
        package mutating func appendInterpolation(_ value: some CustomStringConvertible, privacy: LogPrivacy = .private) {
            append(value.description, privacy)
        }
        package mutating func appendInterpolation(_ value: (some CustomStringConvertible)?, privacy: LogPrivacy = .private) {
            append(value.map(\.description) ?? "nil", privacy)
        }

        private mutating func append(_ value: String, _ privacy: LogPrivacy) {
            text += privacy == .public ? value : "<private>"
        }
    }
}

/// How much the SDK logs (unified logging, subsystem `dev.pingfront.sdk`).
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum PingFrontLogLevel: Int, Sendable, Comparable {
    /// Nothing at all.
    case off
    /// Errors and setup problems only.
    case error
    /// Errors plus notable events: sessions, live state, look revisions (default).
    case info
    /// Everything, including request paths and statuses (never bodies or tokens).
    case debug

    /// Orders levels from quietest to most verbose.
    public static func < (lhs: PingFrontLogLevel, rhs: PingFrontLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One SDK log line, as passed to `PingFrontConfiguration.logHandler`.
///
/// The message is safe to store and upload: values that could identify a person or grant access
/// (ids, names, emails, URLs, tokens, server text, user input) are already replaced by `<private>`.
public struct PingFrontLogEntry: Sendable, Equatable {
    /// `.error`, `.info` or `.debug`.
    public let level: PingFrontLogLevel
    /// The SDK area, for example `session`, `network` or `live`.
    public let category: String
    /// The redacted line.
    public let message: String

    /// An entry (public for tests of a host's handler).
    @_spi(Fixtures) public init(level: PingFrontLogLevel, category: String, message: String) {
        self.level = level
        self.category = category
        self.message = message
    }
}

/// Receives every SDK log line at or above `logLevel`, from any thread.
///
/// Keep it fast; hand off to your logger.
public typealias PingFrontLogHandler = @Sendable (PingFrontLogEntry) -> Void
