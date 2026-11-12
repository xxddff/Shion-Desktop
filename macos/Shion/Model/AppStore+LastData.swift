import AppKit
import Foundation
import Observation

/// The last real data from the server, kept on this Mac. Once Shion has connected, the window
/// never falls back to the demo: before connecting and while the connection is down it shows
/// this, read-only. Kept: the assistants, 今天's paragraph, the todos, the reports, the board's
/// cards and each chat's newest page, in ~/Library/Application Support/dev.shion.Shion/
/// last-data.json, readable only by you. No keys, tokens or passwords: those stay in the keychain.
/// Kept per server: another address shows the demo until it connects. Approvals and questions are
/// not kept, since they can only be answered live. Screenshot runs keep it in memory only.
@Observable
final class LastData {
    /// The window shows it: the assistants, chats, todos… are the kept ones.
    var shown = false
    /// When it was taken from the server.
    var savedAt: Date?
    @ObservationIgnored var file: LastDataFile?
    /// Connected and the first reads are in: from here on it may be saved.
    @ObservationIgnored var ready = false
    /// The connection was up at the last change: a drop saves at once.
    @ObservationIgnored var online = false
    @ObservationIgnored var saving: Task<Void, Never>?
    /// The page open when you disconnected, to stay on it.
    @ObservationIgnored var route: Route?

    /// A chat's newest page, as Shion pages a transcript.
    static let chatRows = 50

    nonisolated static var url: URL {
        URL.applicationSupportDirectory
            .appending(path: "dev.shion.Shion", directoryHint: .isDirectory)
            .appending(path: "last-data.json", directoryHint: .notDirectory)
    }
}

/// last-data.json. A part is nil when the server did not have it (no shion plugin: no todos,
/// paragraph or reports); the window then has nothing for it.
nonisolated struct LastDataFile: Codable, Sendable {
    var version = 1
    /// The server it came from (`https://host[/prefix]`).
    var server: String
    var savedAt: Date
    var bots: [StoredBot]?
    var chats: [String: [StoredItem]]?
    var todos: [StoredTodo]?
    var today: String?
    var reports: [StoredReport]?
    var cards: [StoredCard]?
    /// What each assistant's review kept (`review.summary`): no row of a transcript, so only here.
    var notes: [String: [StoredItem]]?
    /// The skills to look at, as the plugin last listed them.
    var skillReviews: [String: [SkillReview]]?
}

nonisolated struct StoredBot: Codable, Sendable {
    var id: String
    var name: String
    var title: String
    var chief: Bool
    /// Its place in Palette.hues; nil for 总秘书's accent.
    var hue: Int?
    /// Bot Mode's colour as it wrote it (`#rrggbb`, `hsl(…)`), when it set one: it wins over `hue`.
    var color: String?
    /// Bot Mode's avatar shape, and whether the profile has a picture (BotLook.swift).
    var shape: String?
    var picture: Bool?
}

nonisolated struct StoredItem: Codable, Sendable {
    var id: String
    var role: String
    var at: Date
    var text: String
    var event: ChatEvent?
    var cardId: String?
    var cardTitle: String?
    var cardAssignee: String?
    var stopped: Bool?
    var failure: TurnFailure?
    var midTurn: Bool?
}

nonisolated struct StoredTodo: Codable, Sendable {
    var id: String
    var title: String
    var area: String
    var source: String
    var doAt: Date?
    var dueAt: Date?
    var doAllDay: Bool?
    var dueAllDay: Bool?
    var done: Bool
    var nudges: Int
    var proposed: Bool
}

nonisolated struct StoredReport: Codable, Sendable {
    var id: String
    var kind: String
    var botId: String
    var date: Date
    var headline: String
    var blocks: [StoredBlock]
}

nonisolated struct StoredBlock: Codable, Sendable {
    var heading: String
    var items: [String]
}

nonisolated struct StoredCard: Codable, Sendable {
    var id: String
    var title: String
    var assignee: String
    /// Shion's column: queued, running, waiting (stuck), review or done.
    var status: String
    /// What it is doing, waiting on, or delivered, as the board said then.
    var line: String
    var updatedAt: Date
}

extension AppStore {
    /// Before connecting and while the connection is down, the window shows the last data, and what
    /// would change it (a todo ticked, a message sent, a card moved) waits for the server.
    var readOnly: Bool {
        lastData.shown || (live && gateway.phase != .online) || unconnected || Self.readOnlyDemo
    }

    /// Never connected to this server, and nothing kept from it: there is nothing to show, and
    /// the window says how to connect (RootView).
    var unconnected: Bool { !live && !lastData.shown && demo == nil }

    /// A screenshot run before it connects: the made-up day (Fixture.swift).
    var showsDemo: Bool { !live && !lastData.shown && demo != nil }

    /// The sidebar's line under the server: the data is the last the server gave, from then.
    var lastDataNote: String? {
        guard readOnly else { return nil }
        return "上次的数据 · \(Fmt.when(lastData.savedAt ?? Date(), now: Date()))"
    }

    // MARK: showing it

