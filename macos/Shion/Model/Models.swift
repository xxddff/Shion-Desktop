import SwiftUI

enum Area: String, CaseIterable {
    case study, work, life

    var label: String {
        switch self {
        case .study: return "学习"
        case .work: return "工作"
        case .life: return "生活"
        }
    }

    var color: Color {
        switch self {
        case .study: return Palette.hues[0]
        case .work: return Palette.hues[1]
        case .life: return Palette.hues[2]
        }
    }
}

enum BotStatus {
    case idle, working, waiting
}

/// 詩音 or one of her assistants: a Hermes profile with its own Bot Chat.
struct Bot: Identifiable, Hashable {
    let id: String
    let name: String
    let title: String
    let chief: Bool
    let hue: Color
    var status: BotStatus
    var statusNote: String

    var initial: String { String(name.prefix(1)) }
}

/// A todo keeps when to do it apart from when it is due.
struct Todo: Identifiable, Hashable {
    let id: String
    var title: String
    var area: Area
    var source: String
    var doAt: Date?
    var dueAt: Date?
    var done = false
    var nudges = 0
    /// Dates suggested by an assistant, not yet confirmed by you.
    var proposed = false
}

enum EventKind {
    case commute, lesson, focus, event
}

struct CalEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: EventKind
    let area: Area
    let start: Date
    let end: Date
    var place: String?
}

/// Kanban columns: queued (todo/ready), running, waiting on you (blocked/review), done.
enum CardStatus: CaseIterable {
    case queued, running, waiting, done

    var label: String {
        switch self {
        case .queued: return "排队"
        case .running: return "在做"
        case .waiting: return "等你"
        case .done: return "完成"
        }
    }
}

/// Work handed to an assistant on the Hermes kanban board.
struct Card: Identifiable, Hashable {
    let id: String
    let title: String
    let assignee: String
    var status: CardStatus
    /// What it is doing, waiting on, or delivered.
    var line: String
    var updatedAt: Date
}

enum AskKind {
    case approval, clarify, takeover
}

/// What answering an ask from the server needs: which session, which run of it.
struct RemotePrompt: Hashable {
    let sessionId: String
    let generation: Int
    let isClarify: Bool
}

struct AskOption: Identifiable, Hashable {
    let value: String
    let label: String
    var primary = false

    var id: String { value }
}

/// Something an assistant will not do without you: an approval, a question, or a takeover.
struct Ask: Identifiable, Hashable {
    let id: String
    let kind: AskKind
    let botId: String
    let at: Date
    let title: String
    var detail: String?
    var preview: String?
    var options: [AskOption]
    /// Set for approvals and questions that came from the Hermes server.
    var remote: RemotePrompt?
}

enum ChatRole {
    case user, assistant, system, card, tool
}

struct ChatItem: Identifiable, Hashable {
    var id: String
    let role: ChatRole
    let at: Date
    var text = ""
    var cardId: String?
    var todoIds: [String] = []
    /// An assistant reply still arriving.
    var streaming = false
}

enum ReportKind: String, CaseIterable, Identifiable {
    case study, work, life, news

    var id: String { rawValue }

    var label: String {
        switch self {
        case .study: return "学习"
        case .work: return "工作"
        case .life: return "生活"
        case .news: return "新闻"
        }
    }
}

struct ReportBlock: Hashable {
    let heading: String
    let items: [String]
}

struct Report: Identifiable, Hashable {
    let id: String
    let kind: ReportKind
    let botId: String
    let date: Date
    let headline: String
    let blocks: [ReportBlock]
}

/// The focus check: what you planned to be doing now, and whether the window in front matches.
struct FocusStatus: Hashable {
    var planTitle: String
    var plannedAt: Date
    var onTrack: Bool
}

/// An assistant's own desktop on the VPS (Hermes Bot Screen).
struct BotScreen: Hashable {
    let botId: String
    var running: Bool
    var activity: String
    var needsHuman = false
    var url = ""
}

/// How many board tasks the server runs at once: `kanban.max_in_progress` and
/// `kanban.max_in_progress_per_profile` from its config.yaml, read once when the gateway starts.
struct BoardLimits: Equatable {
    /// Across the whole server, every board; nil when unset.
    var maxInProgress: Int?
    /// Per assistant, counted on each board separately; nil when unset (no limit).
    var perAssistant: Int?
    /// The server's memory, which sets the default when `maxInProgress` is unset.
    var memoryMB: Int?

    /// What the dispatcher uses: the setting; unset, total memory ÷ 512 MB kept between 2 and 8;
    /// with the memory unknown (a server not on Linux), no limit.
    var effectiveMax: Int? {
        maxInProgress ?? memoryMB.map { min(8, max(2, $0 / 512)) }
    }

    var derivedFromMemory: Bool { maxInProgress == nil && memoryMB != nil }
}
