package import Foundation

/// Server events on the live socket (the protocol's `ServerEvent`).
package enum ServerEvent: Sendable, Equatable {
    /// Who is typing; a kind this version doesn't know decodes as `unknown` (its dots never show).
    package enum TypingAuthorKind: String, Sendable, TolerantStringEnum {
        case team, ai, unknown
        package static let fallback = Self.unknown
    }

    /// `rev` 0: the server has no thread for this person (before their first message, or after a reset).
    case hello(lastSeq: Int, readSeq: Int, teamReadSeq: Int? = nil, rev: Int? = nil, status: ThreadStatus? = nil)
    case message(seq: Int, message: Message)
    case messageUpdated(seq: Int, message: Message)
    case typing(kind: TypingAuthorKind, name: String?, on: Bool)
    case read(upToSeq: Int)
    case thread(status: ThreadStatus)
    case reset
    /// The team reset this conversation from the dashboard: every message is gone; the socket stays open.
    case threadReset(threadId: String)
    case config(revision: Int, draft: Bool)
    case reauth
    /// A team action for the host app. No `seq`: it doesn't change the thread.
    case teamAction(TeamActionPayload)
    /// An event type this SDK version does not know. Ignored.
    case unknown(type: String)

    /// The thread sequence number, for events that change the thread.
    package var seq: Int? {
        switch self {
        case .message(let seq, _), .messageUpdated(let seq, _): seq
        default: nil
        }
    }

    package static func decode(_ data: Data) throws -> ServerEvent {
        try WireJSON.decode(Wire.self, from: data).event
    }

    private struct Wire: Decodable {
        let event: ServerEvent
        private enum Keys: String, CodingKey {
            case type, threadId, lastSeq, readSeq, teamReadSeq, rev, seq, message, author, on, by, upToSeq, status, revision, draft, action
        }
        private struct TypingAuthor: Decodable {
            let kind: TypingAuthorKind
            let name: String?
        }
        /// The `type` discriminator values of the protocol's `ServerEvent`.
        private enum EventType: String {
            case hello, message, typing, read, thread, reset, config, reauth
            case messageUpdated = "message_updated"
            case teamAction = "team_action"
            case threadReset = "thread_reset"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard let known = EventType(rawValue: type) else {
                event = .unknown(type: type)
                return
            }
            switch known {
            case .hello:
                // Before the first message there is no thread (`threadId: null`, `rev: 0`): `rev` 0 means "no thread".
                // The engine never stores it (holding 0 would make the first card tap after the person writes a
                // 409 `thread_reset`), and a late no-thread hello never resets a thread it holds.
                let noThread = try c.contains(.threadId) && c.decodeNil(forKey: .threadId)
                let rev = try c.decodeIfPresent(Int.self, forKey: .rev)
                event = .hello(
                    lastSeq: try c.decode(Int.self, forKey: .lastSeq),
                    readSeq: try c.decode(Int.self, forKey: .readSeq),
                    teamReadSeq: try c.decodeIfPresent(Int.self, forKey: .teamReadSeq),
                    rev: noThread || rev == 0 ? 0 : rev,
                    status: try c.decodeIfPresent(ThreadStatus.self, forKey: .status)
                )
            case .message:
                event = .message(seq: try c.decode(Int.self, forKey: .seq), message: try c.decode(Message.self, forKey: .message))
            case .messageUpdated:
                event = .messageUpdated(seq: try c.decode(Int.self, forKey: .seq), message: try c.decode(Message.self, forKey: .message))
            case .typing:
                let author = try c.decode(TypingAuthor.self, forKey: .author)
                event = .typing(kind: author.kind, name: author.name, on: try c.decode(Bool.self, forKey: .on))
            case .read: event = .read(upToSeq: try c.decode(Int.self, forKey: .upToSeq))
            case .thread: event = .thread(status: try c.decode(ThreadStatus.self, forKey: .status))
            case .reset: event = .reset
            case .threadReset:
                // Without the thread it names, it is not the event the protocol defines: ignored, as unknown.
                if let threadId = try c.decodeIfPresent(String.self, forKey: .threadId) {
                    event = .threadReset(threadId: threadId)
                } else {
                    event = .unknown(type: type)
                }
            case .config:
                event = .config(revision: try c.decode(Int.self, forKey: .revision), draft: try c.decode(Bool.self, forKey: .draft))
            case .reauth: event = .reauth
            case .teamAction: event = .teamAction(try c.decode(TeamActionPayload.self, forKey: .action))
            }
        }
    }
}

/// Client events on the live socket.
package enum ClientEvent: Sendable, Equatable, Encodable {
    case typing(on: Bool)
    case ping

    private enum Keys: String, CodingKey { case type, on }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .typing(let on):
            try c.encode("typing", forKey: .type)
            try c.encode(on, forKey: .on)
        case .ping: try c.encode("ping", forKey: .type)
        }
    }
}

package enum LiveProtocol {
    package static let subprotocol = "pingfront.v1"
    package static let heartbeat: Duration = .seconds(30)
    /// How long a WebSocket pong may take before the connection counts as dead.
    package static let pongDeadline: Duration = .seconds(10)
    package static let typingThrottle: Duration = .seconds(3)
}
