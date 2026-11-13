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
    /// Bot Mode's avatar shape, when it set one (BotLook.swift).
    var shape: String? = nil
    /// The profile has Bot Mode's avatar picture (AvatarPictures holds it once read).
    var hasPicture = false

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
    /// The date is a whole day, with no time of day: `doAt` / `dueAt` is then where that day
    /// starts on this Mac (Format.swift has what follows from it: labels, when it is overdue).
    var doAllDay = false
    var dueAllDay = false
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
    /// Its calendar's color, for this Mac's calendars (AppStore+Local.swift).
    var tint: Color?
    var allDay = false
}

/// Shion's five columns over Hermes's eight: queued (triage, todo, scheduled, ready), running,
/// stuck (blocked: on you, on something it lacks, or on an error), handed in for review (a
/// reviewing assistant picks it up; it does not wait on you), and done.
enum CardStatus: CaseIterable {
    case queued, running, stuck, review, done

    var label: String {
        switch self {
        case .queued: return "排队"
        case .running: return "在做"
        case .stuck: return "卡住"
        case .review: return "待验收"
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
    case approval, clarify, takeover, secret
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

/// What a card in a chat says happened, when it stands for an event rather than for a card made
/// on the board or for an ask (EventCards.swift). The event's words are the item's `text`.
nonisolated enum ChatEvent: Hashable, Codable, Sendable {
    /// The board's word on a card this chat made: done, stopped, given up, timed out.
    case board
    /// Another assistant wrote to this one; `from` is its name as Hermes signs the message, or, of
    /// its answer to a message this one sent it, its handle (Notices.peerAnswers).
    case received(from: String)
    /// This assistant wrote to another (the message_agent tool).
    case sent(to: String)
    /// Something that ran in the background ended, and Hermes told the assistant.
    case background
    /// What the assistant's own review after a turn kept, in its words (`review.summary`).
    case learned
    /// A skill it wrote or changed by itself, for you to look at: the review's id (SkillReviews.swift).
    case skill(String)

    /// Whether Hermes gave it to the assistant as a turn, in your name: such a card starts the
    /// turn that follows it, as a message of yours would.
    var startsTurn: Bool {
        switch self {
        case .board, .received, .background: return true
        case .sent, .learned, .skill: return false
        }
    }
}

struct ChatItem: Identifiable, Hashable {
    var id: String
    let role: ChatRole
    let at: Date
    var text = ""
    /// The event a card stands for, when it is one.
    var event: ChatEvent?
    var cardId: String?
    /// What was asked in this chat that its card or line stands for: a password or a key
    /// (SecretRequest.swift), or an answered approval or question (AskTrail.swift).
    var askId: String?
    /// A card made in the chat (kanban_create): what it was made with, to find it on the board
    /// when the transcript does not say its id.
    var cardTitle: String?
    var cardAssignee: String?
    var todoIds: [String] = []
    /// An assistant reply still arriving.
    var streaming = false
    /// The pictures and files you sent with the words (ChatMedia.swift).
    var media: [ChatMedia] = []
    /// A reply you stopped: what had come before the stop.
    var stopped = false
    /// A turn Hermes ended with an error: this line says why (TurnFailure.swift).
    var failure: TurnFailure?
    /// A message of yours that went into a turn already running (引导, 打断: Compose.swift): it
    /// started no turn of its own.
    var midTurn = false
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
