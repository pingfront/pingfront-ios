/// Reconnect and retry backoff: `min(1s * 2^n, cap)` with ±20% jitter.
///
/// Two caps, as the protocol sets them: queued writes (sends, card actions, team action answers) retry
/// with `min(1 s · 2ⁿ, 5 min)` (`writes`); the live socket and the gap repair that rides on it reconnect with
/// `min(1 s · 2ⁿ, 30 s)` (`live`, also the default).
package struct Backoff: Sendable {
    package var base: Duration = .seconds(1)
    package var cap: Duration = .seconds(30)
    package var jitter: Double = 0.2

    package init() {}

    /// Live reconnects: capped at 30 s.
    package static let live = Backoff()

    /// Queued writes: capped at 5 minutes.
    package static let writes: Backoff = {
        var backoff = Backoff()
        backoff.cap = .seconds(300)
        return backoff
    }()

    /// The un-jittered delay for attempt `n` (0-based).
    package func nominal(attempt n: Int) -> Duration {
        let exponent = min(max(n, 0), 16)
        let delay = base * (1 << exponent)
        return min(delay, cap)
    }

    /// The jittered delay. `unit` is a random value in -1...1 (injected in tests).
    package func delay(attempt n: Int, unit: Double = Double.random(in: -1...1)) -> Duration {
        let factor = 1 + jitter * min(max(unit, -1), 1)
        return nominal(attempt: n) * factor
    }
}
