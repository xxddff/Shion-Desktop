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

extension EventCursor {
    /// Later in its session's stream than an attach's snapshot was taken (its `replay_epoch` and
    /// `last_sequence`, the stream's place as Hermes read the session: gateway/session_authority.py
    /// attach). False where the snapshot does not say, or is of another epoch: nothing is then
    /// known to be newer than it.
    nonisolated func isAfter(_ snapshot: JSONValue) -> Bool {
        guard let epoch = snapshot["replay_epoch"]?.string, let seq = snapshot["last_sequence"]?.int else { return false }
        return epoch == self.epoch && self.seq > seq
    }
}

/// What each session's frames last said of the things an attach's snapshot says too, and where in
/// the stream they said it. Hermes takes a snapshot (`session.resume`) with the viewer already
/// joined to the stream, and answers a moment later: a turn that ends in that moment has its
/// `message.complete` and `session.info` on the socket before the snapshot that still calls it
/// running. Such a snapshot is older than what was taken, and must not be put over it: it is read
/// again (`outdate`), and where it comes back older every time, what the frames said stands over
/// what it says: whether a turn runs (`running(after:)`), that one ended (`ended(after:)`: its
/// reply or its failure is the frames'), and what waits for an answer of yours (`current`).
/// Foundation only, so it can be checked away from a Mac.
nonisolated struct SessionWords: Sendable {
    /// How often a snapshot is asked for again when frames already taken are newer than it. Those
    /// frames are few (a turn's start and end, not its words), so one more is nearly always enough.
    static let rereads = 3

    /// What a snapshot carries and a frame can change: whether a turn runs, what waits for an
    /// answer of yours, the rows of a turn begun or ended.
    private static let said: Set<String> = [
        "message.start", "message.complete", "session.info",
        "approval.request", "approval.settled", "clarify.request", "clarify.settled",
    ]

    /// The newest frame that said whether a turn runs, and what it said.
    private var turns: [String: (at: EventCursor, running: Bool)] = [:]
    /// The newest frame that said anything a snapshot says.
    private var states: [String: EventCursor] = [:]
    /// The newest frame that ended a turn.
    private var ends: [String: EventCursor] = [:]
    /// What a frame last said of each approval or question of a session: asked, as the frame
    /// carried it (the same object a snapshot lists: gateway/session_pending_controls.py), or
    /// settled (nil).
    private var prompts: [String: [String: (at: EventCursor, asked: JSONValue?)]] = [:]

    /// A frame's params, live or replayed, as it is taken. One without a place in the stream (a
    /// server that numbers nothing) says nothing here: no snapshot can be told older than it.
    mutating func note(_ frame: JSONValue) {
        guard let session = frame["session_id"]?.string, !session.isEmpty, let type = frame["type"]?.string,
              Self.said.contains(type), let seq = frame["seq"]?.int, let epoch = frame["replay_epoch"]?.string
        else { return }
        let at = EventCursor(epoch: epoch, seq: seq)
        states[session] = at
        switch type {
        case "message.start":
            turns[session] = (at, true)
        case "message.complete":
            turns[session] = (at, false)
            ends[session] = at
        case "session.info":
            if let running = frame["payload"]?["running"]?.bool {
                turns[session] = (at, running)
            }
        case "approval.request", "clarify.request":
            if let prompt = frame["payload"], let id = prompt["prompt_id"]?.string {
                prompts[session, default: [:]][id] = (at, prompt)
            }
        case "approval.settled", "clarify.settled":
            if let id = frame["payload"]?["prompt_id"]?.string {
                prompts[session, default: [:]][id] = (at, nil)
            }
        default:
            break
        }
    }

    /// A frame already taken says something later than this snapshot does: the snapshot is not
    /// how the session is now.
    func outdate(_ snapshot: JSONValue) -> Bool {
        guard let session = snapshot["session_id"]?.string else { return false }
        return states[session]?.isAfter(snapshot) == true
    }

    /// Whether a turn runs, by a frame later than this snapshot. Nil: none said, the snapshot's
    /// own word is the newest.
    func running(after snapshot: JSONValue) -> Bool? {
        guard let session = snapshot["session_id"]?.string, let turn = turns[session], turn.at.isAfter(snapshot)
        else { return nil }
        return turn.running
    }

    /// A frame later than this snapshot ended a turn: how that turn ended (the reply it brought,
    /// or the failure it said) is what the frame said, and the snapshot's rows know nothing of it.
    func ended(after snapshot: JSONValue) -> Bool {
        guard let session = snapshot["session_id"]?.string else { return false }
        return ends[session]?.isAfter(snapshot) == true
    }

    /// The snapshot with what frames later than it said put over what it says: whether a turn
    /// runs, and what waits for an answer of yours (`prompts`). An approval or question asked
    /// since is among them, as its frame carried it, and one settled since is not, whatever the
    /// snapshot lists. So a snapshot that is still older than the frames after being asked for
    /// again neither drops an ask a frame brought nor brings back one a frame took away. Where
    /// no frame is later, or the snapshot is of another epoch (the stream started over: nothing
    /// taken before can be told newer than it), it is itself.
    func current(_ snapshot: JSONValue) -> JSONValue {
        guard case .object(var object) = snapshot, let session = object["session_id"]?.string else { return snapshot }
        if let running = running(after: snapshot) {
            object["running"] = .bool(running)
        }
        let later = (prompts[session] ?? [:]).filter { $0.value.at.isAfter(snapshot) }
        if !later.isEmpty {
            var open = (object["prompts"]?.array ?? []).filter { prompt in
                // said of again since: the frame's word, below
                prompt["prompt_id"]?.string.map { later[$0] == nil } ?? true
            }
            // asked since, in the order they were asked
            open += later.values.sorted { $0.at.seq < $1.at.seq }.compactMap(\.asked)
            object["prompts"] = .array(open)
        }
        return .object(object)
    }
}

/// When the next automatic reconnect is tried: 1, 2, 4, 8 s, then every 15 s.
nonisolated enum Backoff {
    static func delay(afterFailures failures: Int) -> TimeInterval {
        min(15, 0.5 * pow(2, Double(min(max(failures, 1), 6))))
    }
}
