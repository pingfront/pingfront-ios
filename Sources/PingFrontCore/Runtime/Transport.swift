package import Foundation

/// The network seam.
///
/// Production uses `URLSessionTransport`; tests use a stub, so no actor needs a network.
package protocol Transport: Sendable {
    /// Performs an HTTP request.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Opens a WebSocket with the given subprotocols.
    func webSocket(url: URL, protocols: [String]) async throws -> any WebSocketConnection
}

/// One live socket.
package protocol WebSocketConnection: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    /// The HTTP status of a failed handshake, when known (for example 401).
    var handshakeStatus: Int? { get }
    /// Sends a protocol-level ping and returns when the pong arrives. Must end when `close()` is called.
    func ping() async throws
    func close()
}

extension WebSocketConnection {
    /// Connections without a ping (test doubles) report every ping as answered.
    package func ping() async throws {}
}

/// `URLSession` with the async APIs.
///
/// No cookies, no URL cache.
package struct URLSessionTransport: Transport {
    private let session: URLSession

    package init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    package func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    package func webSocket(url: URL, protocols: [String]) async throws -> any WebSocketConnection {
        let task = session.webSocketTask(with: url, protocols: protocols)
        task.resume()
        return URLSessionWebSocket(task: task)
    }
}

private struct URLSessionWebSocket: WebSocketConnection {
    let task: URLSessionWebSocketTask

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    var handshakeStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }

    func ping() async throws {
        // sendPing is callback-only; the handler also fires with an error when the task is cancelled.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}
