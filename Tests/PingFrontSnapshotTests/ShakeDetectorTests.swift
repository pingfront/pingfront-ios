#if canImport(UIKit)
    import CoreMotion
    import Foundation
    import XCTest
    @testable import PingFrontReports
    #if targetEnvironment(simulator)
        import notify
    #endif

    /// CoreMotion calls the accelerometer handler on its own queue.
    ///
    /// A handler that inherits the main
    /// actor traps there, so shake to report crashed the app on the first sample.
    final class ShakeDetectorTests: XCTestCase {
        func testHandlerRunsOffTheMainThread() async {
            let (samples, input) = AsyncStream.makeStream(of: Double.self)
            let handler = ShakeDetector.magnitudes(into: input)
            // A detached task runs on the global executor, never the main thread, like CoreMotion's queue. Only
            // CoreMotion can make a CMAccelerometerData (one made with init() crashes when read), so the handler
            // gets no sample: entering it off the main thread is what traps when it inherits the main actor.
            await Task.detached {
                handler(nil, nil)
                input.finish()
            }.value
            var received: [Double] = []
            for await sample in samples { received.append(sample) }
            XCTAssertEqual(received, [])
            XCTAssertEqual(ShakeDetector.magnitude(3, 4, 12), 13)
        }

        #if targetEnvironment(simulator)
            /// The simulator has no accelerometer: Device > Shake (the notification it posts) is a shake there, so
            /// shake to report can be tried in the simulator.
            @MainActor func testDeviceShakeInTheSimulatorIsAShake() async throws {
                let shakes = ShakeDetector.shakes()
                let first = Task { () -> Bool in
                    for await _ in shakes { return true }
                    return false
                }
                try await Task.sleep(for: .milliseconds(600))
                notify_post("com.apple.UIKit.SimulatorShake")  // what Device > Shake posts
                let timeout = Task {
                    try await Task.sleep(for: .seconds(5))
                    first.cancel()
                }
                let shook = await first.value
                timeout.cancel()
                XCTAssertTrue(shook, "Device > Shake in the simulator did nothing")
            }
        #endif
    }
#endif
