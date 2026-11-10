import Foundation

/// How far a session's event stream has been seen. Hermes numbers each session's frames (`seq`,
/// from 1) within an epoch (`replay_epoch`: a new one when the server restarts or stops keeping the
/// session's frames), and keeps the last 512 for a client that comes back (`session.events.since`).
nonisolated struct EventCursor: Equatable, Sendable {
    var epoch: String
    var seq: Int
}

/// Every session's cursor, kept across reconnects (a new socket starts from where the old one
/// stopped). Foundation only, so it can be checked away from a Mac.
nonisolated struct EventCursors: Sendable {
    private var bySession: [String: EventCursor] = [:]

    subscript(session: String) -> EventCursor? { bySession[session] }

    /// A frame's params, live or replayed. False for one at or behind its session's cursor: seen
    /// already (a replay and what a resume catches up can meet). Otherwise its cursor moves to it.
    /// A frame without a seq (a server that does not number them, or not a session's) goes through.
    mutating func admit(_ frame: JSONValue) -> Bool {
        guard let session = frame["session_id"]?.string, !session.isEmpty,
              let seq = frame["seq"]?.int, let epoch = frame["replay_epoch"]?.string
        else { return true }
        if let cursor = bySession[session], cursor.epoch == epoch, seq <= cursor.seq { return false }
        bySession[session] = EventCursor(epoch: epoch, seq: seq)
        return true
    }

    /// An attach's snapshot (`session.resume`, `session.create`): its `replay_epoch` and
    /// `last_sequence`, where the stream goes on from. A cursor already past it in the same epoch
    /// stays: what a resume catches up comes before its reply.
    mutating func start(_ snapshot: JSONValue) {
        guard let session = snapshot["session_id"]?.string, !session.isEmpty,
              let epoch = snapshot["replay_epoch"]?.string, let seq = snapshot["last_sequence"]?.int
        else { return }
        if let cursor = bySession[session], cursor.epoch == epoch, cursor.seq >= seq { return }
        bySession[session] = EventCursor(epoch: epoch, seq: seq)
    }

    /// The server cannot replay from here (`snapshot_required`): the next snapshot starts it again.
    mutating func forget(_ session: String) {
        bySession[session] = nil
    }

    mutating func removeAll() {
        bySession = [:]
    }
}

/// When the next automatic reconnect is tried: 1, 2, 4, 8 s, then every 15 s.
nonisolated enum Backoff {
    static func delay(afterFailures failures: Int) -> TimeInterval {
        min(15, 0.5 * pow(2, Double(min(max(failures, 1), 6))))
    }
}