    /// At launch: the last data of the server in Settings, if any; then it follows the server's.
    func startLastData() {
        if !LaunchOptions.current.snapshot, let data = try? Data(contentsOf: LastData.url),
           let file = try? JSONDecoder().decode(LastDataFile.self, from: data) {
            lastData.file = file
            showLastData()
        }
        watchLastData()
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveLastData(now: true)
            }
        }
        // the failed turn's screenshot (DemoData+Failure.swift)
        if let demo, UserDefaults.standard.bool(forKey: "ShionFailureDemo") {
            chats[chiefId, default: []] += demo.failedTurn
        }
    }

    /// Shows the last data, if it is this server's. What the server did not have stays empty.
    func showLastData() {
        guard let file = lastData.file, file.server == serverSettings.trimmed.signInServer,
              let stored = file.bots, !stored.isEmpty
        else { return }
        bots = stored.map { $0.bot }
        let pages = file.chats ?? [:]
        chats = Dictionary(bots.map { bot in (bot.id, (pages[bot.id] ?? []).compactMap { $0.item }) },
                           uniquingKeysWith: { first, _ in first })
        asks = []
        todos = file.todos?.map { $0.todo } ?? demo?.todos ?? []
        reports = file.reports?.map { $0.report } ?? demo?.reports ?? []
        todaySummary = file.today
        cards = file.cards?.map { $0.card } ?? demo?.cards ?? []
        notes = (file.notes ?? [:]).mapValues { $0.compactMap(\.item) }
        skillReviews = file.skillReviews ?? [:]
        lastData.savedAt = file.savedAt
        lastData.shown = true
        if case .chat(let id)? = lastData.route, bot(id) != nil {
            route = lastData.route
        } else if case .chat(let id)? = route, bot(id) == nil {
            route = .today
        }
    }

    /// Connected, and the first reads are in: the window shows the server's data from now on, and
    /// the last data follows it. A part the server does not have goes back to the demo's.
    func settleLastData() {
        guard live else { return }
        if lastData.shown && !pluginData {
            todos = demo?.todos ?? []
            reports = demo?.reports ?? []
            todaySummary = nil
        }
        lastData.shown = false
        lastData.ready = true
        lastData.online = gateway.phase == .online
        saveLastData()
    }

    /// Before disconnecting: keeps what the server gave, so the window goes on showing it.
    func keepLastData() {
        saveLastData(now: true)
        lastData.ready = false
        lastData.saving?.cancel()
        lastData.route = route
    }

    /// Settings' 清除: the file goes, and the demo comes back while it was shown.
    func clearLastData() {
        lastData.file = nil
        lastData.savedAt = nil
        if !LaunchOptions.current.snapshot {
            try? FileManager.default.removeItem(at: LastData.url)
        }
        guard lastData.shown else { return }
        bots = demo?.bots ?? []
        chats = demo?.chats ?? [:]
        asks = demo?.asks ?? []
        todos = demo?.todos ?? []
        reports = demo?.reports ?? []
        todaySummary = nil
        cards = demo?.cards ?? []
        notes = [:]
        skillReviews = [:]
        lastData.shown = false
        if case .chat(let id)? = route, bot(id) == nil {
            route = .today
        }
    }

    // MARK: keeping it

    /// What the server gave: in memory at once, on disk soon after (never in screenshot runs).
    /// Only while connected and loaded; a part not loaded yet keeps what was kept before.
    func saveLastData(now: Bool = false) {
        guard live, lastData.ready else { return }
        let server = serverSettings.trimmed.signInServer
        let previous = lastData.file?.server == server ? lastData.file : nil
        var file = LastDataFile(server: server, savedAt: Date())
        file.bots = bots.map { bot in
            StoredBot(bot, color: roster.profiles.first { $0.name == bot.id }?.color)
        }
        var pages = previous?.chats ?? [:]
        for bot in bots {
            let items = (chats[bot.id] ?? []).filter { !$0.streaming }
            if !items.isEmpty {
                pages[bot.id] = items.suffix(LastData.chatRows).map { StoredItem($0) }
            }
        }
        file.chats = pages.filter { id, _ in bots.contains { $0.id == id } }
        file.notes = notes.filter { id, _ in bots.contains { $0.id == id } }.mapValues { $0.map { StoredItem($0) } }
        file.skillReviews = skillReviews.filter { id, _ in bots.contains { $0.id == id } }
        if pluginData {
            file.todos = todos.map { StoredTodo($0) }
            file.today = todaySummary
            file.reports = reports.map { StoredReport($0) }
        }
        file.cards = board.loaded ? liveCards : previous?.cards
        lastData.file = file
        lastData.savedAt = file.savedAt
        guard !LaunchOptions.current.snapshot, let data = try? JSONEncoder().encode(file) else { return }
        if now {
            Self.write(data)
        } else {
            Task.detached(priority: .utility) {
                Self.write(data)
            }
        }
    }

    /// Saves a few seconds after the server's data changes, and at once when the connection drops:
    /// the time on the sidebar is then when it went.
    private func watchLastData() {
        withObservationTracking {
            _ = bots
            _ = chats
            _ = notes
            _ = skillReviews
            _ = todos
            _ = reports
            _ = todaySummary
            _ = board.tasks
            _ = board.elsewhere
            _ = gateway.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.lastDataChanged()
                self?.watchLastData()
            }
        }
    }

    private func lastDataChanged() {
        guard live, lastData.ready else { return }
        lastData.saving?.cancel()
        guard gateway.phase == .online else {
            if lastData.online {
                lastData.online = false
                saveLastData()
            }
            return
        }
        lastData.online = true
        lastData.saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.saveLastData()
        }
    }

    /// Every board's cards, as 今天, the board page and the chats show them (BoardStore.swift's
    /// serverCards, with the line the board gave them then).
    private var liveCards: [StoredCard] {
        (board.tasks + board.elsewhere.values.joined()).map { task in
            StoredCard(
                id: task.id,
                title: task.title,
                assignee: task.assignee ?? "",
                status: StoredCard.key(CardStatus(key: task.status)),
                line: board.line(task, limits: boardLimits) { self.bot($0)?.name ?? $0 },
                updatedAt: task.runStartedAt ?? task.startedAt ?? task.createdAt ?? .distantPast
            )
        }
    }

    nonisolated private static func write(_ data: Data) {
        let url = LastData.url
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }
}

