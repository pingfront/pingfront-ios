package import Foundation
internal import os

/// Why stored data could not be read or written.
package enum StorageError: Error, Sendable, Equatable {
    /// Protected data or the Keychain is locked (before first unlock, prewarming). Try again later and
    /// never treat it as "nothing stored".
    case unavailable
    /// Any other failure, with a diagnostic that carries no user data.
    case failed(String)

    /// Safe to log publicly: the diagnostic is built by the SDK from codes, never from user data.
    package var logDescription: String {
        switch self {
        case .unavailable: "unavailable"
        case .failed(let diagnostic): diagnostic
        }
    }
}

/// Raw named records: files or Keychain items. `VersionedFile` adds versions and migrations on top.
package protocol RecordStore: Sendable {
    /// The stored bytes, `nil` when nothing is stored.
    func load(_ name: String) async throws(StorageError) -> Data?
    /// Stores bytes, or deletes the record for `nil`.
    func store(_ name: String, _ data: Data?) async throws(StorageError)
}

/// Records as files (`Persistence`).
package struct FileRecords: RecordStore {
    package let persistence: any Persistence

    package init(_ persistence: any Persistence) { self.persistence = persistence }

    package func load(_ name: String) async throws(StorageError) -> Data? {
        do { return try await persistence.read(name) } catch { throw Self.map(error) }
    }

    package func store(_ name: String, _ data: Data?) async throws(StorageError) {
        do {
            if let data { try await persistence.write(name, data) } else { try await persistence.remove(name) }
        } catch {
            throw Self.map(error)
        }
    }

    /// File protection (`completeUntilFirstUserAuthentication`) surfaces as a permission error.
    private static func map(_ error: any Error) -> StorageError {
        let code = (error as? CocoaError)?.code
        if code == .fileReadNoPermission || code == .fileWriteNoPermission { return .unavailable }
        let posix = (error as NSError).underlyingErrors.compactMap { ($0 as NSError).domain == NSPOSIXErrorDomain ? $0 as NSError : nil }
        if posix.contains(where: { $0.code == Int(EPERM) || $0.code == Int(EACCES) }) { return .unavailable }
        return .failed("file \((error as NSError).domain) \((error as NSError).code)")
    }
}

/// Records as Keychain items (`SecureStore`).
package struct SecureRecords: RecordStore {
    package let secure: any SecureStore

    package init(_ secure: any SecureStore) { self.secure = secure }

    package func load(_ name: String) async throws(StorageError) -> Data? { try await secure.read(name) }

    package func store(_ name: String, _ data: Data?) async throws(StorageError) { try await secure.write(name, data) }
}

/// One persisted value with a version envelope `{"v": n, "value": …}`, explicit migrations, and one coder.
///
/// Data that cannot be read (corrupt, or written by a newer SDK) is moved aside under
/// `<name>.aside-<n>`, never overwritten, and reported in `issues` and the log. While the store is locked
/// (`StorageError.unavailable`) `load` throws, so callers never mistake "locked" for "empty".
package actor VersionedFile<Value: Codable & Sendable> {
    /// Turns a stored older version (the whole stored bytes) into the current value.
    ///
    /// Version 0 is the
    /// legacy format without an envelope.
    package typealias Migration = @Sendable (Data) throws -> Value

    /// Something found while loading, kept for diagnostics and tests.
    package enum Issue: Sendable, Equatable {
        /// The bytes could not be decoded (moved aside).
        case unreadable(storedVersion: Int?, asideName: String?)
        /// Written by a newer SDK (moved aside).
        case newerVersion(Int, asideName: String?)
        /// Migrated from an older version.
        case migrated(from: Int)
    }

    private struct Header: Decodable { let v: Int }
    private struct Envelope: Codable {
        let v: Int
        let value: Value
    }

    package let name: String
    package let version: Int
    private let records: any RecordStore
    private let migrations: [Int: Migration]
    /// What `load` found, oldest first.
    package private(set) var issues: [Issue] = []
    /// Set when unreadable data could not be moved aside: saving then would destroy it, so saves stop.
    private var frozen = false

    package init(_ name: String, version: Int, records: any RecordStore, migrations: [Int: Migration] = [:]) {
        self.name = name
        self.version = version
        self.records = records
        self.migrations = migrations
    }

    /// The stored value; `nil` when nothing usable is stored.
    ///
    /// Throws only `.unavailable` (try again later).
    package func load() async throws(StorageError) -> Value? {
        let data: Data?
        do { data = try await records.load(name) } catch .unavailable { throw .unavailable } catch {
            Log.storage(.error)?.error("Could not read \(self.name, privacy: .public): \(error.logDescription, privacy: .public)")
            return nil
        }
        guard let data else { return nil }
        let stored = try? WireJSON.decode(Header.self, from: data).v
        switch stored {
        case let stored? where stored == version:
            if let envelope = try? WireJSON.decode(Envelope.self, from: data) { return envelope.value }
            await setAside(data, issue: { .unreadable(storedVersion: stored, asideName: $0) })
            return nil
        case let stored? where stored > version:
            await setAside(data, issue: { .newerVersion(stored, asideName: $0) })
            return nil
        default:
            let from = stored ?? 0
            if let migrate = migrations[from], let value = try? migrate(data) {
                issues.append(.migrated(from: from))
                Log.storage(.info)?.info("Migrated \(self.name, privacy: .public) from version \(from, privacy: .public)")
                // Rewrite in the current format right away, so the old shape is read only once.
                try? await save(value)
                return value
            }
            await setAside(data, issue: { .unreadable(storedVersion: stored, asideName: $0) })
            return nil
        }
    }

    /// Stores `value` in the current version, or deletes the record for `nil`.
    package func save(_ value: Value?) async throws(StorageError) {
        guard !frozen else {
            Log.storage(.error)?.fault("Not saving \(self.name, privacy: .public): unreadable data could not be preserved")
            return
        }
        guard let value else {
            try await records.store(name, nil)
            return
        }
        let data: Data
        do { data = try WireJSON.encode(Envelope(v: version, value: value)) } catch {
            throw .failed("encode \(name)")
        }
        try await records.store(name, data)
    }

    /// Deletes the record and everything set aside from it (logout, erase).
    ///
    /// The person's data, readable or not, leaves the device. Saving works again afterwards.
    package func erase() async throws(StorageError) {
        try await records.store(name, nil)
        frozen = false
        for index in 1...Self.asideSlots { try? await records.store("\(name).aside-\(index)", nil) }
    }

    /// How many unreadable versions are kept aside at most.
    private static var asideSlots: Int { 20 }

    private func setAside(_ data: Data, issue: (String?) -> Issue) async {
        var aside: String?
        for index in 1...Self.asideSlots {
            let candidate = "\(name).aside-\(index)"
            let existing: Data?
            do { existing = try await records.load(candidate) } catch { continue }
            guard existing == nil else { continue }
            do {
                try await records.store(candidate, data)
                try await records.store(name, nil)
                aside = candidate
            } catch {
                aside = nil
            }
            break
        }
        if aside == nil { frozen = true }
        let found = issue(aside)
        issues.append(found)
        Log.storage(.error)?.fault(
            "\(self.name, privacy: .public) could not be read (\(String(describing: found), privacy: .public)); kept as \(aside ?? "the original", privacy: .public)"
        )
    }
}
