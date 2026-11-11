import Foundation
internal import os

/// The state of the live channel.
#if hasAttribute(nonexhaustive)
    @nonexhaustive
#endif
public enum LiveState: Sendable, Equatable {
    /// Not connected (chat closed).
    case stopped
    /// Opening the socket.
    case connecting
    /// Receiving events.
    case live
    /// Disconnected; retrying after `retryIn`.
    case waiting(retryIn: Duration, offline: Bool)
}

/// Owns the WebSocket while the chat is visible: subprotocols `pingfront.v1` + `bearer.<token>`,
/// heartbeat every 30 s, `reauth` handling and reconnect backoff `min(1s·2ⁿ, 30s)` ±20%.
package actor LiveConnection {
    package enum Signal: Sendable, Equatable {
        case state(LiveState)
        case event(ServerEvent)
        /// The server refused the socket (403 at the handshake) or its session (with the error, which names a closed
        /// send policy such as `app_paused`). The connection has stopped and does not reconnect by itself: the next
        /// chat open, foreground or thread load starts it again.
        case refused(PingFrontError?)
    }

    private enum Ending: Sendable {
        case failed(status: Int?, error: PingFrontError?)
        case reauth
    }

    private let api: APIClient
    private let session: SessionStore
    private let time: TimeSource
    private let backoff = Backoff.live
    private var runTask: Task<Void, Never>?
    private var connection: (any WebSocketConnection)?
    private var attempt = 0
    /// Bumped by `start` and `stop`.
    ///
    /// A run only acts (stores a socket, emits) while its generation is current,
    /// so nothing from a stopped run leaks out after `.stopped`.
    private var runGeneration: UInt64 = 0
    private let continuation: AsyncStream<Signal>.Continuation
    /// States and events, in order.
    package nonisolated let signals: AsyncStream<Signal>

    package init(api: APIClient, session: SessionStore, time: TimeSource) {
        self.api = api
        self.session = session
        self.time = time
        (signals, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    package var isRunning: Bool { runTask != nil }

    package func start(_ endpoint: LiveEndpoint) {
        guard runTask == nil else { return }
        attempt = 0
        runGeneration += 1
        let generation = runGeneration
        runTask = Task { await self.run(endpoint, generation: generation) }
    }

    package func stop() {
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        connection?.close()
        connection = nil
        continuation.yield(.state(.stopped))
    }

    /// Restarts immediately (for example after coming back to the foreground, or a failed gap repair).
    package func reconnectNow(_ endpoint: LiveEndpoint) {
        stop()
        start(endpoint)
    }

    package func send(_ event: ClientEvent) async {
        guard let connection, let data = try? WireJSON.encode(event) else { return }
        try? await connection.send(String(decoding: data, as: UTF8.self))
    }

    private func isCurrent(_ generation: UInt64) -> Bool { generation == runGeneration && !Task.isCancelled }

    private func emit(_ signal: Signal, _ generation: UInt64) {
        guard generation == runGeneration else { return }
        continuation.yield(signal)
    }

    private func run(_ endpoint: LiveEndpoint, generation: UInt64) async {
        while isCurrent(generation) {
            if let wait = await api.cooldowns.remaining(.live) {
                emit(.state(.waiting(retryIn: wait, offline: false)), generation)
                guard await time.pause(wait) else { return }
            }
            emit(.state(.connecting), generation)
            var offline = false
            do throws(PingFrontError) {
                let token = try await session.token(reason: .chatOpened)
                // Stopped while the token was on its way: never open a socket for a dead run.
                guard isCurrent(generation) else { return }
                let ending = await connect(endpoint, token: token, generation: generation)
                guard isCurrent(generation) else { return }
                switch ending {
                case .reauth:
                    await session.invalidate(token: token)
                    // One immediate retry with a fresh token; repeated reauths back off like failures.
                    if attempt == 0 {
                        attempt += 1
                        continue
                    }
                case .failed(let status, let error):
                    if status == 403 {
                        // Forbidden (the app paused, the person blocked): reconnecting gets the same answer.
                        stopRefused(nil, generation)
                        return
                    }
                    if status == 401 { await session.invalidate(token: token) }
                    if status == 429 { await api.cooldowns.record(scope: .live, retryAfter: nil) }
                    offline = error?.isOffline ?? false
                }
            } catch {
                offline = error.isOffline
                if error == .cancelled { return }
                if SendPolicy.Reason(refusal: error.code) != nil {
                    stopRefused(error, generation)
                    return
                }
                Log.live(.info)?.info("Live token failed: \(error.logDescription, privacy: .public)")
            }
            guard isCurrent(generation) else { return }
            let delay = backoff.delay(attempt: attempt)
            attempt += 1
            emit(.state(.waiting(retryIn: delay, offline: offline)), generation)
            guard await time.pause(delay) else { return }
        }
    }

    /// Ends the run after a refusal: says so, then reports the connection stopped.
    private func stopRefused(_ error: PingFrontError?, _ generation: UInt64) {
        Log.live(.info)?.info("Live refused; not reconnecting until the chat opens again.")
        emit(.refused(error), generation)
        emit(.state(.stopped), generation)
        // Not running any more, so the next start (chat open, foreground, a thread load) starts a new run.
        if generation == runGeneration { runTask = nil }
    }

    private func connect(_ endpoint: LiveEndpoint, token: String, generation: UInt64) async -> Ending {
        let socket: any WebSocketConnection
        do {
            socket = try await api.openLive(endpoint, token: token)
        } catch let error as URLError {
            return .failed(status: nil, error: .network(error.code))
        } catch {
            return .failed(status: nil, error: nil)
        }
        guard isCurrent(generation) else {
            socket.close()
            return .failed(status: nil, error: .cancelled)
        }
        connection = socket
        let time = self.time
        let ending = await withTaskGroup(of: Ending?.self) { group in
            group.addTask {
                // Heartbeat every 30 s: a failed send or a missing pong ends the connection (half-open sockets).
                let ping = (try? WireJSON.encode(ClientEvent.ping)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"type":"ping"}"#
                while await time.pause(LiveProtocol.heartbeat) {
                    do { try await socket.send(ping) } catch let error as URLError {
                        return .failed(status: nil, error: .network(error.code))
                    } catch {
                        return .failed(status: nil, error: nil)
                    }
                    guard await Self.pong(from: socket, within: LiveProtocol.pongDeadline, time: time) else {
                        Log.live(.info)?.info("No pong within the deadline; reconnecting")
                        return .failed(status: nil, error: .network(.timedOut))
                    }
                }
                return nil
            }
            group.addTask {
                while true {
                    let text: String
                    do {
                        // URLSessionWebSocketTask.receive() ignores task cancellation: closing the socket ends it.
                        text = try await withTaskCancellationHandler {
                            try await socket.receive()
                        } onCancel: {
                            socket.close()
                        }
                    } catch let error as URLError {
                        return .failed(status: socket.handshakeStatus, error: .network(error.code))
                    } catch {
                        return .failed(status: socket.handshakeStatus, error: nil)
                    }
                    guard let event = try? ServerEvent.decode(Data(text.utf8)) else { continue }
                    if event == .reauth { return .reauth }
                    await self.received(event, generation: generation)
                }
            }
            var result: Ending = .failed(status: nil, error: nil)
            for await value in group {
                if let value {
                    result = value
                    break
                }
            }
            group.cancelAll()
            return result
        }
        socket.close()
        if connection.map({ $0 as AnyObject }) === (socket as AnyObject) { connection = nil }
        return ending
    }

    /// Sends a WebSocket ping and waits for the pong, up to `deadline` on the injected clock.
    private static func pong(from socket: any WebSocketConnection, within deadline: Duration, time: TimeSource) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await withTaskCancellationHandler {
                        try await socket.ping()
                    } onCancel: {
                        socket.close()
                    }
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                _ = await time.pause(deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func received(_ event: ServerEvent, generation: UInt64) {
        guard generation == runGeneration else { return }
        if case .hello = event {
            attempt = 0
            continuation.yield(.state(.live))
        }
        continuation.yield(.event(event))
    }
}
