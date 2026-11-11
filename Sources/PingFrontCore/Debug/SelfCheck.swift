import Foundation
internal import os

#if DEBUG
    /// Debug-only launch arguments for coding agents:
    /// - `-PingFrontSelfCheck`: creates a session, sends "Setup check from <app>", waits for the ack and
    ///   logs one line: `PingFront self-check: PASS` or `PingFront self-check: FAIL <code>: <what to do>`.
    /// - `-PingFrontPreview welcome|conversation`: opens the chat with offline fixture data.
    extension Engine {
        func runLaunchArguments() {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains(LaunchArgument.selfCheck) {
                run { [weak self] in
                    guard let self else { return }
                    SetupCheck.emit(await self.setupCheck().line)
                }
            }
            if let index = arguments.firstIndex(of: LaunchArgument.preview) {
                let name = index + 1 < arguments.count ? arguments[index + 1] : "conversation"
                enterPreview(PreviewFixture(rawValue: name) ?? .conversation)
                facade.openChat()
            }
        }
    }
#endif

#if DEBUG
    extension SetupCheck {
        /// Logs the result line and prints it, so `simctl launch --console` shows it (debug launch argument only).
        package static func emit(_ line: String) {
            if line.hasSuffix("PASS") {
                Log.selfCheck(.info)?.notice("\(line, privacy: .public)")
            } else {
                Log.selfCheck(.error)?.fault("\(line, privacy: .public)")
            }
            print(line)
        }
    }
#endif
