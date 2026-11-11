package import Foundation

/// The file-storage seam for the outbox, drafts, config cache and message cache.
package protocol Persistence: Sendable {
    func read(_ name: String) async throws -> Data?
    func write(_ name: String, _ data: Data) async throws
    func remove(_ name: String) async throws
}

/// Files in Application Support/PingFront, excluded from backup, with file protection on iOS.
package struct FilePersistence: Persistence {
    private let directory: URL

    package init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "PingFront", directoryHint: .isDirectory)
    }

    @concurrent package func read(_ name: String) async throws -> Data? {
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try Data(contentsOf: url)
    }

    @concurrent package func write(_ name: String, _ data: Data) async throws {
        try prepareDirectory()
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS) || os(visionOS) || os(watchOS) || os(tvOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: directory.appending(path: name), options: options)
    }

    @concurrent package func remove(_ name: String) async throws {
        let url = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prepareDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
    }
}

package enum Files {
    package static let outbox = "outbox.json"
    package static let draft = "draft.json"
    package static let config = "config.json"
    package static let thread = "thread-cache.json"
    package static let hostLookVersion = "host-look-version"
    package static let teamActionAcks = "team-action-acks.json"
    /// Card action reports waiting to be sent (`CardActionReports`).
    package static let cardActions = "card-actions.json"
    /// The latest `ContextCollection` from a session answer.
    package static let contextCollection = "context-collection.json"
    /// `installId:hash` of the screens list this install last sent (`ScreensReporter`).
    package static let screensSent = "screens-sent"
}
