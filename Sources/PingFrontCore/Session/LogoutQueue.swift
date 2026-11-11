import Foundation
internal import os

/// Installs this device logged out of, until the server accepted `POST /me/logout` for each.
/// One actor owns the list and persists it after every change, removing entries by `installId`,
/// so overlapping drains can never drop a logout that has not reached the server.
package actor LogoutQueue {
    private let file: VersionedFile<[InstallCredentials]>
    private var pending: [InstallCredentials] = []
    private var loaded = false

    package init(secure: any SecureStore) {
        file = VersionedFile(
            SecureKeys.pendingLogouts, version: 1, records: SecureRecords(secure),
            migrations: [0: { try JSONDecoder().decode([InstallCredentials].self, from: $0) }])
    }

    private func load() async {
        guard !loaded else { return }
        do {
            let stored = try await file.load() ?? []
            // Merge: anything added before the first load stays.
            pending = stored + pending.filter { added in !stored.contains { $0.installId == added.installId } }
            loaded = true
        } catch {
            // Locked Keychain: keep what is in memory and read again next time; never overwrite.
        }
    }

    private func persist() async {
        guard loaded else { return }
        do { try await file.save(pending.isEmpty ? nil : pending) } catch {
            Log.session(.error)?.error("Could not store pending logouts: \(error.logDescription, privacy: .public)")
        }
    }

    package func add(_ credentials: InstallCredentials) async {
        await load()
        guard !pending.contains(where: { $0.installId == credentials.installId }) else { return }
        pending.append(credentials)
        await persist()
    }

    package func all() async -> [InstallCredentials] {
        await load()
        return pending
    }

    /// Sends each pending logout; removes an entry only when the server accepted it (or rejected it for good).
    package func drain(api: APIClient) async {
        for credentials in await all() {
            do throws(PingFrontError) {
                _ = try await api.send(Endpoints.logout(credentials))
                await remove(credentials.installId)
            } catch  where error.isTransient {
                continue
            } catch {
                Log.session(.info)?.info("Logout was not accepted: \(error.logDescription, privacy: .public)")
                await remove(credentials.installId)
            }
        }
    }

    private func remove(_ installId: String) async {
        pending.removeAll { $0.installId == installId }
        await persist()
    }
}
