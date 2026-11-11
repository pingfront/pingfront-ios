/// Tracks the last applied thread sequence number and detects gaps in live events.
package struct SeqTracker: Sendable, Equatable {
    package enum Decision: Sendable, Equatable {
        /// The next event in order: apply it.
        case apply
        /// Already seen: apply idempotently (updates) or ignore.
        case duplicate
        /// Events were missed: repair with `GET /thread/messages?after=<after>`, then apply.
        case gap(after: Int)
    }

    package private(set) var lastSeq: Int

    package init(lastSeq: Int = 0) { self.lastSeq = lastSeq }

    package func decide(_ seq: Int) -> Decision {
        if seq <= lastSeq { return .duplicate }
        if seq == lastSeq + 1 { return .apply }
        return .gap(after: lastSeq)
    }

    /// Records that everything up to `seq` is applied.
    package mutating func advance(to seq: Int) { lastSeq = max(lastSeq, seq) }

    package mutating func reset(to seq: Int) { lastSeq = seq }
}
