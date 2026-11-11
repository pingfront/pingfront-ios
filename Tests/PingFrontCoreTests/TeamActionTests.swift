import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// Team actions ("Fix it for them"): the live event, the catch-up read, once-per-id delivery and the queued answers.
@Suite("Team actions")
struct TeamActionTests {
    let key = "pk_test_abcdefghijklmnopqrstuvvd"

    static func payload(_ id: String, actionId: String = "repair_sync") -> TeamActionPayload {
        TeamActionPayload(
            id: id, actionId: actionId, name: "Repair bank sync", fields: ["bank": "Monzo"], ackRequired: true,
            createdAt: Date(timeIntervalSince1970: 1_793_440_000), expiresAt: Date(timeIntervalSince1970: 1_794_044_800))
    }

    static func pending(_ ids: String...) -> String {
        let actions = ids.map {
            #"{"id":"\#($0)","actionId":"repair_sync","name":"Repair bank sync","fields":{},"ackRequired":true,"createdAt":"2026-10-31T10:00:00.000Z","expiresAt":"2026-11-07T10:00:00.000Z"}"#
        }
        return #"{"actions":[\#(actions.joined(separator: ","))]}"#
    }

    @MainActor
    func configured(_ server: StubServer, persistence: MemoryPersistence = MemoryPersistence()) -> PingFront {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        configuration.dependencies = Dependencies(
            transport: StubTransport(server: server), secure: MemorySecureStore(), persistence: persistence, time: TimeSource(TestClock()))
        facade.start(appKey: key, configuration: configuration)
        Retain.keep(facade)
        return facade
    }

    /// Collects what a `teamActions` stream delivers.
    @MainActor final class Received {
        var actions: [TeamAction] = []
        var ids: [String] { actions.map(\.id) }
        var task: Task<Void, Never>?

        init(_ stream: AsyncStream<TeamAction>) {
            task = Task { @MainActor [weak self] in
                for await action in stream { self?.actions.append(action) }
            }
        }
    }

    @Test("The live team_action event decodes, with no seq")
    func decodesLiveEvent() throws {
        let json =
            #"{"type":"team_action","action":{"id":"tar_1","actionId":"extend_trial","name":"Extend trial","fields":{},"#
            + #""days":7,"until":"2026-11-07T10:00:00.000Z","ackRequired":false,"#
            + #""createdAt":"2026-10-31T10:00:00.000Z","expiresAt":"2026-11-07T10:00:00.000Z"}}"#
        let event = try ServerEvent.decode(Data(json.utf8))
        guard case .teamAction(let action) = event else {
            Issue.record("Decoded \(event)")
            return
        }
        #expect(action.days == 7)
        #expect(action.ackRequired == false)
        #expect(event.seq == nil)
    }

