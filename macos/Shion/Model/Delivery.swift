import Foundation

/// Where a message you sent is on its way to the server. None: Hermes has it.
nonisolated enum Delivery: Equatable, Sendable {
    /// Sent: no receipt yet.
    case sending
    /// The connection went before the receipt came: once it is back, the server says (DeliveryCheck).
    case unsure
    /// Put into a running turn as the connection went (引导, 打断): it may have reached the
    /// assistant, and a correction has no receipt to ask for. It is not sent again by itself.
    case unconfirmed
    /// Put into a running turn, and Hermes answered that the turn did not take it, without saying
    /// that no assistant saw it: with most assistants none did, but one that runs on Codex may
    /// have had it before its answer was given up on. So it does not say 没发出去, and it is not
    /// sent again by itself: 再发一次 sends it as a message of its own, behind the turn.
    case declined
    /// Hermes does not have it: 重发 sends it again, under the same submission id. The reason is
    /// Hermes's refusal in words, when it refused it.
    case unsent(String?)

    /// It can be sent again from its line under the message (重发, 再发一次).
    var resendable: Bool {
        switch self {
        case .unsent, .declined: return true
        case .sending, .unsure, .unconfirmed: return false
        }
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

    // MARK: a message put into a running turn

    /// The chat's other messages in the same words as a message, as they stood when it was said:
    /// what Hermes may already have had that reads the same. A message put into a running turn
    /// (`session.steer`, `session.redirect`) has no receipt, so only a row of the transcript can
    /// say it got there, and it must not be one of these; nor does a page read in the chat's
    /// place stand for a message still on its way because one of these is on it.
    nonisolated struct Before: Equatable, Sendable {
        /// The transcript rows they are known to be stored as.
        var rows: Set<Int> = []
        /// How many more Hermes may have whose row is not known yet: their turn has not ended, or
        /// their own receipt is still out.
        var unstored = 0
    }

    /// The row a chat item stands for, where its id says (`row-<id>`: it was read from the transcript).
    static func row(of id: String) -> Int? {
        id.hasPrefix("row-") ? Int(id.dropFirst(4)) : nil
    }

    /// The rows of the transcript's newest page that a message put into a turn as the connection
    /// went may be stored as, oldest first: rows of yours in the same words that are neither a
    /// message the chat had in those words before it was sent (`before.rows`; the oldest of the
    /// rest are the ones whose row was not known then), nor a row another such message has been
    /// found in already (`taken`). None: the page does not show that it got there, and it stays
    /// in doubt. So an earlier message in the same words never passes for it, and a row confirms
    /// one message, not two.
    static func stored(_ text: String, before: Before, taken: Set<Int> = [], page: [StoredUserRow]) -> [StoredUserRow] {
        let other = page.filter { row in
            row.text == text && !(row.row.map { before.rows.contains($0) } ?? false)
        }
        return other.dropFirst(before.unstored).filter { row in
            !(row.row.map { taken.contains($0) } ?? false)
        }
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

/// A message of yours on a transcript page: its words, when it was stored, and as which row.
nonisolated struct StoredUserRow: Equatable, Sendable {
    var text: String
    var at: Date
    var row: Int? = nil
}
