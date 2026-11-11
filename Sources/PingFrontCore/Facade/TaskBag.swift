import Foundation

/// One-shot operations owned by a component on the main actor; `cancelAll()` ends every one of them.
@MainActor
package final class TaskBag {
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var nextId: UInt64 = 0

    package init() {}

    /// Runs `operation` as an owned task.
    package func run(_ operation: @escaping @MainActor () async -> Void) {
        nextId += 1
        let id = nextId
        tasks[id] = Task { [weak self] in
            await operation()
            self?.tasks[id] = nil
        }
    }

    /// Cancels every running operation.
    package func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }
}
