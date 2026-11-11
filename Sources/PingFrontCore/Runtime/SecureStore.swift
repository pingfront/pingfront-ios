package import Foundation
import Security
internal import os

/// The secret-storage seam.
///
/// Production uses the Keychain; tests use `MemorySecureStore`. Errors are typed so a locked Keychain
/// (`.unavailable`) is never mistaken for "nothing stored".
package protocol SecureStore: Sendable {
    /// The item, or `nil` when there is none.
    func read(_ key: String) async throws(StorageError) -> Data?
    /// Stores the item, or deletes it for `nil`.
    func write(_ key: String, _ data: Data?) async throws(StorageError)
}

/// Keychain items, this device only, readable after first unlock (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
package struct KeychainStore: SecureStore {
    private let service: String
    private let client: KeychainClient

    package init(service: String = "dev.pingfront.sdk", client: KeychainClient = .system) {
        self.service = service
        self.client = client
    }

    private func query(_ key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        #if os(macOS)
            query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    @concurrent package func read(_ key: String) async throws(StorageError) -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = client.copyMatching(query)
        switch status {
        case errSecSuccess: return data
        case errSecItemNotFound: return nil
        default: throw Self.error(status, "read")
        }
    }

    @concurrent package func write(_ key: String, _ data: Data?) async throws(StorageError) {
        let base = query(key)
        guard let data else {
            let status = client.delete(base)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status, "delete") }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = client.update(base, attributes)
        if status == errSecItemNotFound {
            let added = client.add(base.merging(attributes) { $1 })
            guard added == errSecSuccess else { throw Self.error(added, "add") }
        } else if status != errSecSuccess {
            throw Self.error(status, "update")
        }
    }

    /// `errSecInteractionNotAllowed`: before first unlock or while prewarming.
    ///
    /// Everything else is a failure.
    private static func error(_ status: OSStatus, _ operation: String) -> StorageError {
        if status == errSecInteractionNotAllowed { return .unavailable }
        Log.session(.error)?.error("Keychain \(operation, privacy: .public) failed: \(status, privacy: .public)")
        return .failed("keychain \(operation) \(status)")
    }
}

/// The Security calls behind `KeychainStore`, injectable so tests can simulate a locked Keychain.
package struct KeychainClient: Sendable {
    package var copyMatching: @Sendable ([String: Any]) -> (OSStatus, Data?)
    package var add: @Sendable ([String: Any]) -> OSStatus
    package var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    package var delete: @Sendable ([String: Any]) -> OSStatus

    package init(
        copyMatching: @escaping @Sendable ([String: Any]) -> (OSStatus, Data?),
        add: @escaping @Sendable ([String: Any]) -> OSStatus,
        update: @escaping @Sendable ([String: Any], [String: Any]) -> OSStatus,
        delete: @escaping @Sendable ([String: Any]) -> OSStatus
    ) {
        self.copyMatching = copyMatching
        self.add = add
        self.update = update
        self.delete = delete
    }

    /// The real Keychain.
    package static let system = KeychainClient(
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

package enum SecureKeys {
    package static let credentials = "install"
    package static let pendingLogouts = "pending-logouts"
}
