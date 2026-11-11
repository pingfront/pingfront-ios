import Foundation
import Security
import Testing
import os

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

@Suite("Versioned persistence and Keychain errors")
struct PersistenceTests {
    let disk = MemoryPersistence()

    func outboxFile() -> VersionedFile<[PendingMessage]> {
        VersionedFile(
            Files.outbox, version: 1, records: FileRecords(disk),
            migrations: [0: { try WireJSON.decode([PendingMessage].self, from: $0) }])
    }

    @Test("An old-format file (no envelope) migrates, and is rewritten in the current version")
    func migratesLegacy() async throws {
        let legacy = [PendingMessage(clientId: "c-1", text: "still unsent")]
        await disk.write(Files.outbox, try WireJSON.encode(legacy))
        let file = outboxFile()
        #expect(try await file.load()?.map(\.clientId) == ["c-1"])
        #expect(await file.issues == [.migrated(from: 0)])
        let rewritten = try #require(await disk.read(Files.outbox))
        #expect(String(decoding: rewritten, as: UTF8.self).hasPrefix(#"{"v":1"#))
        // The outbox itself reads it too.
        let outbox = Outbox(persistence: disk)
        #expect(await outbox.load().map(\.clientId) == ["c-1"])
    }

    @Test("A corrupt file is moved aside with its bytes intact, reported, and never overwritten")
    func corruptPreserved() async throws {
        let garbage = Data(#"{"v":1,"value":[{"clientId":42}]}"#.utf8)
        await disk.write(Files.outbox, garbage)
        let file = outboxFile()
        #expect(try await file.load() == nil)
        #expect(await file.issues == [.unreadable(storedVersion: 1, asideName: "outbox.json.aside-1")])
        #expect(await disk.read("outbox.json.aside-1") == garbage)
        try await file.save([PendingMessage(clientId: "c-2", text: "new")])
        #expect(await disk.read("outbox.json.aside-1") == garbage)
    }

    @Test("A file from a newer SDK version is preserved and reported, not decoded or overwritten")
    func futureVersionPreserved() async throws {
        let future = Data(#"{"v":2,"value":{"queue":[]}}"#.utf8)
        await disk.write(Files.outbox, future)
        let outbox = Outbox(persistence: disk)
        #expect(await outbox.load().isEmpty)
        await outbox.enqueue(PendingMessage(clientId: "c-3", text: "after downgrade"))
        #expect(await disk.read("outbox.json.aside-1") == future)
        let file = outboxFile()
        #expect(try await file.load()?.map(\.clientId) == ["c-3"])
    }

    @Test("Unreadable credentials and logout queues are kept aside too")
    func keychainRecordsAside() async throws {
        let secure = MemorySecureStore()
        try await secure.write(SecureKeys.credentials, Data("not json".utf8))
        let file = SessionStore.credentialsFile(secure)
        #expect(try await file.load() == nil)
        #expect(try await secure.read("install.aside-1") == Data("not json".utf8))
    }

    @Test("A locked Keychain (errSecInteractionNotAllowed) is not 'no install': no session is minted")
    func lockedKeychain() async throws {
        let lock = OSAllocatedUnfairLock(initialState: true)
        let items = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
        let client = KeychainClient(
            copyMatching: { query in
                if lock.withLock({ $0 }) { return (errSecInteractionNotAllowed, nil) }
                let key = query[kSecAttrAccount as String] as? String ?? ""
                return items.withLock { $0[key] }.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
            },
            add: { query in
                if lock.withLock({ $0 }) { return errSecInteractionNotAllowed }
                let key = query[kSecAttrAccount as String] as? String ?? ""
                let data = query[kSecValueData as String] as? Data
                items.withLock { $0[key] = data }
                return errSecSuccess
            },
            update: { query, attributes in
                if lock.withLock({ $0 }) { return errSecInteractionNotAllowed }
                let key = query[kSecAttrAccount as String] as? String ?? ""
                guard items.withLock({ $0[key] }) != nil else { return errSecItemNotFound }
                let data = attributes[kSecValueData as String] as? Data
                items.withLock { $0[key] = data }
                return errSecSuccess
            },
            delete: { _ in errSecSuccess }
        )
        let keychain = KeychainStore(service: "test", client: client)
        await #expect(throws: StorageError.unavailable) { _ = try await keychain.read(SecureKeys.credentials) }

        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        let time = TimeSource(TestClock())
        let api = APIClient(
            baseURL: StubTransport.base, appKey: "pk_test_abcdefghijklmnopqrstuvvd", transport: StubTransport(server: server),
            cooldowns: CooldownBook(time: time))
        let session = SessionStore(api: api, secure: keychain, time: time, profile: PatchCoalescer(time: time))
        await #expect(throws: PingFrontError.protectedDataUnavailable) { _ = try await session.token(reason: .chatOpened) }
        #expect(await server.requests.isEmpty, "a new install was minted while the Keychain was locked")
        #expect(await session.hasInstall() == false)

        lock.withLock { $0 = false }  // the device is unlocked
        #expect(try await session.token(reason: .chatOpened) == "tok_1")
        #expect(await server.requests("POST sessions").count == 1)
        #expect(items.withLock { $0[SecureKeys.credentials] } != nil)
    }
}