// MARK: - to and from the app's own types

extension StoredBot {
    /// `color`: Bot Mode's, from the bot's profile (Roster), kept only when Shion can read it.
    init(_ bot: Bot, color: String? = nil) {
        self.init(id: bot.id, name: bot.name, title: bot.title, chief: bot.chief,
                  hue: bot.chief ? nil : Palette.hues.firstIndex(of: bot.hue),
                  color: color.flatMap { BotLook.color($0) == nil ? nil : $0 },
                  shape: bot.shape, picture: bot.hasPicture ? true : nil)
    }

    var bot: Bot {
        Bot(id: id, name: name, title: title, chief: chief,
            hue: color.flatMap { BotLook.color($0) } ?? hue.map { Palette.hues[$0 % Palette.hues.count] } ?? Palette.accent,
            status: .idle, statusNote: "", shape: shape, hasPicture: picture ?? false)
    }
}

extension StoredItem {
    init(_ item: ChatItem) {
        let name = switch item.role {
        case .user: "user"
        case .assistant: "assistant"
        case .system: "system"
        case .card: "card"
        case .tool: "tool"
        }
        self.init(id: item.id, role: name, at: item.at, text: item.text, event: item.event, cardId: item.cardId,
                  cardTitle: item.cardTitle, cardAssignee: item.cardAssignee, stopped: item.stopped ? true : nil,
                  failure: item.failure, midTurn: item.midTurn ? true : nil)
    }

    var item: ChatItem? {
        let kind: ChatRole? = switch role {
        case "user": .user
        case "assistant": .assistant
        case "system": .system
        case "card": .card
        case "tool": .tool
        default: nil
        }
        guard let kind else { return nil }
        return ChatItem(id: id, role: kind, at: at, text: text, event: event, cardId: cardId, cardTitle: cardTitle,
                        cardAssignee: cardAssignee, stopped: stopped ?? false, failure: failure, midTurn: midTurn ?? false)
    }
}

extension StoredTodo {
    init(_ todo: Todo) {
        self.init(id: todo.id, title: todo.title, area: todo.area.rawValue, source: todo.source, doAt: todo.doAt,
                  dueAt: todo.dueAt, doAllDay: todo.doAllDay ? true : nil, dueAllDay: todo.dueAllDay ? true : nil,
                  done: todo.done, nudges: todo.nudges, proposed: todo.proposed)
    }

    var todo: Todo {
        Todo(id: id, title: title, area: Area(rawValue: area) ?? .life, source: source, doAt: doAt, dueAt: dueAt,
             doAllDay: doAllDay ?? false, dueAllDay: dueAllDay ?? false, done: done, nudges: nudges, proposed: proposed)
    }
}

extension StoredReport {
    init(_ report: Report) {
        self.init(id: report.id, kind: report.kind.rawValue, botId: report.botId, date: report.date,
                  headline: report.headline,
                  blocks: report.blocks.map { StoredBlock(heading: $0.heading, items: $0.items) })
    }

    var report: Report {
        Report(id: id, kind: ReportKind(rawValue: kind) ?? .life, botId: botId, date: date, headline: headline,
               blocks: blocks.map { ReportBlock(heading: $0.heading, items: $0.items) })
    }
}

extension StoredCard {
    static func key(_ status: CardStatus) -> String {
        switch status {
        case .queued: "queued"
        case .running: "running"
        // as files written before the columns were five have it
        case .stuck: "waiting"
        case .review: "review"
        case .done: "done"
        }
    }

    var card: Card {
        let column: CardStatus = switch status {
        case "running": .running
        case "waiting": .stuck
        case "review": .review
        case "done": .done
        default: .queued
        }
        return Card(id: id, title: title, assignee: assignee, status: column, line: line, updatedAt: updatedAt)
    }
}
