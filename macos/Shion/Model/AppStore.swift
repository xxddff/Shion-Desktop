import Observation
import SwiftUI

/// Everything the window shows. Demo data for now; the Canonical Gateway connection and the
/// `shion` plugin fill it later.
@Observable
final class AppStore {
    let now: Date
    var route: Route? = LaunchOptions.current.route
    var bots: [Bot]
    var todos: [Todo]
    var events: [CalEvent]
    var cards: [Card]
    var asks: [Ask]
    var chats: [String: [ChatItem]]
    var reports: [Report]
    var screens: [BotScreen]
    var activityLog = true
    var focusCheck = true

    init(now: Date) {
        let demo = DemoData(now: now)
        self.now = now
        bots = demo.bots
        todos = demo.todos
        events = demo.events
        cards = demo.cards
        asks = demo.asks
        chats = demo.chats
        reports = demo.reports
        screens = demo.screens
    }

    func bot(_ id: String) -> Bot? { bots.first { $0.id == id } }
    func card(_ id: String) -> Card? { cards.first { $0.id == id } }
    func todo(_ id: String) -> Todo? { todos.first { $0.id == id } }

    /// Open todos planned for or due today or earlier, soonest deadline first.
    var todayTodos: [Todo] {
        todos
            .filter { todo in
                guard !todo.done, !todo.proposed else { return false }
                let planned = todo.doAt.map { Fmt.dayDiff($0, now) <= 0 } ?? false
                let due = todo.dueAt.map { Fmt.dayDiff($0, now) <= 0 } ?? false
                return planned || due
            }
            .sorted { ($0.dueAt ?? $0.doAt ?? .distantFuture) < ($1.dueAt ?? $1.doAt ?? .distantFuture) }
    }

    func events(on day: Date) -> [CalEvent] {
        events.filter { Fmt.dayDiff($0.start, day) == 0 }.sorted { $0.start < $1.start }
    }

    func toggle(_ id: String) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].done.toggle()
        todos[index].proposed = false
    }

    func confirm(_ id: String) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].proposed = false
    }

    func addTodo(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todos.append(Todo(id: UUID().uuidString, title: trimmed, area: .life, source: "你自己加的", doAt: now))
    }

    func answer(_ ask: Ask, with option: AskOption) {
        asks.removeAll { $0.id == ask.id }
        chats[ask.botId, default: []].append(ChatItem(id: UUID().uuidString, role: .user, at: now, text: option.label))
        if ask.kind == .takeover && option.primary {
            route = .desktop
        }
    }

    func send(_ text: String, to botId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chats[botId, default: []].append(ChatItem(id: UUID().uuidString, role: .user, at: now, text: trimmed))
    }
}
