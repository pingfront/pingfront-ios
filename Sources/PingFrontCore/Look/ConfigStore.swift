package import Foundation
internal import os

/// Owns the remote app config: ETag caching on disk, at most one refetch per 5 minutes unless forced
/// (a live `config` event), and the draft look for test devices (memory only).
package actor ConfigStore {
    package static let minimumInterval: Duration = .seconds(300)

    private let client: AuthorizedClient
    /// The published config on disk with its ETag (versioned).
    private let file: VersionedFile<Cached>
    private let time: TimeSource
    private var published: AppConfig?
    private var etag: String?
    private var lastFetch: Duration?
    private var draft: AppConfig?
    private var loadedFromDisk = false

    package init(client: AuthorizedClient, persistence: any Persistence, time: TimeSource) {
        self.client = client
        file = VersionedFile(
            Files.config, version: 1, records: FileRecords(persistence),
            migrations: [0: { try JSONDecoder().decode(Cached.self, from: $0) }])
        self.time = time
    }

    package struct Cached: Codable, Sendable {
        var etag: String?
        var body: Data
    }

    /// The cached published config from disk (no network).
    package func cached() async -> AppConfig? {
        if !loadedFromDisk {
            loadedFromDisk = true
            if let cached = try? await file.load(), let config = try? WireJSON.decode(AppConfig.self, from: cached.body) {
                published = config
                etag = cached.etag
            }
        }
        return published
    }

    /// The config to render: the draft on test devices, else the published one.
    package func current(testDevice: Bool) async -> AppConfig? {
        if testDevice, let draft { return draft }
        return await cached()
    }

    /// What one fetch did, for a silent push's background-fetch result.
    package enum Outcome: Sendable, Equatable {
        case changed, unchanged, failed
    }

    /// Refetches if the cache is older than 5 minutes, or always when `force`.
    package func refresh(testDevice: Bool, force: Bool = false) async -> AppConfig? {
        await refreshReporting(testDevice: testDevice, force: force).config
    }

    /// `refresh`, also saying whether the look changed, stayed the same (304, or no fetch) or could not be read.
    package func refreshReporting(testDevice: Bool, force: Bool = false) async -> (config: AppConfig?, outcome: Outcome) {
        _ = await cached()
        let now = time.now()
        if !force, let lastFetch, now - lastFetch < Self.minimumInterval {
            return (await current(testDevice: testDevice), .unchanged)
        }
        lastFetch = now
        var outcome = Outcome.unchanged
        do {
            // Test devices ask for the draft with their bearer token (the server answers the published look otherwise).
            let result = try await client.send(Endpoints.config(draft: testDevice), ifNoneMatch: testDevice ? nil : etag)
            if case .fresh(let config, let body, let newTag) = result {
                if config.draft {
                    draft = config
                } else {
                    published = config
                    draft = nil
                    etag = newTag
                    try? await file.save(Cached(etag: etag, body: body))
                }
                outcome = .changed
                Log.look(.info)?.info(
                    "Applied look revision \(config.revision, privacy: .public)\(config.draft ? " (draft)" : "", privacy: .public)")
            }
        } catch {
            Log.look(.info)?.info("Config fetch failed: \(error.logDescription, privacy: .public)")
            outcome = .failed
        }
        return (await current(testDevice: testDevice), outcome)
    }

    package func clearDraft() { draft = nil }
}
