import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// The language-neutral behaviour scenarios in the protocol fixtures' `scenarios` folder: each file is a scripted
/// exchange served in order by a fake transport, and the SDK must make exactly those requests and end in the stated
/// state.
@Suite("Behaviour scenarios", .serialized)
@MainActor
struct ScenarioTests {
    nonisolated static let root = TestPaths.protocolFixtures.appending(path: "scenarios")
    nonisolated static let key = "pk_test_abcdefghijklmnopqrstuvvd"

    let secure = MemorySecureStore()
    let persistence = MemoryPersistence()
    let clock = TestClock()

    @Test("Every scenario file has a driver here")
    func everyScenarioIsDriven() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.root.path()).filter { $0.hasSuffix(".json") }
        let driven: Set = [
            "auth-401-refresh-retry", "auth-refresh-revoked", "card-action-retry", "outbox-resend", "team-action-pending", "thread-reset",
        ]
        #expect(Set(files.map { String($0.dropLast(5)) }) == driven)
    }

    @Test("auth-401-refresh-retry: one refresh, then one retry with the new token")
    func authRefreshRetry() async throws {
        let scenario = try Scenario.load("auth-401-refresh-retry")
        let (server, requests) = (scenario.server, scenario.then["requests"] as? Int)
        let (facade, engine) = try await makeEngine(scenario)
        defer { withExtendedLifetime(facade) {} }
        await engine.loadThread()
        try await server.finish()
        #expect(await server.served == requests)
        let accessToken = scenario.then["accessToken"] as? String
        #expect(await engine.session.accessTokenForTesting == accessToken)
        #expect(facade.conversation.phase == .ready)
    }

    @Test("auth-refresh-revoked: wipe local state, no retry")
    func authRefreshRevoked() async throws {
        let scenario = try Scenario.load("auth-refresh-revoked")
        let (server, requests) = (scenario.server, scenario.then["requests"] as? Int)
        let (facade, engine) = try await makeEngine(scenario)
        defer { withExtendedLifetime(facade) {} }
        engine.start()
        defer { engine.stop() }
        _ = try? await engine.client.send(Endpoints.read(upTo: 3))
        try await server.finish()
        #expect(await server.served == requests)
        #expect(await eventually { (try? await engine.session.installCredentials()) == nil })
        #expect(await eventually { await engine.outbox.all().isEmpty })
        // The revoke runs the same local wipe as a logout, in an owned task: the revision goes with it.
        #expect(await eventually { await engine.api.threadRevision.value == nil })
        #expect(await eventually { await engine.session.revoked == false })
    }

    @Test("outbox-resend: a lost send is resent with the same clientId, one bubble")
    func outboxResend() async throws {
        let scenario = try Scenario.load("outbox-resend")
        let (server, requests) = (scenario.server, scenario.then["requests"] as? Int)
        let (facade, engine) = try await makeEngine(scenario)
        defer { withExtendedLifetime(facade) {} }
        // The action's send: queued with the scripted clientId (a new send mints a random one), then flushed.
        let clientId = try #require((scenario.steps.first?.request["body"] as? [String: Any])?["clientId"] as? String)
        await engine.outbox.enqueue(PendingMessage(clientId: clientId, text: "Is my streak back?"))
        // The engine's own drain and deliverer. The API client resends an idempotent request once after a dropped
        // connection, so the resend may come from that retry or from the next flush; either way it carries the
        // same clientId and the outbox empties.
        var deliveries = engine.outbox.deliveries.makeAsyncIterator()
        for _ in 0..<2 where await !engine.outbox.all().isEmpty {
            _ = await engine.outbox.drain(uploadsPaused: false, deliver: engine.deliverer())
        }
        let delivered = await deliveries.next()
        try await server.finish()
        #expect(await server.served == requests)
        #expect(await engine.outbox.all().isEmpty)
        // One bubble: the 200 carries the original message, merged by id.
        if let message = delivered?.message { facade.conversation.merge([message]) }
        let thread = try #require(scenario.then["thread"] as? [String: Any])
        #expect(facade.conversation.messages.map(\.id) == thread["messageIds"] as? [String])
    }

    @Test("card-action-retry: a lost report is resent with the same clientId and body; the queue empties")
    func cardActionRetry() async throws {
        let scenario = try Scenario.load("card-action-retry")
        let (server, requests) = (scenario.server, scenario.then["requests"] as? Int)
        let (facade, engine) = try await makeEngine(scenario)
        defer { withExtendedLifetime(facade) {} }
        // The action's pick, queued with the scripted clientId (a new pick mints a random one), then sent by the queue.
        let body = try #require(scenario.steps.first?.request["body"] as? [String: Any])
        let path = try #require(scenario.steps.first?.request["path"] as? String)
        let cardId = try #require(path.split(separator: "/").dropLast().last.map(String.init))
        await engine.cardReports.enqueue(
            cardId: cardId,
            CardActionRequest(
                messageId: body["messageId"] as? String ?? "", action: .chosen, answer: .choice(id: body["choiceId"] as? String ?? "")),
            clientId: body["clientId"] as? String ?? "")
        engine.startOutboxLoop()
        defer { engine.stopWrites() }
        engine.cardReportsWake.notify()
        #expect(await eventually { await server.served >= 1 })
        // The queue's backoff (at most 1.2 s for the first retry) on the injected clock.
        for _ in 0..<20 where await server.served < 2 {
            clock.advance(by: .seconds(2))
            await settle(20)
        }
        try await server.finish()
        #expect(await server.served == requests)
        #expect(await eventually { await engine.cardReports.all().isEmpty })
    }

    @Test("team-action-pending: emitted once; a lost ack is retried")
    func teamActionPending() async throws {
        let scenario = try Scenario.load("team-action-pending")
        let (server, requests) = (scenario.server, scenario.then["requests"] as? Int)
        let (facade, engine) = try await makeEngine(scenario)
        defer { withExtendedLifetime(facade) {} }
        engine.startOutboxLoop()
        defer { engine.stopWrites() }
        var received: [TeamAction] = []
        let stream = facade.teamActions
        let reader = Task { @MainActor in
            for await action in stream {
                received.append(action)
                await action.complete()
            }
        }
        defer { reader.cancel() }
        engine.catchUpTeamActions()
        #expect(await eventually { await server.served >= 2 })
        for _ in 0..<20 where await server.served < 3 {
            clock.advance(by: .seconds(30))
            await settle(20)
        }
        try await server.finish()
        #expect(await server.served == requests)
        #expect(received.map(\.id) == scenario.then["emitted"] as? [String])
    }

    @Test("thread-reset: drop the cache, keep draft and outbox, reload without the revision, send with the new one")
    func threadReset() async throws {
        let scenario = try Scenario.load("thread-reset")
        let (server, requests) = (scenario.server, scenario.then["requests"] as? Int)
        let (facade, engine) = try await makeEngine(scenario)
        defer { withExtendedLifetime(facade) {} }
        engine.start()
        defer { engine.stop() }
        facade.conversation.hasOlder = true
        engine.loadOlder()
        #expect(await eventually(timeout: .seconds(5)) { await server.served == 3 })
        try await server.finish()
        #expect(await server.served == requests)
        let thread = try #require(scenario.then["thread"] as? [String: Any])
        let rev = thread["rev"] as? Int
        #expect(await engine.api.threadRevision.value == rev)
        let ids = thread["messageIds"] as? [String]
        let settled = await eventually { await MainActor.run { facade.conversation.messages.map(\.id) } == ids }
        #expect(settled, "\(facade.conversation.messages.map(\.id))")
        #expect(facade.conversation.draft == scenario.then["draft"] as? String)
        #expect(await eventually { await engine.outbox.all().isEmpty })
    }

    // MARK: Setup from `given`

    func makeEngine(_ scenario: Scenario) async throws -> (PingFront, Engine) {
        let facade = PingFront()
        var configuration = PingFrontConfiguration()
        configuration.baseURL = StubTransport.base
        let dependencies = Dependencies(
            transport: ScenarioTransport(server: scenario.server), secure: secure, persistence: persistence, time: TimeSource(clock))
        let engine = Engine(facade: facade, key: try AppKey.parse(Self.key).get(), configuration: configuration, dependencies: dependencies)
        facade.engine = engine
        Retain.keep(facade)
        let given = scenario.given
        if let id = given["installId"] as? String, let secret = given["installSecret"] as? String {
            try await secure.write(
                SecureKeys.credentials, try JSONEncoder().encode(InstallCredentials(installId: id, installSecret: secret)))
        }
        if let token = given["accessToken"] as? String { await engine.session.adoptForTesting(token: token) }
        if let thread = given["thread"] as? [String: Any] {
            if let rev = thread["rev"] as? Int { await engine.api.threadRevision.set(rev) }
            let messages = (thread["messages"] as? [[String: Any]] ?? []).map {
                makeMessage($0["id"] as? String ?? "", seq: $0["seq"] as? Int ?? 0)
            }
            facade.conversation.messages = messages
            facade.conversation.phase = .ready
        }
        if let draft = given["draft"] as? String { facade.conversation.draft = draft }
        for item in given["outbox"] as? [[String: Any]] ?? [] {
            await engine.outbox.enqueue(PendingMessage(clientId: item["clientId"] as? String ?? "", text: item["text"] as? String ?? ""))
        }
        return (facade, engine)
    }
}

