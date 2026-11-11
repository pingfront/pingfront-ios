import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

/// Collects PATCH bodies.
actor PatchLog {
    private(set) var patches: [UpdateMeRequest] = []
    func add(_ patch: UpdateMeRequest) { patches.append(patch) }
}

@Suite("PATCH /me coalescing")
struct CoalescerTests {
    let clock = TestClock()
    let log = PatchLog()

    func makeCoalescer() async -> PatchCoalescer {
        let coalescer = PatchCoalescer(time: TimeSource(clock))
        let log = log
        await coalescer.setSender { patch async throws(PingFrontError) in
            await log.add(patch)
            return UpdateMeResponse(person: PersonSummary(id: "p", level: .guest, name: nil), identityProblem: nil)
        }
        return coalescer
    }

    /// Lets the flush window elapse and waits for the flush to finish.
    func elapseWindow(expecting count: Int) async {
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(250))
        await eventually { await log.patches.count >= count }
        // Give an empty flush time to (not) send.
        await settle()
    }

    @Test("Nothing is sent before a session exists")
    func inactive() async {
        let coalescer = await makeCoalescer()
        await coalescer.stage(.traits(["a": "1"]))
        clock.advance(by: .seconds(10))
        await settle()
        #expect(await log.patches.isEmpty)
        #expect(clock.sleeperCount == 0)
        #expect(await coalescer.pendingPatch().traits == ["a": "1"])
    }

    @Test("Changes within 250 ms become one PATCH with only the changed fields")
    func coalesces() async throws {
        let coalescer = await makeCoalescer()
        await coalescer.stage(.traits(["a": "1"]))
        await coalescer.activate()
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(100))
        await coalescer.stage(.traits(["b": "2"]))
        await coalescer.stage(.identity(Identity(userId: "u1", name: "Ada")))
        clock.advance(by: .milliseconds(149))
        await settle()
        #expect(await log.patches.isEmpty)
        clock.advance(by: .milliseconds(1))
        await eventually { await log.patches.count == 1 }

        let patches = await log.patches
        #expect(patches.count == 1)
        let patch = try #require(patches.first)
        #expect(patch.traits == ["a": "1", "b": "2"])
        #expect(patch.identity?.userId == "u1")
        #expect(patch.entitlement == nil && patch.offers == nil && patch.push == nil && patch.hostLook == nil)
    }

    @Test("Identical values send nothing; one changed trait sends only that key")
    func onlyChanges() async throws {
        let coalescer = await makeCoalescer()
        await coalescer.activate()
        await coalescer.stage(.traits(["a": "1", "b": "2"]))
        await coalescer.stage(.entitlement(Entitlement(state: .trial)))
        await elapseWindow(expecting: 1)
        #expect(await log.patches.count == 1)

        await coalescer.stage(.traits(["a": "1"]))
        await coalescer.stage(.entitlement(Entitlement(state: .trial)))
        await elapseWindow(expecting: 2)
        #expect(await log.patches.count == 1)

        await coalescer.stage(.traits(["b": "3"]))
        await elapseWindow(expecting: 2)
        let patch = try #require(await log.patches.last)
        #expect(await log.patches.count == 2)
        #expect(patch.traits == ["b": "3"])
        #expect(patch.entitlement == nil && patch.identity == nil)
        let json = String(decoding: try WireJSON.encode(patch), as: UTF8.self)
        #expect(json == #"{"traits":{"b":"3"}}"#)
    }

    @Test("Clearing the push token sends an explicit null")
    func pushNull() async throws {
        let coalescer = await makeCoalescer()
        await coalescer.activate()
        await coalescer.stage(.push(PushRegistration(provider: .apns, token: "abcd", environment: .sandbox)))
        await elapseWindow(expecting: 1)
        let first = try #require(await log.patches.last)
        #expect(
            String(decoding: try WireJSON.encode(first), as: UTF8.self)
                == #"{"push":{"environment":"sandbox","provider":"apns","token":"abcd"}}"#)

        await coalescer.stage(.push(nil))
        await elapseWindow(expecting: 2)
        let second = try #require(await log.patches.last)
        #expect(second.push == .clear)
        #expect(String(decoding: try WireJSON.encode(second), as: UTF8.self) == #"{"push":null}"#)
    }

    @Test("Values that went out with the session are not sent again")
    func markSent() async {
        let coalescer = await makeCoalescer()
        await coalescer.stage(.traits(["a": "1"]))
        await coalescer.markSent(await coalescer.stagedProfile())
        await coalescer.activate()
        await elapseWindow(expecting: 1)
        #expect(await log.patches.isEmpty)
    }
}

@Suite("Profile diff")
struct ProfileTests {
    @Test("patch(since:) sends only changed fields and trait keys")
    func patch() {
        var sent = Profile()
        sent.traits = ["a": "1", "b": "2"]
        sent.identity = Identity(userId: "u1")
        var now = sent
        now.traits["b"] = "3"
        now.traits["c"] = "4"
        let patch = now.patch(since: sent)
        #expect(patch.traits == ["b": "3", "c": "4"])
        #expect(patch.identity == nil)
        #expect(Profile().patch(since: Profile()).isEmpty)
    }

    @Test("Trait validation drops values over the limits")
    func validation() {
        let long = String(repeating: "x", count: 513)
        let (traits, problems) = ProfileValidation.clean(["ok": "1", "": "2", "long": long, String(repeating: "k", count: 65): "3"])
        #expect(traits == ["ok": "1"])
        #expect(problems.count == 3)
        #expect(ProfileValidation.isEmail("ada@example.com"))
        #expect(!ProfileValidation.isEmail("ada@example"))
        #expect(!ProfileValidation.isEmail("@example.com"))
    }

    @Test("Identity token claims are read without verifying")
    func identityToken() {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let token = "\(b64(#"{"alg":"HS256"}"#)).\(b64(#"{"sub":"user_7","name":"Ada","exp":2000000000}"#)).sig"
        let claims = IdentityToken.claims(token)
        #expect(claims?.sub == "user_7" && claims?.name == "Ada" && claims?.email == nil)
        #expect(IdentityToken.claims("not-a-jwt") == nil)
        #expect(IdentityToken.claims("a.\(b64(#"{"name":"no sub"}"#)).c") == nil)
    }
}
