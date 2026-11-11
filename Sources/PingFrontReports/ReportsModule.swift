#if canImport(UIKit)
    public import PingFrontCore
    #if DEBUG
        public import CoreGraphics  // the debug-only capture SPI takes CGPoint
    #else
        internal import CoreGraphics
    #endif
    import SwiftUI
    import UIKit
    import CoreMotion
    import OSLog
    import PingFrontUI
    #if targetEnvironment(simulator)
        import notify
    #endif

    extension PingFrontModule {
        /// Shake to report, a screenshot with markup, the log tail and device state.
        public static var reports: PingFrontModule { reports(.all) }

        /// Bug reports with options.
        ///
        /// - Parameter options: What the module does; both by default.
        /// - Returns: The module, for `config.use(_:)`.
        public static func reports(_ options: ReportOptions) -> PingFrontModule {
            PingFrontModule(id: ModuleID.reports) { context in
                let flow = ReportFlow(pingFront: context.pingFront)
                context.setReportPresenter(flow)
                context.setReportContextProvider(ReportContextCollector(includeLogTail: options.contains(.logTail)))
                if options.contains(.shakeToReport) {
                    context.run {
                        for await _ in ShakeDetector.shakes() { flow.presentReport(prefill: nil) }
                    }
                }
            }
        }
    }

    /// What the reports module does.
    public struct ReportOptions: OptionSet, Sendable {
        /// The raw bits.
        public let rawValue: Int
        /// Wraps raw bits.
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Open the report flow when the person shakes the device (foreground only).
        public static let shakeToReport = ReportOptions(rawValue: 1 << 0)
        /// Attach the last 10 minutes of this app's log (at most 64 KB).
        ///
        /// Values your app logs as `.private`
        /// stay redacted.
        public static let logTail = ReportOptions(rawValue: 1 << 1)
        /// Everything.
        public static let all: ReportOptions = [.shakeToReport, .logTail]
    }

    #if DEBUG
        @_spi(Marketing)
        extension PingFront {
            /// Debug builds only.
            ///
            /// Opens the report flow with text and marks already drawn, for captures.
            /// `marks` are strokes in unit coordinates (0...1) of the screenshot.
            public func presentReportForCapture(text: String, marks: [[CGPoint]]) {
                (reportPresenterForCapture as? ReportFlow)?.presentReport(prefill: text, marks: marks)
            }
        }
    #endif

    /// Presents the report sheet with a screenshot of the current screen.
    final class ReportFlow: ReportPresenting {
        private weak var pingFront: PingFront?
        private weak var presented: UIViewController?

        init(pingFront: PingFront) { self.pingFront = pingFront }

        func presentReport(prefill: String?) { presentReport(prefill: prefill, marks: []) }

        func presentReport(prefill: String?, marks: [[CGPoint]]) {
            guard presented == nil, let pingFront, let top = Presentation.topViewController() else { return }
            // From inside the chat: the app's screen captured before the chat opened, never the chat itself.
            let chatIsOpen = pingFront.isChatVisible
            let screenshot = chatIsOpen ? Presentation.screenBeforeChat : Presentation.snapshot(of: top.view.window)
            let host = UIHostingController(
                rootView: ReportSheet(
                    pingFront: pingFront, screenshot: screenshot, prefill: prefill ?? "", initialMarks: marks,
                    screenshotCaption: chatIsOpen ? .beforeChat : .current
                ).pingFrontLanguage(pingFront))
            host.modalPresentationStyle = .formSheet
            top.present(host, animated: true)
            presented = host
        }

    }

    /// Detects a shake with the accelerometer while the app is in the foreground.
    enum ShakeDetector {
        /// The accelerometer handler, made outside the main actor: CoreMotion calls it on its queue, and a
        /// closure written inside the (main-actor) task would assert it runs on the main thread and crash.
        nonisolated static func magnitudes(into input: AsyncStream<Double>.Continuation) -> CMAccelerometerHandler {
            { data, _ in
                guard let a = data?.acceleration else { return }
                input.yield(magnitude(a.x, a.y, a.z))
            }
        }

        /// The length of an acceleration vector, in g.
        nonisolated static func magnitude(_ x: Double, _ y: Double, _ z: Double) -> Double { (x * x + y * y + z * z).squareRoot() }

        #if targetEnvironment(simulator)
            /// The simulator has no accelerometer.
            ///
            /// Its Device > Shake (Control-Command-Z) posts this notification inside the
            /// simulated device, which is how UIKit there learns of a shake, so shake to report can be tried in the
            /// simulator too.
            static let simulatorShakeNotification = "com.apple.UIKit.SimulatorShake"

            /// Each Device > Shake in the simulator, polled four times a second (`notify_check`; no dispatch queue).
            static func simulatorShakes() -> AsyncStream<Void> {
                AsyncStream { continuation in
                    let task = Task {
                        var token: Int32 = 0
                        guard notify_register_check(simulatorShakeNotification, &token) == NOTIFY_STATUS_OK else {
                            continuation.finish()
                            return
                        }
                        defer { notify_cancel(token) }
                        var changed: Int32 = 0
                        // The first check after registering always reports a change.
                        _ = notify_check(token, &changed)
                        while !Task.isCancelled {
                            if notify_check(token, &changed) == NOTIFY_STATUS_OK, changed != 0 { continuation.yield() }
                            guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { break }
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        #endif

        /// Shakes: the accelerometer on a device, Device > Shake in the simulator.
        static func shakes() -> AsyncStream<Void> {
            #if targetEnvironment(simulator)
                return simulatorShakes()
            #else
                return accelerometerShakes()
            #endif
        }

        /// Three peaks above 2.3 g within a second, then a 2 s pause.
        static func accelerometerShakes() -> AsyncStream<Void> {
            AsyncStream { continuation in
                // The motion manager lives inside this owned task; cancelling the stream stops the sensor.
                let task = Task {
                    let manager = CMMotionManager()
                    guard manager.isAccelerometerAvailable else {
                        continuation.finish()
                        return
                    }
                    manager.accelerometerUpdateInterval = 1.0 / 30
                    let (samples, input) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(8))
                    // CoreMotion delivers on an OperationQueue; that API offers no async alternative.
                    let queue = OperationQueue()  // guard:allow CoreMotion requires an OperationQueue
                    manager.startAccelerometerUpdates(to: queue, withHandler: magnitudes(into: input))
                    defer { manager.stopAccelerometerUpdates() }
                    var peaks: [ContinuousClock.Instant] = []
                    var quietUntil = ContinuousClock.now
                    await withTaskCancellationHandler {
                        for await magnitude in samples {
                            let now = ContinuousClock.now
                            guard now >= quietUntil, magnitude > 2.3 else { continue }
                            peaks = peaks.filter { now - $0 < .seconds(1) } + [now]
                            if peaks.count >= 3 {
                                peaks = []
                                quietUntil = now + .seconds(2)
                                continuation.yield()
                            }
                        }
                    } onCancel: {
                        input.finish()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Collects the log tail and device state for a report.
    struct ReportContextCollector: ReportContextProviding {
        let includeLogTail: Bool

        func reportContext() async -> ReportContext {
            let state = await Self.state()
            let tail = includeLogTail ? await Self.logTail() : nil
            return ReportContext(logTail: tail, state: state)
        }

        @MainActor static func state() -> [String: String] {
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            var state: [String: String] = [
                "os": "\(device.systemName) \(device.systemVersion)",
                "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off",
                "locale": Locale.current.identifier,
            ]
            if device.batteryLevel >= 0 { state["battery"] = "\(Int(device.batteryLevel * 100))%" }
            if let top = Presentation.topViewController() { state["screen"] = String(describing: type(of: top)).prefix(64).description }
            return state
        }

        /// The last 10 minutes of this process's log, newest last, at most 64 KB.
        @concurrent static func logTail() async -> String? {
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
            let position = store.position(date: Date.now.addingTimeInterval(-600))
            guard let entries = try? store.getEntries(at: position) else { return nil }
            var lines: [String] = []
            let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                lines.append("\(log.date.formatted(format)) [\(log.category)] \(log.composedMessage)")
            }
            let text = lines.joined(separator: "\n")
            return UTF8Tail.suffix(text, maxBytes: Limits.reportLogBytes)
        }
    }
#endif
