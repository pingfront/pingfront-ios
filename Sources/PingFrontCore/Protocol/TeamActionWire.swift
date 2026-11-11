package import Foundation

/// `TeamActionPayload`: an action a teammate ran from the inbox that the host app has to do ("Fix it for them").
///
/// Arrives on the live socket (`team_action`, no `seq`) and from `GET /team-actions`.
package struct TeamActionPayload: Sendable, Equatable, Codable {
    /// The run's id; acks and deduplication use it.
    package var id: String
    /// Which action (`extend_trial`, `grant_access` or the app's own id).
    package var actionId: String
    /// The action's name, as the team sees it.
    package var name: String
    /// The values the teammate filled in, by field key.
    package var fields: [String: String]
    /// Days, for `extend_trial` and `grant_access`.
    package var days: Int?
    /// The new access end, for `extend_trial` and `grant_access`.
    package var until: Date?
    /// True when the receipt line waits for the app's confirmation.
    package var ackRequired: Bool
    package var createdAt: Date
    /// After this the server drops the action (no receipt).
    package var expiresAt: Date

    package init(
        id: String, actionId: String, name: String, fields: [String: String] = [:], days: Int? = nil, until: Date? = nil,
        ackRequired: Bool, createdAt: Date, expiresAt: Date
    ) {
        self.id = id
        self.actionId = actionId
        self.name = name
        self.fields = fields
        self.days = days
        self.until = until
        self.ackRequired = ackRequired
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// `GET /team-actions`: the pending actions, oldest first (at most 50).
package struct PendingTeamActionsResponse: Sendable, Equatable, Decodable {
    package var actions: [TeamActionPayload]

    private enum Keys: String, CodingKey { case actions }

    package init(from decoder: any Decoder) throws {
        // One malformed action never hides the others.
        actions = try decoder.container(keyedBy: Keys.self).decodeLossyArray(TeamActionPayload.self, forKey: .actions)
    }
}

/// `TeamActionAck`: the body of `POST /team-actions/{id}/ack`.
package struct TeamActionAck: Sendable, Equatable, Codable {
    package var ok: Bool
    /// `ok: false` only: what went wrong, shown to the team, never to the person (at most 200 characters).
    package var message: String?

    package init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(200))) }
    }
}
