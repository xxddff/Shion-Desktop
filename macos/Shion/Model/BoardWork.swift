import Foundation

/// The board as it concerns people, worked out from cards and their details: which cards an
/// assistant ran today (its 工作记录), which wait on your answer (等你确认), and which changes are
/// worth a notification. Foundation only, so it can be checked away from a Mac.
enum BoardWork {
    /// Hermes's BLOCK_RECURRENCE_LIMIT: a card that stops for the same kind again after an unblock,
    /// this many times in a row, goes to triage (`block_loop_detected`) instead of blocked.
    static let loopLimit = 2

    /// The blocks only you can clear: a decision or answer (needs_input), and a wall the assistant
    /// cannot take down itself (capability: an account, a credential, a step no agent can do).
    /// Hermes routes both "to blocked for a human". A transient block (a flaky site) needs only a
    /// retry, which 詩音 can do herself; a block that names no kind, or the failure breaker's, is
    /// the board's to show.
    static let yours: Set<String> = ["needs_input", "capability"]

    /// The start of the day `now` is in, on this Mac.
    static func today(_ now: Date) -> Date {
        Calendar.current.startOfDay(for: now)
    }

    /// A card the loop breaker moved to triage after it stopped on the same thing of yours again.
    static func looped(_ task: KanbanTask) -> Bool {
        task.status == "triage" && task.blockRecurrences >= loopLimit && yours.contains(task.blockKind ?? "")
    }

    /// Whether a card shows signs of having run since `start`: it is running or stopped, or it
    /// started, finished or sent a heartbeat since. Only these cards' runs are read for the logs.
    static func touched(_ task: KanbanTask, since start: Date) -> Bool {
        if ["running", "blocked", "review"].contains(task.status) || looped(task) { return true }
        return [task.startedAt, task.runStartedAt, task.completedAt, task.lastHeartbeatAt]
            .contains { ($0 ?? .distantPast) >= start }
    }

    /// The runs `profile` made on a card since `start` (still running, or ended since), oldest
    /// first. A run that took no time at all did not run: Hermes writes one down to keep a
    /// handoff made on a card nobody claimed. A run without a profile is the card's assignee's.
    static func runs(of detail: KanbanDetail, card: KanbanTask, by profile: String, since start: Date) -> [KanbanRun] {
        detail.runs.filter { run in
            guard (run.profile ?? card.assignee) == profile, let begin = run.startedAt else { return false }
            guard let end = run.endedAt else { return true }
            // Hermes keeps whole seconds
            return end >= start && (end.timeIntervalSince(begin) >= 1 || run.outcome == "spawn_failed")
        }
    }

    /// What a card waits on you for, when it does: blocked on something of yours, or moved to
    /// triage because it stopped on the same thing again after you let it go on. It takes the
    /// card's detail: the reason is only there, and the card's own `block_kind` may be left from
    /// an earlier block (the failure breaker blocks a card without changing it).
    static func ask(_ task: KanbanTask, detail: KanbanDetail?) -> CardAsk? {
        guard let detail else { return nil }
        switch task.status {
        case "blocked":
            guard let stop = detail.stop else {
                // a card with no stop recorded: its kind is all there is
                guard let kind = task.blockKind, yours.contains(kind) else { return nil }
                return CardAsk(kind: kind, reason: detail.blockReason, at: nil, again: false)
            }
            guard stop.event == "blocked", let kind = stop.blockKind, yours.contains(kind) else { return nil }
            return CardAsk(kind: kind, reason: stop.reason, at: stop.at, again: false)
        case "triage":
            guard looped(task), let stop = detail.stop, stop.event == "block_loop_detected" else { return nil }
            return CardAsk(kind: stop.blockKind ?? task.blockKind ?? "needs_input", reason: stop.reason, at: stop.at, again: true)
        default:
            return nil
        }
    }

    /// The moment a card is at, as a key: a change of key is a change worth looking at. A block's
    /// kind and count change with every new block that lands in blocked; review and done carry
    /// what was handed in, and when.
    static func momentKey(_ task: KanbanTask) -> String? {
        switch task.status {
        case "blocked":
            return "blocked|\(task.blockKind ?? "")|\(task.blockRecurrences)"
        case "triage" where looped(task):
            return "again|\(task.blockKind ?? "")|\(task.blockRecurrences)"
        case "review":
            return "review|\(task.latestSummary ?? "")"
        case "done":
            return "done|\(Int(task.completedAt?.timeIntervalSince1970 ?? 0))"
        default:
            return nil
        }
    }

