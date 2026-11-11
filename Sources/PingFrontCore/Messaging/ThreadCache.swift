import Foundation

/// The last page of the thread on disk, for offline opening. Encoding and decoding run in this actor,
/// never on the main actor.
package actor ThreadCache {
    private let file: VersionedFile<CachedThread>

    package init(persistence: any Persistence) {
        file = VersionedFile(
            Files.thread, version: 1, records: FileRecords(persistence),
            migrations: [0: { try WireJSON.decode(CachedThread.self, from: $0) }])
    }

    package func save(_ cached: CachedThread) async {
        try? await file.save(cached)
    }

    package func load() async -> CachedThread? {
        try? await file.load()
    }

    package func clear() async {
        try? await file.erase()
    }
}

/// The last page of the thread, cached for offline opening.
package struct CachedThread: Codable, Sendable {
    package var messages: [Message]
    package var team: [TeamMember]
    package var hasOlder: Bool

    package init(messages: [Message], team: [TeamMember], hasOlder: Bool) {
        self.messages = messages
        self.team = team
        self.hasOlder = hasOlder
    }
}
