import Foundation
import os

/// A manual clock: time moves only when a test calls `advance(by:)`.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var nextId: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// Number of tasks currently sleeping on this clock.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state -> UInt64 in
            state.nextId += 1
            return state.nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case wait, resume, cancel }
                let action = state.withLock { state -> Action in
                    if Task.isCancelled { return .cancel }
                    if deadline <= state.now { return .resume }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch action {
                case .wait: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and resumes every sleeper whose deadline passed.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits (in real time, at most 10 s) until at least `count` tasks sleep on this clock.
    func waitForSleepers(_ count: Int = 1, timeout: Duration = .seconds(10)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if sleeperCount >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// Polls a condition in real time (at most `timeout`).
///
/// Returns whether it became true.
@discardableResult
func eventually(timeout: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Keeps test facades alive for the whole run.
///
/// An engine holds its facade unowned (the facade owns the
/// engine, and in apps the facade is the immortal `PingFront.shared`); a test that drops its facade while
/// the engine's tasks still run would otherwise read a dead reference.
@MainActor enum Retain {
    private static var objects: [AnyObject] = []
    static func keep(_ object: AnyObject) { objects.append(object) }
}

/// Lets every ready task run (no wall-clock time): for checks that something did *not* happen.
func settle(_ rounds: Int = 200) async {
    for _ in 0..<rounds { await Task.yield() }
}
