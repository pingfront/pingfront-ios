package import Foundation
internal import os

/// Card action reports (`POST /thread/cards/{cardId}/act`), queued on disk and retried safely (the protocol's retry
/// rules).
///
/// Each report carries a `clientId` made once and kept across every retry, so the server records it once. Retried on no
/// answer and on 408, 429 (at least `retryAfter`), 500, 502, 503 and 504; a 401 the client could not fix with its one
/// refresh, and every other 4xx, drops it; a 409 `thread_reset` reloads the thread and retries once if the message is
/// still in it. Dropped after 24 hours or 10 attempts. Cleared with the person's other local data.
package actor CardActionReports {
    package struct Item: Sendable, Equatable, Codable {
        package var cardId: String
        package var request: CardActionRequest
        package var createdAt: Date
        package var attempts = 0
        /// Already retried once after a 409 `thread_reset`.
        package var retriedAfterReset = false

        package init(cardId: String, request: CardActionRequest, createdAt: Date) {
            self.cardId = cardId
            self.request = request
            self.createdAt = createdAt
        }

        package var clientId: String { request.clientId ?? "" }
    }

    package enum DrainResult: Sendable, Equatable {
        case idle
        /// No answer, or one worth retrying: try again after a backoff (or `retryAfter` when longer).
        case retryLater(PingFrontError)
    }

    package typealias Send = @Sendable (Item) async throws(PingFrontError) -> Void

    /// The thread was reset (409): reload it, and say whether the report's message is still in it.
    package typealias StillThere = @Sendable (_ messageId: String) async -> Bool

    /// A report older than this is dropped: a late report is worth little and its card may be gone.
    package static let maxAge: TimeInterval = 24 * 60 * 60
    /// At most this many attempts per report.
    package static let maxAttempts = 10

    private let file: VersionedFile<[Item]>
    private let now: @Sendable () -> Date
    private var items: [Item] = []
    private var loaded = false
    /// Bumped by `clear()`: a load that was reading the file when the queue was cleared keeps nothing it read.
    private var clears = 0

    package init(persistence: any Persistence, now: @escaping @Sendable () -> Date = { .now }) {
        file = VersionedFile(Files.cardActions, version: 1, records: FileRecords(persistence))
        self.now = now
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
        items = stored + items.filter { added in !stored.contains { $0.clientId == added.clientId } }
        return items
    }

    package func all() async -> [Item] { await load() }

    /// Queues one report with a new `clientId` (a new tap, pick, rating or dismissal); scenarios pass a scripted one.
    package func enqueue(cardId: String, _ request: CardActionRequest, clientId: String = UUID().uuidString.lowercased()) async {
        await load()
        var request = request
        request.clientId = clientId
        items.append(Item(cardId: cardId, request: request, createdAt: now()))
        await save()
    }

    /// Forgets every queued report, on disk too (logout, erase, a revoked install).
    package func clear() async {
        clears += 1
        items = []
        loaded = true
        try? await file.erase()
    }

    /// Sends queued reports in order, each with its own `clientId` and body unchanged.
    package func drain(_ send: Send, stillThere: StillThere) async -> DrainResult {
        await load()
        while var item = items.first {
            if Task.isCancelled { return .idle }
            guard now().timeIntervalSince(item.createdAt) < Self.maxAge, item.attempts < Self.maxAttempts else {
                drop(item, "expired")
                await save()
                continue
            }
            item.attempts += 1
            update(item)
            await save()
            do {
                try await send(item)
            } catch {
                if Self.retries(error) { return .retryLater(error) }
                if error == .cancelled { return .idle }
                if error.code == .threadReset, !item.retriedAfterReset, await stillThere(item.request.messageId) {
                    // The thread was reloaded and the card's message is still in it: once more, at once.
                    item.retriedAfterReset = true
                    update(item)
                    await save()
                    continue
                }
                drop(item, error.logDescription)
                await save()
                continue
            }
            items.removeAll { $0.clientId == item.clientId }
            await save()
        }
        return .idle
    }

    /// No answer (offline, a timeout, a lost connection), a rate limit, 408, 500, 502, 503 or 504.
    package static func retries(_ error: PingFrontError) -> Bool {
        switch error {
        case .network, .coolingDown: true
        case .server(let server): [408, 429, 500, 502, 503, 504].contains(server.status)
        default: false
        }
    }

    private func update(_ item: Item) {
        if let index = items.firstIndex(where: { $0.clientId == item.clientId }) { items[index] = item }
    }

    private func drop(_ item: Item, _ why: String) {
        items.removeAll { $0.clientId == item.clientId }
        #if DEBUG
            Log.network(.info)?.info("Card action report dropped: \(why, privacy: .public)")
        #endif
    }

    private func save() async {
        guard loaded else { return }
        do {
            try await file.save(items.isEmpty ? nil : items)
        } catch {
            Log.outbox(.error)?.error("Could not save card action reports: \(String(describing: error), privacy: .private)")
        }
    }
}
