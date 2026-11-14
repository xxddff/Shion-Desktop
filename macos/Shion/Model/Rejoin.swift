import Foundation

/// A session attached again on a socket that does not have it: a new socket (the connection came
/// back), or this one once Hermes ended the session's subscription on it (`session.replay_gap`).
/// When Hermes refuses that `session.resume`, a Bot Chat (AppStore.rejoin) or a review's talk
/// (SkillReviewTalk.rejoin) keeps what it shows and says that it could not be attached again, and
/// why. The session's frames no longer come as they are published (a try replays what it missed),
/// so a turn is no longer shown as running on the word of the last ones. It is tried again by
/// itself a few times, a little later each time, as the official desktop app re-attaches a chat
/// whose resume failed (apps/desktop/src/app/session/hooks/use-resume-reattach.ts: four tries, one
/// to eight seconds apart), and by 再试一次 whenever you like; not by itself after a refusal that
/// trying again does not change (`lasting`). Foundation only, so it can be checked away from a Mac.
enum Rejoin {
    /// How many times a session that was refused is tried again by itself: 1, 2, 4 and 8 s after
    /// each refusal (Backoff).
    static let tries = 4

    /// A Bot Chat this socket could not attach again, as its chat says it (AppStore.rejoinNote).
    struct Refused {
        /// Why, in words (`words`).
        var why: String
        /// When it is tried again by itself; nil once it no longer is.
        var next: Date?
        /// A try is under way: one at a time.
        var trying = false
    }

    /// How long until a session is tried again by itself, after `refused` tries in a row were
    /// refused, the last with `error`. Nil once the tries are used up, or for a refusal that does
    /// not go away.
    static func delay(after refused: Int, _ error: Error) -> TimeInterval? {
        guard refused <= tries, !lasting(error) else { return nil }
        return Backoff.delay(afterFailures: refused)
    }

    /// A refusal that trying again does not change: the session is gone (`not_found`), this
    /// sign-in may not read it (`permission_denied`, `profile_mismatch`), or Hermes does not take
    /// the call as Shion makes it (`invalid_params`, `unknown_method`). Any other can go away: the
    /// store busy (`storage_unavailable`, which Hermes's clients retry: gateway/session_controls.py),
    /// the server going down for a restart (`runtime_draining`), no answer in time.
    static func lasting(_ error: Error) -> Bool {
        guard case GatewayError.rpc(_, let message, let reason) = error else { return false }
        return ["not_found", "permission_denied", "profile_mismatch", "invalid_params", "unknown_method"]
            .contains(reason ?? message)
    }

    /// Why, in words: Shion's where it has something to say, with Hermes's own reason after them;
    /// else Hermes's alone. What is not a refusal (no answer in time) as Shion says it.
    static func words(_ error: Error) -> String {
        guard case GatewayError.rpc(_, let message, let reason) = error else { return error.localizedDescription }
        let said = reason ?? message
        switch said {
        case "not_found": return "服务器上已经没有它了（\(said)）"
        case "permission_denied": return "服务器不让这个连接读它（\(said)）"
        case "storage_unavailable": return "服务器的存储暂时用不了（\(said)）"
        case "runtime_draining": return "服务器正在重启（\(said)）"
        default: return said
        }
    }

    /// The line that says it: what could not be attached again (`what`: 这个对话, 这个会话), why,
    /// and when it is tried again by itself, as the sidebar says when the connection is
    /// (AppStore.reconnectNote).
    static func line(_ what: String, _ why: String, next: Date?) -> String {
        let said = "没能重新接上\(what)：\(why)"
        guard let next else { return said }
        return "\(said) · \(clock.string(from: next)) 再试"
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
