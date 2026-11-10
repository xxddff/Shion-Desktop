import Foundation

/// Where a message you sent is on its way to the server. None: Hermes has it.
nonisolated enum Delivery: Equatable, Sendable {
    /// Sent: no receipt yet.
    case sending
    /// The connection went before the receipt came: once it is back, the server says (DeliveryCheck).
    case unsure
    /// Hermes does not have it: 重发 sends it again, under the same submission id. The reason is
    /// Hermes's refusal in words, when it refused it.
    case unsent(String?)

    var unsent: Bool {
        if case .unsent = self { return true }
        return false
    }
}

/// Whether Hermes got what went out just before the connection went. Hermes admits a prompt once
/// per submission id (`prompt.submit`'s `submission_id`; Shion uses the chat item's id), and says so:
/// every admission is published at once in `session.info`, whose `pending` lists the admissions
/// still queued or started by `input_id` (the submission id); a turn's `message.complete` names the
/// submission it ran (`persisted_turn.submission_id`); a snapshot's `pending` lists them too.
/// Foundation only, so it can be checked away from a Mac.
nonisolated enum DeliveryCheck {
    /// The submission ids a frame (its params, live or replayed) says Hermes has.
    static func submissions(in frame: JSONValue) -> [String] {
        let payload = frame["payload"]
        switch frame["type"]?.string {
        case "session.info":
            return (payload?["pending"]?.array ?? []).compactMap { $0["input_id"]?.string }
        case "message.complete":
            return payload?["persisted_turn"]?["submission_id"]?.string.map { [$0] } ?? []
        default:
            return []
        }
    }

    /// The submission ids of a snapshot's `pending` (`session.resume`).
    static func pending(in snapshot: JSONValue) -> Set<String> {
        Set((snapshot["pending"]?.array ?? []).compactMap { $0["input_id"]?.string })
    }

    /// Whether Hermes has a message that went out before the connection went, once it is back.
    /// With the session's frames replayed from before it went out (`caughtUp`), Hermes has it only
    /// if they, or what came live before the drop, named it (`seen`): an admission is published as
    /// it is made. Without them (the replay could not reach back), the snapshot's pending list,
    /// then the newest page: a message of yours in the same words, stored no earlier than a
    /// minute before this one went out.
    static func arrived(id: String, text: String, at: Date, seen: Set<String>, caughtUp: Bool,
                        pending: Set<String>, rows: [StoredUserRow]) -> Bool {
        if seen.contains(id) || pending.contains(id) { return true }
        if caughtUp { return false }
        return rows.contains { $0.text == text && $0.at >= at.addingTimeInterval(-60) }
    }

    /// Hermes's refusal of a prompt, in words (`error.data.reason`). Nil: it says it in its own.
    static func refusal(_ reason: String?) -> String? {
        switch reason {
        case "permission_denied": return "这个连接还没接上这个对话"
        case "runtime_draining": return "服务器正在重启"
        case "queue_full": return "排队的消息太多了"
        case "not_found": return "服务器上没有这个对话了"
        default: return nil
        }
    }
}

/// A message of yours on a transcript page: its words and when it was stored.
nonisolated struct StoredUserRow: Equatable, Sendable {
    var text: String
    var at: Date
}
