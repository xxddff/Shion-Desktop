import Foundation

/// Where a message you sent is on its way to the server. None: Hermes has it.
nonisolated enum Delivery: Equatable, Sendable {
    /// Sent: no receipt yet.
    case sending
    /// The connection went before the receipt came: once it is back, the server says (DeliveryCheck).
    case unsure
    /// Put into a running turn (引导, 打断) and no answer came: the connection went first. It may
    /// have reached the assistant or not, and nothing later says which: a correction is no
    /// submission, so nothing Hermes publishes names it, and no row of the transcript is taken for
    /// it (Hermes's own clients look in none either). It stays so under its bubble, a relaunch
    /// included (Deliveries.kept), until 再发一次 sends it as a message of its own behind the
    /// running turn, which says it twice if the first one did get there, or 不发了 takes it out of
    /// the chat (AppStore.giveUp), as 重试 does with the turn it was put into. It is not sent again
    /// by itself.
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
        case .unsent, .declined, .unconfirmed: return true
        case .sending, .unsure: return false
        }
    }

    /// What the line under a message put into a running turn says when no answer came
    /// (`unconfirmed`), and what 再发一次 and 不发了 under it say they do. Hermes's answer is the
    /// only word there is on such a message: without it, it may have got there or not, for good.
    static let unansweredNote = "没等到回音，送没送到不知道，以后也不会知道；再发一次可能会说两遍"
    static func unansweredResend(to assistant: String) -> String {
        "作为新的一句发给\(assistant)，排在这一轮后面；要是刚才那句其实送到了，这句话就说了两遍"
    }
    static let unansweredGiveUp = "把这句话从对话里拿掉，不再发；要是它其实送到了，对话记录里的那一条还在"
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
    /// row is that prompt and no other message: one in the same words is not it. Where two do, the
    /// newer: a compaction's copy is a row of a higher number than the one it copied (Hermes never
    /// gives a number twice), wherever the page shows it.
    static func named(in page: JSONValue) -> [String: Int] {
        var named: [String: Int] = [:]
        for row in page["rows"]?.array ?? [] {
            if let submission = submission(of: row), let number = row["row_id"]?.int {
                named[submission] = max(number, named[submission] ?? number)
            }
        }
        return named
    }

    /// The submission a transcript row was stored for, where it names one: a prompt someone's
    /// client sent (prompt.submit), as Hermes keeps the client's `submission_id` on its row
    /// (display_metadata, from the admission it ran: gateway/session_display.py
    /// `submission_turn_scope`), whatever its words. Nothing Hermes writes itself names one: not a
    /// notice it gives the assistant, nor what was put into a running turn (macos/ci/real, stages
    /// copies and explicit). Its own compaction's copies name none either, but the prompt of the
    /// turn it compacted in (stages auto and long).
    static func submission(of row: JSONValue) -> String? {
        guard let submission = row["display_metadata"]?["submission_id"]?.string, !submission.isEmpty else { return nil }
        return submission
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

    /// The row a chat item stands for, where its id says (`row-<id>`: it was read from the transcript).
    static func row(of id: String) -> Int? {
        id.hasPrefix("row-") ? Int(id.dropFirst(4)) : nil
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
