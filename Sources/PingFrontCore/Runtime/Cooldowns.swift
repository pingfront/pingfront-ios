/// Scoped rate-limit cooldowns from 429 `scope` + `retryAfter`.
///
/// Only the named scope pauses,
/// so text keeps sending while uploads wait.
package struct Cooldowns: Sendable, Equatable {
    private var until: [RateScope: Duration] = [:]

    package init() {}

    /// Records a 429 at monotonic time `now`.
    ///
    /// Missing `retryAfter` means 30 s.
    package mutating func record(scope: RateScope, retryAfter: Duration?, now: Duration) {
        let end = now + (retryAfter ?? Timing.defaultCooldown)
        until[scope] = max(until[scope] ?? .zero, end)
    }

    /// Time left for `scope`, or `nil` when it is not cooling down.
    package func remaining(_ scope: RateScope, now: Duration) -> Duration? {
        guard let end = until[scope], end > now else { return nil }
        return end - now
    }

    /// Scopes cooling down at `now`.
    package func active(now: Duration) -> [RateScope: Duration] {
        until.compactMapValues { $0 > now ? $0 - now : nil }
    }

    /// The exact countdown text (`m:ss`) when under five minutes, else `nil` (show a general line instead).
    package static func countdown(_ remaining: Duration) -> String? {
        guard remaining < .seconds(300) else { return nil }
        let seconds = max(Int((Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18).rounded(.up)), 0)
        let tail = seconds % 60 < 10 ? "0\(seconds % 60)" : "\(seconds % 60)"
        return "\(seconds / 60):\(tail)"
    }
}

/// Shared cooldown state, checked before each request of a scope.
package actor CooldownBook {
    private var cooldowns = Cooldowns()
    private let time: TimeSource

    package init(time: TimeSource) { self.time = time }

    package func record(scope: RateScope, retryAfter: Duration?) {
        cooldowns.record(scope: scope, retryAfter: retryAfter, now: time.now())
    }

    package func remaining(_ scope: RateScope) -> Duration? {
        cooldowns.remaining(scope, now: time.now())
    }

    package func active() -> [RateScope: Duration] { cooldowns.active(now: time.now()) }
}
