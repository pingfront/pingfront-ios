internal import CryptoKit
internal import Foundation
internal import os

/// A screen of your app that a saved link can open (`AppScreen` in the protocol).
///
/// Register them with `PingFront.registerScreens(_:)`. The team picks one in the dashboard and sends it as a link
/// card; the person's tap reaches your `onScreen` handler with the id and the link's parameters.
public struct AppScreen: Codable, Sendable, Equatable, Hashable {
    /// Your app's own route id: `^[A-Za-z0-9][A-Za-z0-9_./:-]{0,99}$` (`"settings.sound"`, `"plans/yearly"`).
    public var id: String
    /// What the team sees in the dashboard ("Sound settings").
    ///
    /// At most 60 characters; never shown to the person.
    public var title: String?

    /// Creates a screen.
    public init(id: String, title: String? = nil) {
        self.id = id
        self.title = title
    }
}

/// The screens this build registered, checked and capped as the protocol asks (https://pingfront.sh/docs/offers#saved-links).
package final class ScreenRegistry: Sendable {
    /// At most this many screens; the rest are dropped.
    package static let limit = 200

    /// `ScreenId`: `^[A-Za-z0-9][A-Za-z0-9_./:-]{0,99}$`.
    package static func isValid(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard let first = scalars.first, scalars.count <= 100, first.isASCII, first.properties.isAlphabetic || ("0"..."9").contains(first)
        else { return false }
        return scalars.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            return ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || "_./:-".unicodeScalars.contains(scalar)
        }
    }

    /// What happens to a bad entry.
    ///
    /// A debug build stops (`assertionFailure`), a release build logs and drops it. Tests replace it to record.
    static let invalid = OSAllocatedUnfairLock<@Sendable (String) -> Void>(initialState: { message in
        Log.config(.error)?.error("\(message, privacy: .private)")
        #if DEBUG
            assertionFailure(message)
        #endif
    })

    /// `nil` until the app registers screens; `[]` once it says it registers none.
    private let state = OSAllocatedUnfairLock<[AppScreen]?>(initialState: nil)

    package init() {}

    /// The registered screens, or `nil` when the app never registered any.
    package var screens: [AppScreen]? { state.withLock { $0 } }

    /// Whether this build registered `id`.
    package func contains(_ id: String) -> Bool { state.withLock { $0?.contains { $0.id == id } ?? false } }

    /// Checks, de-duplicates and caps `screens`, and keeps them.
    package func register(_ screens: [AppScreen]) {
        var kept: [AppScreen] = []
        var seen = Set<String>()
        for var screen in screens {
            guard Self.isValid(screen.id) else {
                report("registerScreens: \"\(screen.id)\" is not a valid screen id (^[A-Za-z0-9][A-Za-z0-9_./:-]{0,99}$); it was dropped.")
                continue
            }
            guard seen.insert(screen.id).inserted else {
                report("registerScreens: the screen id \"\(screen.id)\" is registered twice; the first one is kept.")
                continue
            }
            guard kept.count < Self.limit else {
                report("registerScreens: more than \(Self.limit) screens; the rest were dropped.")
                break
            }
            if let title = screen.title {
                let trimmed = String(String.UnicodeScalarView(title.unicodeScalars.prefix(60)))
                screen.title = trimmed.isEmpty ? nil : trimmed
            }
            kept.append(screen)
        }
        let registered = kept
        state.withLock { $0 = registered }
    }

    private func report(_ message: String) {
        let handler = Self.invalid.withLock { $0 }
        handler(message)
    }

    /// The list and the app version, hashed: what this install last sent, to send it again only when it changed.
    package static func hash(_ screens: [AppScreen], appVersion: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = (try? encoder.encode(screens)) ?? Data()
        data.append(Data("|\(appVersion)".utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// When the registered screens ride on a request the SDK makes anyway: every `POST /sessions` once the app registered
/// screens; a refresh or `PATCH /me` only when the list or the app version changed since this install last sent it
/// (the hash is kept with the install). It never makes a request of its own.
package actor ScreensReporter {
    private let registry: ScreenRegistry
    private let persistence: any Persistence
    /// `installId:hash` of the list this install last sent.
    private var sent: String?
    private var loaded = false

    package init(registry: ScreenRegistry, persistence: any Persistence) {
        self.registry = registry
        self.persistence = persistence
    }

    /// What a request adds to `device.app.screens`, and the hash to record once it went out.
    package struct Draft: Sendable {
        package var screens: [AppScreen]
        package var hash: String
    }

    /// For `POST /sessions`: the list whenever the app registered one.
    package func forCreate(appVersion: String) -> Draft? {
        guard let screens = registry.screens else { return nil }
        return Draft(screens: screens, hash: ScreenRegistry.hash(screens, appVersion: appVersion))
    }

    /// For a refresh or `PATCH /me`: the list only when it, or the app version, changed since `installId` sent it.
    package func ifChanged(installId: String, appVersion: String) async -> Draft? {
        guard let screens = registry.screens else { return nil }
        await load()
        let hash = ScreenRegistry.hash(screens, appVersion: appVersion)
        guard sent != "\(installId):\(hash)" else { return nil }
        return Draft(screens: screens, hash: hash)
    }

    /// The list went out for `installId`.
    package func delivered(_ draft: Draft, installId: String) async {
        let record = "\(installId):\(draft.hash)"
        sent = record
        loaded = true
        try? await persistence.write(Files.screensSent, Data(record.utf8))
    }

    private func load() async {
        guard !loaded else { return }
        if let data = try? await persistence.read(Files.screensSent) { sent = String(data: data, encoding: .utf8) }
        loaded = true
    }
}
