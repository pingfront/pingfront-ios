import Foundation
import Testing
import os

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// N4: a team action created while the live socket is open reaches the app's `teamActions` stream from the socket.
///
/// No catch-up read is needed. The frame is the one the server sent on 6 Nov 2026 for "Extend trial" (captured off the
/// wire, key order and spacing as sent).
@Suite("Live team actions")
@MainActor
struct LiveTeamActionTests {
    let key = "pk_test_abcdefghijklmnopqrstuvvd"
    static let frame =
        #"{"type": "team_action", "action": {"id": "tar_lAS0ZXuApUT5UKXYJALs", "days": 7, "name": "Extend trial", "until": "2026-11-13T02:30:30.699Z", "fields": {}, "actionId": "extend_trial", "createdAt": "2026-11-06T02:30:30.699Z", "expiresAt": "2026-11-13T02:30:30.699Z", "ackRequired": true}}"#

    @Test("The captured server frame decodes")
    func decodes() throws {
        guard case .teamAction(let action) = try ServerEvent.decode(Data(Self.frame.utf8)) else {
            Issue.record("not a team action")
            return
        }
        #expect(action.id == "tar_lAS0ZXuApUT5UKXYJALs" && action.days == 7 && action.ackRequired)
    }

    @Test("An action pushed on the open socket reaches teamActions")
    func arrivesLive() async throws {
        let gate = Gate()
        let thread =
            #"{"thread":{"id":"thr_1","status":"open","lastSeq":0,"readSeq":0,"unread":0},"messages":[],"hasOlder":false,"team":[],"policy":{"canSend":true}}"#
        let transport = GatedTransport(
            gate: gate,
            auto: [
                "POST sessions": (200, Wire.session()), "GET config": (503, Wire.error("unavailable")), "GET thread": (200, thread),
            ])
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: transport, secure: MemorySecureStore(), persistence: MemoryPersistence(), time: TimeSource(TestClock()))
        facade.start(appKey: key, configuration: configuration)
        Retain.keep(facade)
        defer { facade.teardown() }
        let received = TeamActionTests.Received(facade.teamActions)
        facade.chatVisibilityChanged(true)
        #expect(await eventually { transport.socketLog.count == 1 }, "the chat opened its live socket")
        let socket = try #require(transport.socketLog.sockets.withLock { $0.first })
        socket.push(#"{"type":"hello","threadId":"thr_1","rev":1,"status":"open","lastSeq":0,"readSeq":0,"teamReadSeq":0}"#)
        socket.push(Self.frame)
        #expect(await eventually { await MainActor.run { received.ids } == ["tar_lAS0ZXuApUT5UKXYJALs"] })
    }
}
