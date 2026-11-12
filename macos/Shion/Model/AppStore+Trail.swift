import Foundation

/// What became of what assistants asked: once answered, an approval or a question leaves 待你处理
/// and leaves a line where it was asked, in the chat and in the ⌥Space window (已允许这一次, 你回答：
/// 中村老师); a password or a key keeps its card while it waits, then a line too (已提交, never what
/// was typed). Hermes's transcript records none of these (checked against hermes-agent b3746e35:
/// the transcript's tool rows carry the call and its arguments, not its result, and a sudo or
/// secret request is not stored at all), so the lines are kept in memory for this run: a chat read
/// again (a reconnect, reopening it) still shows them, a restart does not.
extension AppStore {
    /// From `answer`: what you chose or typed for one of the server's approvals or questions, as
    /// the line that stays. The demo's asks are answered in the chat itself.
    func keepAnswer(_ ask: Ask, with option: AskOption) {
        guard ask.remote != nil, ask.kind == .approval || ask.kind == .clarify else { return }
        let outcome = ask.kind == .approval
            ? Self.approvalOutcome(option)
            : (option.value.isEmpty ? "跳过了" : "你回答：\(option.label)")
        trail.answered.removeAll { $0.id == ask.id }
        trail.answered.append(AnsweredAsk(id: ask.id, kind: ask.kind, botId: ask.botId, server: serverKey,
                                          at: ask.at, title: ask.title, outcome: outcome))
    }

    /// An approval's answer in words, as Hermes names the choices.
    static func approvalOutcome(_ option: AskOption) -> String {
        switch option.value {
        case "once": return "已允许这一次"
        case "session": return "这次对话都允许"
        case "always": return "以后都允许"
        case "deny": return "已拒绝"
        default: return option.label
        }
    }

    /// A chat's rows with what was asked in it among them, each after what came before it: the
    /// card of a password or a key, or the line of what became of an ask. `open` false leaves out
    /// what still waits (the ⌥Space window answers it under the reply); `since` leaves out what was
    /// asked before then.
    func withAskCards(_ items: [ChatItem], of botId: String, open: Bool = true, since: Date? = nil) -> [ChatItem] {
        let server = serverKey
        var marks: [(id: String, at: Date)] = []
        for request in secrets.requests where request.botId == botId && (request.demo || request.server == server)
            && (open || !request.isOpen) {
            marks.append((request.id, request.at))
        }
        for answer in trail.answered where answer.botId == botId && answer.server == server {
            marks.append((answer.id, answer.at))
        }
        if let since {
            marks.removeAll { $0.at < since }
        }
        // a chat on its way in: its rows first, the cards and lines land among them
        guard !marks.isEmpty, !(items.isEmpty && openingChats.contains(botId)) else { return items }
        var merged = items
        for mark in marks.sorted(by: { $0.at < $1.at }) {
            let card = ChatItem(id: "ask-\(mark.id)", role: .card, at: mark.at, askId: mark.id)
            let index = merged.lastIndex { $0.at <= mark.at }.map { $0 + 1 } ?? 0
            merged.insert(card, at: index)
        }
        return merged
    }
}
