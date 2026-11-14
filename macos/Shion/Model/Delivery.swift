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

    /// The rows of a transcript page that name the submission they were stored for, by that
    /// submission (Hermes keeps a prompt's `submission_id` on its row: display_metadata). Such a
    /// row is that prompt and no other message: one in the same words is not it.
    static func named(in page: JSONValue) -> [String: Int] {
        var named: [String: Int] = [:]
        for row in page["rows"]?.array ?? [] {
            if let submission = row["display_metadata"]?["submission_id"]?.string, let number = row["row_id"]?.int {
                named[submission] = number
            }
        }
        return named
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
        /// The ones of them read from the transcript, by their time and words: compacted since,
        /// the session may have them under other numbers (StoredUserRow.Identity).
        var identities: Set<StoredUserRow.Identity> = []
        /// The others, by their chat item's id: Hermes had them, or might have, as a row not
        /// known then (their turn had not ended, or their own receipt was still out). What became
        /// of each is asked when the transcript is looked at (AppStore.others): by then its row
        /// may be known, or it may be known never to have got there. A count taken once stayed
        /// one too many when such a message was then refused, and the message it was counted for
        /// could stay in doubt for good with its row in the transcript.
        var others: Set<String> = []
        /// For a message put into a running turn: the admission that run is, by its submission id,
        /// as Hermes said of that run (ChatControl.began). Hermes stores the message after that
        /// admission's row (AppStore.began). Nil when that is not known; never the last item before
        /// it that starts a turn, which may be a prompt waiting behind the run, stored after it.
        var turn: String?
    }

    /// What is known of the other messages in a message's words at the moment the transcript is
    /// looked at for it: which rows are theirs, and how many of them Hermes may have as a row
    /// nobody can name yet.
    nonisolated struct Others: Equatable, Sendable {
        /// Rows that are other messages', by number: the ones it had before it (Before.rows), and
        /// those of messages whose row has become known since. Hermes gives no number twice.
        var rows: Set<Int> = []
        /// Rows that are other messages', by their time and words, which a row keeps when a
        /// compaction stores it again under a new number: the ones it had read before it
        /// (Before.identities), and those that have confirmed another message put into a turn.
        var identities: Set<StoredUserRow.Identity> = []
        /// Said before it, and Hermes may have them: of the rows in its words that are nobody's,
        /// the oldest are theirs.
        var earlier = 0
        /// Said after it while it was still in doubt, and Hermes may have them: the newest such
        /// rows are theirs.
        var later = 0
        /// Hermes's time of the row that began the turn it was said in: a row stored then or
        /// before is another message's, whatever its number and whether it names anything. A
        /// compaction Hermes runs by itself stores the messages it keeps again under new numbers,
        /// at their own time and naming no submission, so a message known by its number alone
        /// is a row nobody can name after it, in the same words; its time stays the old one.
        var since: Date?
    }

    /// The row a chat item stands for, where its id says (`row-<id>`: it was read from the transcript).
    static func row(of id: String) -> Int? {
        id.hasPrefix("row-") ? Int(id.dropFirst(4)) : nil
    }

    /// The row of the transcript's newest page (oldest first) that a message is stored as, when
    /// the page shows it got there: a row of yours in its words that is no other message's.
    /// The rows in its words that are known to be others' are left out, by number or by their
    /// time and words (`others`: under the new number a compaction gave it, such a row is
    /// still known), and so are the rows stored before the turn it was said in began
    /// (`others.since`); of the rest, as many as other messages may account for are theirs
    /// (`earlier` of the oldest, `later` of the newest), and only one beyond those is this
    /// message's: the one after the earlier ones. Nil: the page does not show that it got there,
    /// and it stays in doubt. So a message in the same words, said before or after, never passes
    /// for it, and a row confirms one message, not two.
    static func stored(_ text: String, others: Others, page: [StoredUserRow]) -> StoredUserRow? {
        let free = page.filter { row in
            row.text == text && !(row.row.map { others.rows.contains($0) } ?? false)
                && !others.identities.contains(row.identity) && !(others.since.map { row.at <= $0 } ?? false)
        }
        return free.count > others.earlier + others.later ? free[others.earlier] : nil
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

    /// Which row it is from one read of the transcript to the next: its words, and when Hermes
    /// stored it (the row's own `timestamp`, not this Mac's clock). A number names one row for
    /// good, Hermes never gives it twice, but not one message: a compaction stores the messages
    /// it keeps again, in place or in a new session, each under a new number and with everything
    /// else of its original, its time and words too (by which, with its role, Hermes's own
    /// display shows a message's copies once).
    var identity: Identity { Identity(text: text, at: at) }

    nonisolated struct Identity: Hashable, Sendable {
        var text: String
        var at: Date
    }
}