    @Test("A live action reaches the app once per id; the catch-up read never repeats it")
    @MainActor func deliversOncePerId() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET team-actions", .ok(Self.pending("tar_1", "tar_2")))
        let facade = configured(server)
        defer { facade.teardown() }
        let received = Received(facade.teamActions)
        let engine = try #require(facade.engine)
        await engine.apply(.teamAction(Self.payload("tar_1")))
        await engine.apply(.teamAction(Self.payload("tar_1")))
        // Starting the session reads the pending actions.
        _ = try await engine.session.token(reason: .prepare)
        #expect(await eventually { await MainActor.run { received.ids } == ["tar_1", "tar_2"] })
        #expect(received.actions.first?.fields == ["bank": "Monzo"])
        #expect(await server.requests("GET team-actions").count == 1)
    }

    @Test("Nothing is read before a session exists (sessions stay lazy)")
    @MainActor func noReadWithoutSession() async throws {
        let server = StubServer()
        let facade = configured(server)
        defer { facade.teardown() }
        facade.engine?.catchUpTeamActions()
        await settle()
        #expect(await server.requests("GET team-actions").isEmpty)
        #expect(await server.requests("POST sessions").isEmpty)
    }

    @Test("An action that arrives before the app listens is replayed to the first stream")
    @MainActor func replaysUnanswered() async throws {
        let facade = configured(StubServer())
        defer { facade.teardown() }
        await facade.engine?.apply(.teamAction(Self.payload("tar_1")))
        let received = Received(facade.teamActions)
        #expect(await eventually { await MainActor.run { received.ids } == ["tar_1"] })
    }

    @Test("complete() and fail(message:) post their answers; an answered action is not replayed")
    @MainActor func answers() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET team-actions", .ok(Self.pending()))
        await server.on("POST team-actions/tar_1/ack", .json(204, ""))
        await server.on("POST team-actions/tar_2/ack", .json(204, ""))
        let facade = configured(server)
        defer { facade.teardown() }
        let engine = try #require(facade.engine)
        _ = try await engine.session.token(reason: .prepare)
        let received = Received(facade.teamActions)
        await engine.apply(.teamAction(Self.payload("tar_1")))
        await engine.apply(.teamAction(Self.payload("tar_2")))
        #expect(await eventually { await MainActor.run { received.actions.count } == 2 })
        await received.actions[0].complete()
        await received.actions[1].fail(message: String(repeating: "x", count: 250))
        #expect(await eventually { await server.requests("POST team-actions/tar_2/ack").count == 1 })
        let done = try #require(await server.requests("POST team-actions/tar_1/ack").first?.json)
        #expect(done["ok"] as? Bool == true)
        #expect(done["message"] == nil)
        let failed = try #require(await server.requests("POST team-actions/tar_2/ack").first?.json)
        #expect(failed["ok"] as? Bool == false)
        #expect((failed["message"] as? String)?.count == 200)
        // A second answer is ignored (the first one wins), and a new stream gets nothing old.
        await received.actions[0].fail(message: "late")
        await settle()
        #expect(await server.requests("POST team-actions/tar_1/ack").count == 1)
        let later = Received(facade.teamActions)
        await settle()
        #expect(later.ids.isEmpty)
    }

    @Test("404 and 409 drop the answer instead of retrying it")
    @MainActor func dropsRefusedAnswers() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET team-actions", .ok(Self.pending()))
        await server.on("POST team-actions/tar_1/ack", .json(409, Wire.error("conflict")))
        await server.on("POST team-actions/tar_2/ack", .json(204, ""))
        let facade = configured(server)
        defer { facade.teardown() }
        let engine = try #require(facade.engine)
        _ = try await engine.session.token(reason: .prepare)
        await engine.answerTeamAction("tar_1", TeamActionAck(ok: true))
        await engine.answerTeamAction("tar_2", TeamActionAck(ok: true))
        #expect(await eventually { await server.requests("POST team-actions/tar_2/ack").count == 1 })
        #expect(await server.requests("POST team-actions/tar_1/ack").count == 1)
        #expect(await engine.teamActionAcks.all().isEmpty)
    }

    @Test("An answer queued offline is kept, and its action is not delivered again after a relaunch")
    @MainActor func answersSurviveRelaunch() async throws {
        let persistence = MemoryPersistence()
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET team-actions", .ok(Self.pending()))
        await server.on("POST team-actions/tar_1/ack", .failure(.notConnectedToInternet))
        let first = configured(server, persistence: persistence)
        let engine = try #require(first.engine)
        _ = try await engine.session.token(reason: .prepare)
        await engine.answerTeamAction("tar_1", TeamActionAck(ok: true))
        #expect(await eventually { await server.requests("POST team-actions/tar_1/ack").count >= 1 })
        first.teardown()

        // Next launch: the server still lists it as pending; the app already did it, so it isn't delivered.
        let relaunched = configured(server, persistence: persistence)
        defer { relaunched.teardown() }
        let received = Received(relaunched.teamActions)
        await relaunched.engine?.receiveTeamActions([Self.payload("tar_1")])
        await settle()
        #expect(received.ids.isEmpty)
        #expect(await relaunched.engine?.teamActionAcks.all().map(\.id) == ["tar_1"])
    }

    @Test("Logout forgets delivered actions and queued answers")
    @MainActor func logoutClears() async throws {
        let server = StubServer()
        await server.on("POST sessions", .ok(Wire.session()))
        await server.on("GET team-actions", .ok(Self.pending()))
        await server.on("POST me/logout", .json(204, ""))
        await server.on("POST team-actions/tar_1/ack", .failure(.notConnectedToInternet))
        let facade = configured(server)
        defer { facade.teardown() }
        let engine = try #require(facade.engine)
        _ = try await engine.session.token(reason: .prepare)
        await engine.apply(.teamAction(Self.payload("tar_2")))
        await engine.answerTeamAction("tar_1", TeamActionAck(ok: true))
        await engine.performLogout()
        #expect(await engine.teamActionAcks.all().isEmpty)
        let received = Received(facade.teamActions)
        await settle()
        #expect(received.ids.isEmpty)
    }

    @Test("AppConfig features: branding is optional, and a missing flag never resets the others")
    func brandingFlag() throws {
        let base = #"{"appName":"Ledgerly","look":{},"team":[],"features":{"photos":false,"reports":true,"translation":false,"ai":true"#
        let free = try WireJSON.decode(AppConfig.self, from: Data((base + #","branding":true}}"#).utf8))
        #expect(free.features.branding)
        let pro = try WireJSON.decode(AppConfig.self, from: Data((base + "}}").utf8))
        #expect(!pro.features.branding)
        #expect(!pro.features.photos)
        #expect(pro.features.ai)
        #expect(ResolvedLook.resolve(remote: free, code: ChatAppearance(), codeTopics: nil, host: nil).showsBranding)
        #expect(!ResolvedLook.resolve(remote: pro, code: ChatAppearance(), codeTopics: nil, host: nil).showsBranding)
    }
}
