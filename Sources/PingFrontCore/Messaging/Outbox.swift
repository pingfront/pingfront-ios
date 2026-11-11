public import Foundation
internal import os

/// A message the person wrote that the server has not acknowledged yet.
public struct PendingMessage: Sendable, Equatable, Identifiable, Codable {
    /// Delivery state.
    #if hasAttribute(nonexhaustive)
        @nonexhaustive
    #endif
    public enum State: String, Sendable, Codable {
        /// Waiting to be sent (also while offline or rate limited).
        case queued
        /// Being uploaded or sent right now.
        case sending
        /// The server rejected it; the person can retry or discard.
        case failed
    }
    /// A photo staged for upload.
    public struct Photo: Sendable, Equatable, Codable {
        /// File name in the outbox directory.
        package var file: String
        /// Pixel width.
        public var width: Int
        /// Pixel height.
        public var height: Int
        /// Byte count.
        public var bytes: Int
        /// Hex SHA-256 of the JPEG.
        public var sha256: String
        /// Set once uploaded, so a retry never uploads twice.
        public var attachmentId: String?
    }

    /// The idempotency key.
    ///
    /// A retry reuses it, so the server never stores a message twice.
    public var id: String { clientId }
    /// The idempotency key.
    public var clientId: String
    /// Text, if any.
    public var text: String?
    /// Photos, if any.
    public var photos: [Photo]
    /// Reply to a choices or rating card.
    package var replyToCard: CardReply?
    /// When the person tapped Send.
    public var createdAt: Date
    /// Delivery attempts so far.
    public var attempts: Int
    /// Current state.
    public var state: State
    /// Why it failed, in plain words.
    public var failure: String?
    /// Why a closed policy refused it (the app paused, verification required), kept across relaunches.
    ///
    /// It goes again by itself when sending reopens, and the messages behind it wait for it. A blocked person's message
    /// is never held.
    public package(set) var heldFor: SendPolicy.Reason?

    /// Refused by a closed policy and waiting to go by itself (`heldFor` says why).
    public var isHeld: Bool { heldFor != nil }

    /// Already sent once more after a 409 `thread_reset` reloaded the thread.
    ///
    /// A second reset fails it (the protocol's retry rules). Kept across relaunches; `nil` in queues stored
    /// before it existed.
    package var retriedAfterReset: Bool?

    package init(
        clientId: String = UUID().uuidString.lowercased(), text: String?, photos: [Photo] = [], replyToCard: CardReply? = nil,
        createdAt: Date = .now
    ) {
        self.clientId = clientId
        self.text = text
        self.photos = photos
        self.replyToCard = replyToCard
        self.createdAt = createdAt
        attempts = 0
        state = .queued
        failure = nil
    }
}