    /// What to tell you about a card whose moment changed.
    static func news(_ task: KanbanTask, detail: KanbanDetail?) -> CardNews {
        switch task.status {
        case "blocked", "triage":
            // the reason, and whether the block is yours at all, are in the detail
            guard detail != nil else { return .wait }
            guard let ask = ask(task, detail: detail) else { return .none }
            return .tell(.ask, ask.reason)
        case "review":
            return .tell(.review, task.latestSummary)
        case "done":
            return .tell(.done, task.latestSummary ?? task.result)
        default:
            return .none
        }
    }

    /// The things about a card that its detail follows: when one of them changes, its detail is
    /// read again (the other boards have no event stream here).
    static func signature(_ task: KanbanTask) -> String {
        func stamp(_ date: Date?) -> String { date.map { String(Int($0.timeIntervalSince1970)) } ?? "" }
        return [task.status, task.blockKind ?? "", String(task.blockRecurrences), String(task.comments),
                task.latestSummary ?? "", stamp(task.runStartedAt), stamp(task.completedAt),
                stamp(task.lastHeartbeatAt), String(task.parents), String(task.children)]
            .joined(separator: "|")
    }
}

/// A card and the board it is on (nil: the server's current board).
struct CardRef: Hashable {
    let board: String?
    let id: String
}

/// Why a card waits on you.
struct CardAsk: Equatable {
    /// needs_input or capability.
    let kind: String
    let reason: String?
    /// When it stopped; nil until the card's detail is read.
    let at: Date?
    /// It stopped on the same thing again after you let it go on, and Hermes moved it to triage.
    let again: Bool

    /// Why it stopped, the way the board says it.
    var words: String {
        if again {
            return reason.map { "又卡在同一处：\($0)" } ?? "又卡在同一处了"
        }
        if kind == "capability" {
            return reason.map { "缺少能力：\($0)" } ?? "缺少它需要的能力"
        }
        return reason ?? "卡住了，等你"
    }
}

/// A card's change, for a notification: it waits on you, it is handed to you to check, it is done.
enum CardNews: Equatable {
    case tell(CardMoment.Kind, String?)
    /// Nothing to tell.
    case none
    /// The card's detail is needed first.
    case wait
}

/// What a notification about a card says, and where a click on it goes.
struct CardMoment: Equatable {
    enum Kind: Equatable {
        case ask, review, done
    }

    /// The card's board; nil for the server's current one.
    let board: String?
    let cardId: String
    let title: String
    let assignee: String?
    let kind: Kind
    /// The reason it stopped, or its handoff.
    let text: String?
}

/// A card on 「等你确认」: what it is, who stopped, why, and what was said since.
struct BoardAsk: Identifiable, Equatable {
    let board: String?
    let cardId: String
    let title: String
    let assignee: String?
    let ask: CardAsk
    /// The comments since it stopped: the assistant's own note, and your replies.
    var comments: [KanbanComment] = []

    var id: String { "\(board ?? "")/\(cardId)" }
}

/// A card in an assistant's 工作记录: today's runs of it by that assistant.
struct WorkLogEntry: Identifiable, Equatable {
    let board: String?
    let boardName: String?
    let cardId: String
    let title: String
    let assignee: String?
    /// The card's status now (a workflow column key).
    let status: String
    /// Oldest first.
    let runs: [KanbanRun]

    var id: String { "\(board ?? "")/\(cardId)" }

    /// When its latest run today began: the log's order, newest first.
    var latest: Date { runs.last?.startedAt ?? .distantPast }
}

extension KanbanRun {
    /// 09:12–09:40, or 10:33 开始 while it runs.
    var spanText: String {
        guard let start = startedAt else { return "" }
        guard let end = endedAt else { return "\(Fmt.hm(start)) 开始" }
        return "\(Fmt.hm(start))–\(Fmt.hm(end))"
    }

    /// How the run ended, in words.
    var outcomeText: String {
        switch outcome ?? "" {
        case "": return endedAt == nil ? "进行中" : "结束了"
        case "completed": return "做完了"
        case "blocked": return "停下来等你"
        case "crashed": return "中途出错"
        case "timed_out": return "超时了"
        case "reclaimed": return "收回了"
        case "gave_up": return "放弃了"
        case "spawn_failed": return "没能开始"
        case "review_requested", "review": return "交给你检查"
        case "changes_requested": return "要它再改"
        case let other: return other
        }
    }
}
