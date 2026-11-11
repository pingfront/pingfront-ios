package import Foundation

/// Uploads photos (`POST /uploads`, then `PUT putUrl` with the returned headers exactly)
/// and resolves short-lived attachment URLs. Owns the attachment URL cache: at most `cacheLimit` entries, cleared on
/// logout and erase.
package actor Uploader {
    /// The most attachment URLs kept; past it, expired entries go first, then the ones that expire soonest.
    package static let cacheLimit = 200

    private let client: AuthorizedClient
    private let time: TimeSource
    private var urls: [String: (url: URL, validUntil: Duration)] = [:]
    /// Bumped by `clear()`: a URL fetched for the previous person is not cached.
    private var clears = 0

    package init(client: AuthorizedClient, time: TimeSource) {
        self.client = client
        self.time = time
    }

    /// Uploads one JPEG and returns its attachment id. `requestId` makes retries safe: the same id returns
    /// the same attachment, so a lost response never creates a second one.
    package func upload(
        _ data: Data, width: Int, height: Int, sha256: String, requestId: String = UUID().uuidString.lowercased(),
        reason: SessionReason = .chatOpened
    ) async throws(PingFrontError) -> String {
        let request = CreateUploadRequest(
            requestId: requestId, contentType: "image/jpeg", bytes: data.count, width: width, height: height, sha256: sha256)
        let slot = try await client.send(Endpoints.createUpload(request), reason: reason)
        try await client.api.upload(data, to: UploadTarget(slot))
        return slot.attachmentId
    }

    /// A fresh URL for an attachment, refetched when the cached one is about to expire.
    package func url(for attachmentId: String) async throws(PingFrontError) -> URL {
        if let cached = urls[attachmentId], time.now() < cached.validUntil { return cached.url }
        let clearsBefore = clears
        let response = try await client.send(Endpoints.attachment(id: attachmentId))
        guard clearsBefore == clears else { return response.url }
        let seconds = max(response.expiresAt.timeIntervalSinceNow - 30, 0)
        urls[attachmentId] = (response.url, time.now() + .milliseconds(Int64(seconds * 1000)))
        evict()
        return response.url
    }

    /// Forgets every cached URL (logout, erase, a revoked install): they were signed for the previous person.
    package func clear() {
        clears += 1
        urls = [:]
    }

    /// The number of cached URLs, for tests.
    package var cachedCount: Int { urls.count }

    private func evict() {
        guard urls.count > Self.cacheLimit else { return }
        let now = time.now()
        urls = urls.filter { now < $0.value.validUntil }
        guard urls.count > Self.cacheLimit else { return }
        let excess = urls.count - Self.cacheLimit
        for (id, _) in urls.sorted(by: { $0.value.validUntil < $1.value.validUntil }).prefix(excess) { urls[id] = nil }
    }
}