/// The persistent offline send queue. Survives relaunch (Application Support, excluded from backup,
/// file protection). Delivery is idempotent on `clientId`.
package actor Outbox {
    package enum DrainResult: Sendable, Equatable {
        case idle
        /// A transient failure (offline, 5xx, rate limit): try again after a backoff.
        case retryLater(PingFrontError)
    }

    package typealias Deliver = @Sendable (PendingMessage) async throws(PingFrontError) -> Message

    private let persistence: any Persistence
    /// The queue on disk (versioned; legacy arrays migrate, unreadable files are kept aside).
    private let file: VersionedFile<[PendingMessage]>
    private var items: [PendingMessage] = []
    private var loaded = false
    /// Bumped by `clear()`: a load that was reading the file when the queue was cleared keeps nothing it read.
    private var clears = 0
    private let continuation: AsyncStream<[PendingMessage]>.Continuation
    /// The queue after every change, for the UI.
    package nonisolated let changes: AsyncStream<[PendingMessage]>
    private let delivered: AsyncStream<(clientId: String, message: Message)>.Continuation
    /// Messages the server acknowledged.
    package nonisolated let deliveries: AsyncStream<(clientId: String, message: Message)>

    package init(persistence: any Persistence) {
        self.persistence = persistence
        file = VersionedFile(
            Files.outbox, version: 1, records: FileRecords(persistence),
            migrations: [0: { try WireJSON.decode([PendingMessage].self, from: $0) }])
        (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (deliveries, delivered) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Loads the queue from disk.
    ///
    /// Items left `sending` by a killed process go back to `queued`.
    @discardableResult
    package func load() async -> [PendingMessage] {
        guard !loaded else { return items }
        let clearsBefore = clears
        let stored: [PendingMessage]
        do { stored = try await file.load() ?? [] } catch {
            // Protected data is locked: keep the in-memory queue and read again later; never overwrite.
            continuation.yield(items)
            return items
        }
        // Cleared while the file was being read (logout, erase): what was read belongs to the previous person.
        guard clearsBefore == clears, !loaded else { return items }
        loaded = true
        let restored = stored.map {
            var item = $0
            if item.state == .sending { item.state = .queued }
            return item
        }
        // Anything queued in memory while the file was unreadable stays, after what was stored.
        items = restored + items.filter { added in !restored.contains { $0.clientId == added.clientId } }
        continuation.yield(items)
        return items
    }

    package func all() -> [PendingMessage] { items }

    /// Adds a message and stores its photo bytes next to the queue.
    package func enqueue(_ message: PendingMessage, photoData: [Data] = []) async {
        await load()
        let clearsBefore = clears
        for (photo, data) in zip(message.photos, photoData) {
            try? await persistence.write(photo.file, data)
        }
        // Cleared while the photos were written (logout, erase): the send belonged to the previous person.
        guard clearsBefore == clears else {
            for photo in message.photos { try? await persistence.remove(photo.file) }
            return
        }
        items.append(message)
        await save()
    }

    package func retry(_ clientId: String) async {
        guard let index = items.firstIndex(where: { $0.clientId == clientId }) else { return }
        items[index].state = .queued
        items[index].failure = nil
        items[index].heldFor = nil
        // The person's Try again is a new attempt: it may again go once more after a thread reset.
        items[index].retriedAfterReset = nil
        await save()
    }

    /// Queues again the items a closed send policy refused (only those held `for` that reason, when given); true when
    /// there were any.
    package func retryHeld(for reason: SendPolicy.Reason? = nil) async -> Bool {
        await load()
        var any = false
        for index in items.indices where items[index].isHeld && (reason == nil || items[index].heldFor == reason) {
            items[index].state = .queued
            items[index].failure = nil
            items[index].heldFor = nil
            any = true
        }
        if any { await save() }
        return any
    }

    /// The policy turned to blocked: held items stop waiting and become plain failures (Delete, or Try again once the
    /// person can send), so they no longer keep the queue behind them waiting.
    package func releaseHeld() async {
        await load()
        var any = false
        for index in items.indices where items[index].isHeld {
            items[index].heldFor = nil
            any = true
        }
        if any { await save() }
    }

    package func discard(_ clientId: String) async {
        guard let index = items.firstIndex(where: { $0.clientId == clientId }) else { return }
        let item = items.remove(at: index)
        for photo in item.photos { try? await persistence.remove(photo.file) }
        await save()
    }

    /// Forgets the queue and its photos, on disk too, whether or not it was loaded (logout, erase, revoked).
    package func clear() async {
        // What is on disk names the photo files to delete (a load already in flight then keeps nothing).
        await load()
        clears += 1
        let photos = items.flatMap(\.photos)
        items = []
        loaded = true
        continuation.yield(items)
        try? await file.erase()
        for photo in photos { try? await persistence.remove(photo.file) }
    }

    package func photoData(_ photo: PendingMessage.Photo) async -> Data? {
        try? await persistence.read(photo.file)
    }

    package func recordUpload(clientId: String, file: String, attachmentId: String) async {
        guard let index = items.firstIndex(where: { $0.clientId == clientId }),
            let photoIndex = items[index].photos.firstIndex(where: { $0.file == file })
        else { return }
        items[index].photos[photoIndex].attachmentId = attachmentId
        await save()
    }

    /// Sends queued items in order, and is the only place that decides what goes next.
    ///
    /// A held item (`heldFor`) stops the drain: nothing behind it goes before it, whenever `retryHeld` queues it
    /// again. Items that need uploads wait while `uploadsPaused`, but text keeps going. A plain failure waits for the
    /// person (Try again or Delete) and does not hold up the rest.
    package func drain(uploadsPaused: Bool, deliver: Deliver) async -> DrainResult {
        await load()
        var index = 0
        while index < items.count {
            if Task.isCancelled { return .idle }
            let item = items[index]
            if item.isHeld { return .idle }
            let needsUpload = item.photos.contains { $0.attachmentId == nil }
            guard item.state == .queued, !(needsUpload && uploadsPaused) else {
                index += 1
                continue
            }
            items[index].state = .sending
            items[index].attempts += 1
            continuation.yield(items)
            do {
                let message = try await deliver(items[index])
                // Cleared while the send was in flight (logout, erase): the answer belongs to the previous
                // person and is not reported.
                if let at = items.firstIndex(where: { $0.clientId == item.clientId }) {
                    let removed = items.remove(at: at)
                    for photo in removed.photos { try? await persistence.remove(photo.file) }
                    delivered.yield((item.clientId, message))
                }
                await save()
            } catch {
                guard let at = items.firstIndex(where: { $0.clientId == item.clientId }) else { continue }
                if error.code == .threadReset, items[at].retriedAfterReset != true {
                    // The deliverer reloaded the thread and the message is still queued: once more, at once. A second
                    // reset fails it below, so a send never loops on resets.
                    items[at].retriedAfterReset = true
                    items[at].state = .queued
                    await save()
                    index = at
                    continue
                }
                if error.isTransient || error == .cancelled {
                    items[at].state = .queued
                    await save()
                    if case .coolingDown(scope: .uploads, _) = error {
                        index = at + 1
                        continue
                    }
                    return .retryLater(error)
                }
                if let reason = SendPolicy.Reason(refusal: error.code) {
                    // The person can't send now: every later item would be refused too.
                    if reason.holdsMessages {
                        // It waits, failed, for sending to reopen (`retryHeld`), when it goes again by itself, first.
                        items[at].state = .failed
                        items[at].failure = Outbox.describe(error)
                        items[at].heldFor = reason
                    } else {
                        // Blocked: nothing is promised. This one and the ones queued behind it fail plainly, unsent.
                        for later in items.indices[at...] where items[later].state == .queued || later == at {
                            items[later].state = .failed
                            items[later].failure = Outbox.describe(error)
                        }
                    }
                    await save()
                    return .idle
                }
                if error.code == .sessionRevoked {
                    // The install was revoked or erased: the rest of its queue belongs to no one now, and must not
                    // go out under the new guest the next delivery would start (scenario auth-refresh-revoked).
                    await clear()
                    return .idle
                }
                items[at].state = .failed
                items[at].failure = Outbox.describe(error)
                await save()
                index = at + 1
            }
        }
        return .idle
    }

    private func save() async {
        continuation.yield(items)
        guard loaded else { return }
        do {
            try await file.save(items.isEmpty ? nil : items)
        } catch {
            Log.outbox(.error)?.error("Could not save the outbox: \(String(describing: error), privacy: .private)")
        }
    }

    package static func describe(_ error: PingFrontError) -> String {
        switch error {
        case .server(let server): server.code.rawValue
        case .invalidInput(let message): message
        default: String(describing: error)
        }
    }
}
