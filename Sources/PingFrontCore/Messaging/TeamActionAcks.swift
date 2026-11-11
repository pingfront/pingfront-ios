import Foundation
internal import os

/// The host app's answers to team actions (`POST /team-actions/{id}/ack`), queued on disk and retried like other
/// writes, so an answer given offline or just before the app quits still reaches the team.
///
/// The first answer per action wins; a repeat is a no-op on the server (204). 404 (not this person's action) and
/// 409 (expired) drop the answer.
package actor TeamActionAcks {
    package struct Item: Sendable, Equatable, Codable {
        package var id: String
        package var ack: TeamActionAck
    }

    package enum DrainResult: Sendable, Equatable {
        case idle
        /// A transient failure (offline, 5xx, rate limit): try again after a backoff.
        case retryLater(PingFrontError)
        /// The app is paused (403 `app_paused`): the answers stay queued, with no retry, until the next session start,
        /// refresh or chat open.
        case paused
    }

    package typealias Send = @Sendable (Item) async throws(PingFrontError) -> Void

    private let file: VersionedFile<[Item]>
    private var items: [Item] = []
    private var loaded = false
    /// Bumped by `clear()`: a load that was reading the file when the queue was cleared keeps nothing it read.
    private var clears = 0

    package init(persistence: any Persistence) {
        file = VersionedFile(Files.teamActionAcks, version: 1, records: FileRecords(persistence))
    }

    /// Loads the queue from disk once (protected data locked: try again next time, never overwrite).
    @discardableResult
    package func load() async -> [Item] {
        guard !loaded else { return items }
        let clearsBefore = clears
        let stored: [Item]
        do { stored = try await file.load() ?? [] } catch { return items }
        guard clearsBefore == clears, !loaded else { return items }
        loaded = true
        items = stored + items.filter { added in !stored.contains { $0.id == added.id } }
        return items
    }

    package func all() async -> [Item] { await load() }

    /// True when an answer for this action is waiting to be sent.
    package func contains(_ id: String) async -> Bool { await load().contains { $0.id == id } }

    /// Queues an answer; a second answer for the same action is ignored (the first one wins).
    package func enqueue(id: String, _ ack: TeamActionAck) async {
        await load()
        guard !items.contains(where: { $0.id == id }) else { return }
        items.append(Item(id: id, ack: ack))
        await save()
    }

    /// Forgets every queued answer, on disk too, whether or not the queue was loaded (logout, erase).
    package func clear() async {
        clears += 1
        items = []
        loaded = true
        try? await file.erase()
    }

    /// Sends queued answers in order.
    package func drain(_ send: Send) async -> DrainResult {
        await load()
        while let item = items.first {
            if Task.isCancelled { return .idle }
            do {
                try await send(item)
            } catch {
                if error.isTransient || error == .cancelled { return .retryLater(error) }
                if error.code == .appPaused { return .paused }
                // 404, 409 and anything else permanent: the server will never take it; drop it.
                Log.outbox(.info)?.info("Team action answer dropped: \(error.logDescription, privacy: .public)")
            }
            items.removeAll { $0.id == item.id }
            await save()
        }
        return .idle
    }

    private func save() async {
        guard loaded else { return }
        do {
            try await file.save(items.isEmpty ? nil : items)
        } catch {
            Log.outbox(.error)?.error("Could not save team action answers: \(String(describing: error), privacy: .private)")
        }
    }
}
