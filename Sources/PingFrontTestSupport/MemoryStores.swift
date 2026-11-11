package import Foundation
package import PingFrontCore

/// In-memory persistence for tests.
package actor MemoryPersistence: Persistence {
    private var files: [String: Data] = [:]
    package init() {}
    package func read(_ name: String) -> Data? { files[name] }
    package func write(_ name: String, _ data: Data) { files[name] = data }
    package func remove(_ name: String) { files[name] = nil }
}

/// An in-memory secure store for tests.
package actor MemorySecureStore: SecureStore {
    private var items: [String: Data] = [:]
    package init() {}
    package func read(_ key: String) throws(StorageError) -> Data? { items[key] }
    package func write(_ key: String, _ data: Data?) throws(StorageError) { items[key] = data }
}
