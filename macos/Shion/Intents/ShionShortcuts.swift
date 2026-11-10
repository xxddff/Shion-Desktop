import AppKit
import Foundation

/// What Shortcuts, Siri and Spotlight do in Shion (ShionIntents.swift), on the main window's own
/// store. Nothing goes out without a server Shion is signed in to and connected with; each action
/// says why instead. One that starts Shion waits for the connection the launch makes. 跟总秘书说
/// waits a few seconds for the reply and hands it back, and the reply's notification is left out
/// while it waits; a reply that comes later is notified as usual.
enum ShionShortcuts {
    private static weak var store: AppStore?
    /// 总秘书's id for each action waiting on a reply.
    private static var waiting: [String: Int] = [:]

    /// How long 跟总秘书说 waits for the reply. Test runs shorten it (`-ShionIntentReplyWait <seconds>`).
    static var replyWait: Duration {
        let asked = LaunchOptions.current.snapshot ? UserDefaults.standard.double(forKey: "ShionIntentReplyWait") : 0
        return asked > 0 ? .milliseconds(Int(asked * 1000)) : .seconds(10)
    }

    static func attach(_ store: AppStore) {
        self.store = store
    }

    /// An action is waiting for this assistant's reply: it shows it, so no notification.
    static func awaitsReply(from botId: String) -> Bool {
        (waiting[botId] ?? 0) > 0
    }

    // MARK: the connection

