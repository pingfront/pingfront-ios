/// Monotonic time and sleeping, backed by an injected `Clock`.
///
/// Production uses `ContinuousClock`; tests inject a manual clock so backoff, coalescing and polling are deterministic.
package struct TimeSource: Sendable {
    /// Monotonic time since the source was created.
    package let now: @Sendable () -> Duration
    /// Sleeps for a duration on the injected clock.
    ///
    /// Honors cancellation.
    package let sleep: @Sendable (Duration) async throws -> Void

    package init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { duration in try await clock.sleep(for: duration) }
    }

    package static let continuous = TimeSource(ContinuousClock())

    /// Sleeps, returning `false` instead of throwing when cancelled.
    package func pause(_ duration: Duration) async -> Bool {
        do {
            try await sleep(duration)
            return true
        } catch { return false }
    }
}
