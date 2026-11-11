import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// Records delivery attempts and scripts their outcomes.
actor DeliveryScript {
    private(set) var attempts: [String] = []
    private var failures: [String: [PingFrontError]] = [:]

    func fail(_ text: String, with errors: PingFrontError...) { failures[text, default: []] += errors }

    func deliver(_ item: PendingMessage) throws(PingFrontError) -> Message {
        attempts.append(item.clientId)
        let key = item.text ?? ""
        if var queue = failures[key], !queue.isEmpty {
            let error = queue.removeFirst()
            failures[key] = queue
            throw error
        }
        return Message(
            id: "srv_\(item.clientId.prefix(8))", seq: attempts.count, clientId: item.clientId, author: Author(kind: .person),
            parts: [.text(item.text ?? "")], createdAt: .now)
    }

    func attemptCount(for clientId: String) -> Int { attempts.filter { $0 == clientId }.count }
}

@Suite("Offline outbox")
struct OutboxTests {
    let script = DeliveryScript()

    var deliver: Outbox.Deliver {
        let script = script
        return { item async throws(PingFrontError) in try await script.deliver(item) }
    }

    @Test("The queue survives a new Outbox instance (relaunch)")
    func persistence() async {
        let storage = MemoryPersistence()
        let first = Outbox(persistence: storage)
        let message = PendingMessage(text: "Hello from yesterday")
        await first.enqueue(message)

        let relaunched = Outbox(persistence: storage)
        let items = await relaunched.load()
        #expect(items.map(\.clientId) == [message.clientId])
        #expect(items.first?.text == "Hello from yesterday")
        #expect(items.first?.state == .queued)
    }

    @Test("FilePersistence stores the queue and photo bytes on disk, excluded from backup")
    func fileStorage() async throws {
        let directory = URL.temporaryDirectory.appending(path: "pf-outbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FilePersistence(directory: directory)
        let photo = PendingMessage.Photo(
            file: "outbox-x-0.jpg", width: 10, height: 10, bytes: 3, sha256: String(repeating: "a", count: 64), attachmentId: nil)
        let message = PendingMessage(text: "with photo", photos: [photo])
        await Outbox(persistence: storage).enqueue(message, photoData: [Data([1, 2, 3])])

        let relaunched = Outbox(persistence: storage)
        #expect(await relaunched.load().first?.photos == [photo])
        #expect(await relaunched.photoData(photo) == Data([1, 2, 3]))
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        await relaunched.discard(message.clientId)
        #expect(await relaunched.photoData(photo) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: Files.outbox).path(percentEncoded: false)))
    }

    @Test("Items a killed process left `sending` go back to `queued`")
    func sendingReverts() async throws {
        let storage = MemoryPersistence()
        var item = PendingMessage(text: "in flight")
        item.state = .sending
        await storage.write(Files.outbox, try WireJSON.encode([item]))
        #expect(await Outbox(persistence: storage).load().first?.state == .queued)
    }

    @Test("A transient failure is retried with the same clientId, then delivered once")
    func idempotentRetry() async throws {
        let outbox = Outbox(persistence: MemoryPersistence())
        let message = PendingMessage(text: "retry me")
        await outbox.enqueue(message)
        await script.fail("retry me", with: .network(.networkConnectionLost))

        let first = await outbox.drain(uploadsPaused: false, deliver: deliver)
        #expect(first == .retryLater(.network(.networkConnectionLost)))
        #expect(await outbox.all().first?.state == .queued)
        #expect(await outbox.all().first?.attempts == 1)

        let second = await outbox.drain(uploadsPaused: false, deliver: deliver)
        #expect(second == .idle)
        #expect(await script.attempts == [message.clientId, message.clientId])
        #expect(await outbox.all().isEmpty)

        var deliveries = outbox.deliveries.makeAsyncIterator()
        let delivered = await deliveries.next()
        #expect(delivered?.clientId == message.clientId)
        #expect(delivered?.message.clientId == message.clientId)
    }

    @Test("A permanent failure marks the item failed and later items still send; retry re-queues it")
    func permanentFailure() async {
        let outbox = Outbox(persistence: MemoryPersistence())
        let bad = PendingMessage(text: "bad")
        let good = PendingMessage(text: "good")
        await outbox.enqueue(bad)
        await outbox.enqueue(good)
        await script.fail(
            "bad", with: .server(ServerError(status: 422, code: .invalidRequest, message: "", docs: nil, retryAfter: nil, scope: nil)))

        #expect(await outbox.drain(uploadsPaused: false, deliver: deliver) == .idle)
        let items = await outbox.all()
        #expect(items.map(\.clientId) == [bad.clientId])
        #expect(items.first?.state == .failed)
        #expect(items.first?.failure == "invalid_request")

        // Failed items are not retried automatically.
        #expect(await outbox.drain(uploadsPaused: false, deliver: deliver) == .idle)
        #expect(await script.attemptCount(for: bad.clientId) == 1)

        await outbox.retry(bad.clientId)
        #expect(await outbox.drain(uploadsPaused: false, deliver: deliver) == .idle)
        #expect(await outbox.all().isEmpty)
        #expect(await script.attemptCount(for: bad.clientId) == 2)
    }

    @Test("While uploads are paused, photo messages wait and text behind them still sends")
    func uploadsPaused() async {
        let outbox = Outbox(persistence: MemoryPersistence())
        let photo = PendingMessage.Photo(file: "p.jpg", width: 1, height: 1, bytes: 1, sha256: "", attachmentId: nil)
        let withPhoto = PendingMessage(text: "photo", photos: [photo])
        let uploaded = PendingMessage(
            text: "already uploaded",
            photos: [PendingMessage.Photo(file: "q.jpg", width: 1, height: 1, bytes: 1, sha256: "", attachmentId: "att_1")])
        let text = PendingMessage(text: "text")
        await outbox.enqueue(withPhoto)
        await outbox.enqueue(uploaded)
        await outbox.enqueue(text)

        #expect(await outbox.drain(uploadsPaused: true, deliver: deliver) == .idle)
        #expect(await script.attempts == [uploaded.clientId, text.clientId])
        #expect(await outbox.all().map(\.clientId) == [withPhoto.clientId])

        #expect(await outbox.drain(uploadsPaused: false, deliver: deliver) == .idle)
        #expect(await outbox.all().isEmpty)
    }

    @Test("An uploads cooldown during delivery skips that item but keeps draining")
    func uploadCooldownMidDrain() async {
        let outbox = Outbox(persistence: MemoryPersistence())
        let photoMessage = PendingMessage(text: "photo")
        let text = PendingMessage(text: "text")
        await outbox.enqueue(photoMessage)
        await outbox.enqueue(text)
        await script.fail("photo", with: .coolingDown(scope: .uploads, remaining: .seconds(30)))

        #expect(await outbox.drain(uploadsPaused: false, deliver: deliver) == .idle)
        #expect(await outbox.all().map(\.clientId) == [photoMessage.clientId])
        #expect(await outbox.all().first?.state == .queued)
    }

    @Test("recordUpload keeps the attachment id so a retry never uploads twice")
    func recordUpload() async {
        let outbox = Outbox(persistence: MemoryPersistence())
        let photo = PendingMessage.Photo(file: "p.jpg", width: 1, height: 1, bytes: 1, sha256: "", attachmentId: nil)
        let message = PendingMessage(text: nil, photos: [photo])
        await outbox.enqueue(message)
        await outbox.recordUpload(clientId: message.clientId, file: "p.jpg", attachmentId: "att_9")
        #expect(await outbox.all().first?.photos.first?.attachmentId == "att_9")
    }
}
