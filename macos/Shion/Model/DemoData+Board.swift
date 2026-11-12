import Foundation

#if DEBUG

/// The demo day's board as 工作记录 and 待你处理 show it: who ran which card today, and the card
/// that stopped on your answer.
extension DemoData {
    /// Each demo card's runs, under its assignee's profile, oldest first.
    var runs: [String: [KanbanRun]] {
        func run(_ id: String, _ profile: String, _ start: Date, _ end: Date?, _ outcome: String?,
                 _ summary: String? = nil) -> KanbanRun {
            KanbanRun(id: id, profile: profile, outcome: outcome, startedAt: start, endedAt: end, summary: summary, error: nil)
        }
        return [
            "c7a1": [run("r1", "study", at(0, 10, 33), nil, nil)],
            "g5d2": [run("r2", "study", at(0, 10, 12), at(0, 10, 20), "blocked", "学校门户要两步验证码")],
            "h6a4": [run("r3", "study", at(0, 9, 5), at(0, 9, 24), "completed", "批改意见 5 条，放在 Notion「数据结构与算法」第6回下面")],
            "d6c3": [run("r4", "study", at(-1, 20, 40), at(-1, 21, 6), "completed", "12 张，放在 Notion「数据结构与算法」第6回下面")],
            "f1e0": [run("r5", "news", at(0, 8, 42), nil, nil)],
            "m2b1": [run("r6", "mail", at(0, 8, 41), at(0, 8, 44), "review_requested", "回复起草好了，待你处理后发出")],
        ]
    }

    /// The demo cards that stopped on you: why, and since when.
    var blocks: [String: CardAsk] {
        [
            "g5d2": CardAsk(kind: "needs_input", reason: "学校门户要两步验证码，发到你手机上了。告诉我验证码，我接着下载。",
                            at: at(0, 10, 20), again: false),
        ]
    }
}
#endif
