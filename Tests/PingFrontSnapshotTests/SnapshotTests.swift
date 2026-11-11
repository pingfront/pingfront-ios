#if canImport(UIKit)
    import XCTest
    import UIKit
    @_spi(Snapshots) import PingFrontUI

    /// Host-less smoke test: renders the whole matrix into a temporary folder to prove every state
    /// builds and lays out.
    ///
    /// Without a window scene, rendering falls back to `layer.render`, which cannot
    /// draw continuous-corner strokes; pixel-exact images need a host app's real window scene.
    @MainActor
    final class SnapshotSmokeTests: XCTestCase {
        func testMatrixRenders() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "pingfront-snapshots-\(UUID().uuidString)")
            let result = try await SnapshotMatrix.render(to: directory, scene: nil)
            XCTAssertGreaterThanOrEqual(result.count, 45)
            let manifest = try Data(contentsOf: directory.appending(path: "manifest.json"))
            let entries = try JSONSerialization.jsonObject(with: manifest) as? [[String: Any]]
            XCTAssertEqual(entries?.count, result.count)
            try? FileManager.default.removeItem(at: directory)
        }
    }
#endif
