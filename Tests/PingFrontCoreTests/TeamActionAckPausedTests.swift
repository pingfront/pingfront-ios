import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// A team action answer refused because the app is paused is kept, with no retry, and goes on the next drain (the
/// next session start, refresh or chat open), as on Android.
@Suite("Team action answers while paused")
struct TeamActionAckPausedTests {
    @Test("403 app_paused keeps the answer and stops; the next drain sends it once")
    func pausedKeepsTheAnswer() async {
        let persistence = MemoryPersistence()
        let acks = TeamActionAcks(persistence: persistence)
        await acks.enqueue(id: "tar_1", TeamActionAck(ok: true))
        let calls = Counter()
        let paused = await acks.drain { _ async throws(PingFrontError) in
            await calls.add()
            throw .server(ServerError(status: 403, code: .appPaused, message: "paused"))
        }
        #expect(paused == .paused)
        #expect(await calls.value == 1, "no retry while paused")
        // Kept on disk: a relaunch still has it.
        #expect(await TeamActionAcks(persistence: persistence).all().map(\.id) == ["tar_1"])
        let sent = await acks.drain { _ async throws(PingFrontError) in await calls.add() }
        #expect(sent == .idle)
        #expect(await calls.value == 2)
        #expect(await acks.all().isEmpty)
    }
}

actor Counter {
    var value = 0
    func add() { value += 1 }
}
