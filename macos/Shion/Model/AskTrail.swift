import Foundation
import Observation

/// An approval or a question once you answered it: the line that stays in the chat (and the ⌥Space
/// window) where it was asked, 已允许这一次 or 你回答：中村老师. Hermes's transcript has no record
/// of it (its tool rows carry the call, not the result), so these are kept for this run only.
struct AnsweredAsk: Identifiable, Hashable {
    /// The ask's id (Hermes's `prompt_id`).
    let id: String
    let kind: AskKind
    let botId: String
    /// The server it was asked on (`ServerSettings.signInServer`): another one shows none of them.
    let server: String
    /// When it was asked: where its line goes among the chat's rows.
    let at: Date
    /// What was asked: the approval's title, or the question.
    let title: String
    /// What became of it.
    let outcome: String
}

/// What you answered since Shion started, newest last; in memory only.
@Observable
final class AskTrail {
    var answered: [AnsweredAsk] = []

    func answer(_ id: String) -> AnsweredAsk? {
        answered.first { $0.id == id }
    }
}
