import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore
@testable import PingFrontTestSupport

@Suite("Moments and unread polling")
struct MomentsTests {
    @Test(
        "Unread polling: 20 s for 2 minutes, 2 minutes for an hour, then stop",
        arguments: [
            (Duration.zero, Duration.seconds(20) as Duration?),
            (.seconds(119), .seconds(20)),
            (.seconds(120), .seconds(120)),
            (.seconds(3719), .seconds(120)),
            (.seconds(3720), nil),
            (.seconds(86_400), nil),
        ])
    func unreadSchedule(elapsed: Duration, interval: Duration?) {
        #expect(UnreadSchedule.interval(sinceActivity: elapsed) == interval)
    }

    @Test(
        "Moment names",
        arguments: [
            ("paywall_closed", true), ("trial.cancelled-2", true), ("a", true), (String(repeating: "a", count: 64), true),
            ("", false), ("_x", false), ("Paywall", false), ("has space", false), (String(repeating: "a", count: 65), false),
        ])
    func names(name: String, valid: Bool) {
        #expect(MomentGate.isValid(name) == valid)
    }

    @Test("Listened moments are cached for 5 minutes")
    func gateTTL() async {
        let clock = TestClock()
        let gate = MomentGate(time: TimeSource(clock))
        #expect(await !gate.isFresh())
        await gate.update(["paywall_closed"])
        #expect(await gate.isFresh())
        #expect(await gate.contains("paywall_closed"))
        #expect(await !gate.contains("other"))
        clock.advance(by: .seconds(299))
        #expect(await gate.isFresh())
        clock.advance(by: .seconds(1))
        #expect(await !gate.isFresh())
    }

    @Test("Moment props encode as strings, numbers and booleans")
    func props() throws {
        let request = MomentRequest(
            name: "paywall_closed", props: ["plan": "pro", "count": 3, "ratio": 0.5, "first": true], occurredAt: nil, clientId: "c")
        let json = String(decoding: try WireJSON.encode(request), as: UTF8.self)
        #expect(json == #"{"clientId":"c","name":"paywall_closed","props":{"count":3,"first":true,"plan":"pro","ratio":0.5}}"#)
    }
}

@Suite("Clock-driven helpers")
struct ClockTests {
    @Test("WakeSignal wakes a waiter, or the next waiter when nobody waits")
    func wake() async {
        let signal = WakeSignal()
        signal.notify()
        await signal.wait()  // returns immediately: pending notification
        let waiter = Task {
            await signal.wait()
            return true
        }
        await settle()
        signal.notify()
        #expect(await waiter.value)
    }

    @Test("WakeSignal.wait(timeout:) returns when the injected clock passes the timeout")
    func wakeTimeout() async {
        let clock = TestClock()
        let signal = WakeSignal()
        let waiter = Task {
            await signal.wait(timeout: .seconds(30), time: TimeSource(clock))
            return true
        }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(30))
        #expect(await waiter.value)
    }

    @Test("Cancelling a waiter does not hang")
    func wakeCancel() async {
        let signal = WakeSignal()
        let waiter = Task { await signal.wait() }
        await settle()
        waiter.cancel()
        await waiter.value
    }

    @Test("TimeSource measures and sleeps on the injected clock")
    func timeSource() async {
        let clock = TestClock()
        let time = TimeSource(clock)
        #expect(time.now() == .zero)
        clock.advance(by: .seconds(5))
        #expect(time.now() == .seconds(5))
        let sleeper = Task { await time.pause(.seconds(10)) }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(10))
        #expect(await sleeper.value)
        let cancelled = Task { await time.pause(.seconds(10)) }
        await clock.waitForSleepers(1)
        cancelled.cancel()
        #expect(await cancelled.value == false)
    }
}

@Suite("Image preparation")
struct ImagePreparationTests {
    @Test("SHA-256 is lowercase hex")
    func sha() {
        #expect(ImagePreparation.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Non-images are rejected with a plain message")
    func notAnImage() async {
        await #expect(throws: PingFrontError.invalidInput("This file is not an image.")) {
            try await ImagePreparation.prepare(Data("hello".utf8))
        }
    }
}