    /// The store once it is connected, its assistants are in and the window has left the last
    /// data for the server's (until then a send does nothing: `readOnly`); why not, otherwise.
    /// Signed in but still connecting (Shion was just started for this): waited for.
    static func connected(within timeout: Duration = .seconds(15)) async throws -> AppStore {
        guard let store else { throw ShortcutError.notReady }
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            guard store.canConnect(store.serverSettings) else { throw ShortcutError.notSignedIn }
            switch store.gateway.phase {
            case .online where store.live && !store.readOnly:
                return store
            case .failed(let reason):
                throw ShortcutError.offline(reason)
            case .offline where clock.now - start > .seconds(3):
                // not connecting at all: 断开 in Settings
                throw ShortcutError.notConnected
            default:
                break
            }
            guard clock.now - start < timeout else { throw ShortcutError.offline("连接超时") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: the actions

    /// 跟总秘书说: the sentence into 总秘书's Bot Chat, as the ⌥Space window sends it. Returns the
    /// reply when the turn ends within `replyWait`, nil when it went out and the reply is still to
    /// come.
    static func tell(_ text: String) async throws -> String? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw ShortcutError.nothingToSay }
        let store = try await connected()
        let chief = store.chiefId
        await store.openChief()
        if let error = store.chatErrors[chief] {
            throw ShortcutError.notSent(error)
        }
        let before = Set((store.chats[chief] ?? []).map(\.id))
        let sentAt = Date()
        waiting[chief, default: 0] += 1
        defer { waiting[chief] = max(0, (waiting[chief] ?? 1) - 1) }
        store.send(words, to: chief)
        guard store.chats[chief]?.contains(where: { $0.role == .user && $0.text == words && !before.contains($0.id) }) == true else {
            throw ShortcutError.notSent(store.chatErrors[chief] ?? "对话还没打开")
        }
        let clock = ContinuousClock()
        let deadline = clock.now + replyWait
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            let items = store.chats[chief] ?? []
            // the sentence's row: by its words, sent no earlier (a read of the chat renames rows)
            guard let index = items.lastIndex(where: { $0.role == .user && $0.text == words && $0.at >= sentAt.addingTimeInterval(-120) }) else {
                continue
            }
            let after = items[(index + 1)...]
            if let failed = after.first(where: { $0.role == .system && $0.text.hasPrefix("没发出去") }) {
                throw ShortcutError.notSent(String(failed.text.drop { $0 != "：" }.dropFirst()))
            }
            let replies = after.filter { $0.role == .assistant && !$0.streaming && !$0.text.isEmpty }
            if !replies.isEmpty && !store.replying.contains(chief) {
                return replies.map(\.text).joined(separator: "\n\n")
            }
        }
        return nil
    }

    /// 今天的待办: what 今天 and the menu bar list, from the server's shion plugin.
    static func todayTodos() async throws -> [Todo] {
        let store = try await connected()
        // the plugin's todos come right after the assistants
        let clock = ContinuousClock()
        let start = clock.now
        while !store.pluginData && clock.now - start < .seconds(5) {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard store.pluginData else { throw ShortcutError.noPlugin }
        return store.todayTodos
    }

    /// The assistants in Shion's sidebar: the server's, so none without one.
    static func assistants() async throws -> [Bot] {
        try await connected().bots
    }

    /// 打开助手: its chat in the main window.
    static func openAssistant(_ id: String) async throws {
        let store = try await connected()
        guard store.bots.contains(where: { $0.id == id }) else {
            throw ShortcutError.noAssistant(id)
        }
        store.route = .chat(id)
        MainWindow.show()
    }

    // MARK: as App Intents hand them over

    static func todayTodoEntities() async throws -> [TodoEntity] {
        let todos = try await todayTodos()
        return todos.map(todoEntity)
    }

    static func todoEntities(_ ids: [String]) async throws -> [TodoEntity] {
        let store = try await connected()
        return ids.compactMap { store.todo($0) }.map(todoEntity)
    }

    static func assistantEntities() async throws -> [AssistantEntity] {
        try await assistants().map(assistantEntity)
    }

    /// As ⌘K finds them: by name first, then by description or profile name.
    static func assistantEntities(matching words: String) async throws -> [AssistantEntity] {
        let bots = try await assistants()
        let query = JumpSearch.normalized(words)
        guard !query.isEmpty else { return bots.map(assistantEntity) }
        let ranked = bots.enumerated().compactMap { index, bot -> (rank: Int, index: Int, bot: Bot)? in
            let candidate = JumpCandidate(id: bot.id, group: .assistant, title: bot.name, keywords: [bot.id, bot.title])
            return JumpSearch.rank(candidate, query).map { ($0, index, bot) }
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map { assistantEntity($0.bot) }
    }

    private static func todoEntity(_ todo: Todo) -> TodoEntity {
        let now = store?.now ?? Date()
        let when = todo.dueAt.map { DueLabel(date: $0, now: now).text } ?? todo.doAt.map { Fmt.when($0, now: now) } ?? ""
        return TodoEntity(id: todo.id, title: todo.title, subtitle: when)
    }

    private static func assistantEntity(_ bot: Bot) -> AssistantEntity {
        AssistantEntity(id: bot.id, name: bot.name, title: bot.title)
    }

    /// 打开等你确认: opens whatever Shion shows there, connected or not.
    static func openConfirm() {
        store?.route = .confirm
        MainWindow.show()
    }
}

/// Why an action did nothing, in the words Shortcuts and Siri show.
nonisolated enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case notSignedIn
    case notConnected
    case offline(String)
    case notSent(String)
    case nothingToSay
    case noPlugin
    case noAssistant(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Shion 还没准备好，过一会儿再试。"
        case .notSignedIn: "Shion 还没登录服务器，什么都没发。在 Shion 的设置里登录后再试。"
        case .notConnected: "Shion 没有连着服务器，什么都没发。在 Shion 的设置里点「连接」后再试。"
        case .offline(let reason): "Shion 连不上服务器（\(reason)），什么都没发。"
        case .notSent(let reason): "没有发出去：\(reason)"
        case .nothingToSay: "没有要说的话。"
        case .noPlugin: "服务器上的总秘书没装 shion 插件，读不到待办。"
        case .noAssistant(let id): "Shion 里没有「\(id)」这个助手。"
        }
    }
}

/// What the last action said, for the test runs that call them (IntentHook.swift).
enum IntentOutcome {
    static var said = ""
    static var value: JSONValue = .null

    static func note(_ said: String, value: JSONValue = .null) {
        self.said = said
        self.value = value
    }
}