/// One scenario file.
struct Scenario {
    struct Step {
        let name: String
        let request: [String: Any]
        let response: [String: Any]
    }
    let given: [String: Any]
    let steps: [Step]
    let then: [String: Any]
    let server: ScenarioServer

    static func load(_ name: String) throws -> Scenario {
        let data = try Data(contentsOf: ScenarioTests.root.appending(path: "\(name).json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let steps = (json["steps"] as? [[String: Any]] ?? []).map {
            Step(
                name: $0["name"] as? String ?? "", request: $0["request"] as? [String: Any] ?? [:],
                response: $0["response"] as? [String: Any] ?? [:])
        }
        return Scenario(
            given: json["given"] as? [String: Any] ?? [:], steps: steps, then: json["then"] as? [String: Any] ?? [:],
            server: ScenarioServer(
                steps: steps.map {
                    try? JSONSerialization.data(withJSONObject: ["request": $0.request, "response": $0.response, "name": $0.name])
                }.compactMap { $0 }))
    }
}

/// Serves a scenario's steps in order and records every mismatch.
actor ScenarioServer {
    private let steps: [Data]
    private(set) var served = 0
    private(set) var mismatches: [String] = []

    init(steps: [Data]) { self.steps = steps }

    enum Answer {
        case http(Int, [String: String], Data)
        case lost
        case offline
    }

    func answer(_ request: URLRequest) -> Answer {
        let method = request.httpMethod ?? "GET"
        var path = request.url?.path() ?? ""
        if let query = request.url?.query(), !query.isEmpty { path += "?\(query)" }
        guard served < steps.count,
            let step = try? JSONSerialization.jsonObject(with: steps[served]) as? [String: Any],
            let expected = step["request"] as? [String: Any], let response = step["response"] as? [String: Any]
        else {
            mismatches.append("unexpected request \(method) \(path) after \(served) steps")
            return .http(500, [:], Data(#"{"error":{"code":"internal","message":"unscripted","docs":"x"}}"#.utf8))
        }
        let name = step["name"] as? String ?? "step \(served + 1)"
        let operation = (expected["operation"] as? String ?? "").split(separator: " ")
        var problems: [String] = []
        if operation.first.map(String.init) != method { problems.append("method \(method)") }
        if expected["path"] as? String != path { problems.append("path \(path)") }
        let headers = request.allHTTPHeaderFields ?? [:]
        func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
        for (key, value) in expected["headers"] as? [String: String] ?? [:] where header(key) != value {
            problems.append("header \(key)=\(header(key) ?? "absent"), want \(value)")
        }
        for key in expected["absentHeaders"] as? [String] ?? [] where header(key) != nil {
            problems.append("header \(key) must be absent")
        }
        var body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        // Device context (`DevicePatch`) is optional on session calls and rides along on requests the SDK makes
        // anyway; a scenario that doesn't script it doesn't check it.
        if var object = body as? [String: Any], (expected["body"] as? [String: Any])?["device"] == nil {
            object["device"] = nil
            body = object
        }
        if let want = expected["body"] {
            if !Self.equal(want, body) { problems.append("body \(request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "none")") }
        } else if let body, !(body is NSNull) {
            problems.append("unexpected body")
        }
        if !problems.isEmpty { mismatches.append("\(name): \(problems.joined(separator: "; "))") }
        served += 1
        switch response["transport"] as? String {
        case "lost": return .lost
        case "offline": return .offline
        default:
            let status = response["status"] as? Int ?? 200
            let data = response["body"].flatMap { $0 is NSNull ? nil : try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
            return .http(status, response["headers"] as? [String: String] ?? [:], data)
        }
    }

    /// Fails unless every step was served and every request matched.
    func finish() throws {
        if !mismatches.isEmpty { throw ScenarioFailure(message: mismatches.joined(separator: "\n")) }
        if served != steps.count { throw ScenarioFailure(message: "\(steps.count - served) steps unserved") }
    }

    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (let a as [String: Any], let b as [String: Any]):
            return a.count == b.count && a.allSatisfy { equal($0.value, b[$0.key]) }
        case (let a as [Any], let b as [Any]):
            return a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
        case (let a as NSNumber, let b as NSNumber): return a == b
        case (let a as String, let b as String): return a == b
        case (nil, nil), (is NSNull, nil), (nil, is NSNull), (is NSNull, is NSNull): return true
        default: return false
        }
    }
}

struct ScenarioFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// A transport that answers from a `ScenarioServer`.
///
/// No network; the live socket is never opened.
struct ScenarioTransport: Transport {
    let server: ScenarioServer

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        switch await server.answer(request) {
        case .lost: throw URLError(.networkConnectionLost)
        case .offline: throw URLError(.notConnectedToInternet)
        case .http(let status, let headers, let body):
            var all = headers
            all["Content-Type"] = "application/json"
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: all) else {
                throw URLError(.badServerResponse)
            }
            return (body, response)
        }
    }

    func webSocket(url: URL, protocols: [String]) async throws -> any WebSocketConnection {
        throw URLError(.unsupportedURL)
    }
}
