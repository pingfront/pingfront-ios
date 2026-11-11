internal import os

/// A level-triggered wake-up: `notify()` wakes the current waiter, or the next one if nobody waits.
///
/// Uses a lock because cancellation handlers must resume the continuation synchronously.
package final class WakeSignal: Sendable {
    private struct State {
        var pending = false
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextId: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    package func notify() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            if state.waiters.isEmpty {
                state.pending = true
                return []
            }
            let all = Array(state.waiters.values)
            state.waiters.removeAll()
            return all
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Waits until notified or cancelled.
    package func wait() async {
        let id: UInt64? = state.withLock { state in
            if state.pending {
                state.pending = false
                return nil
            }
            state.nextId += 1
            return state.nextId
        }
        guard let id else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.pending || Task.isCancelled {
                        state.pending = false
                        return true
                    }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }

    /// Waits until notified, `timeout` passes on `time`, or the task is cancelled.
    package func wait(timeout: Duration, time: TimeSource) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.wait() }
            group.addTask { _ = await time.pause(timeout) }
            await group.next()
            group.cancelAll()
        }
    }
}
