import AppIntents
import Foundation

// Shion's actions for Shortcuts, Spotlight and Siri (App Intents), with Chinese phrases for Siri
// (ShionAppShortcuts). Each runs on the app's own store through ShionShortcuts.swift; test runs
// call their perform() themselves (IntentHook.swift). Settings → 这台 Mac says what each does.
//
// The intents are not declared nonisolated (their @Parameter storage cannot be), so what the
// protocol reads without an actor is marked nonisolated: the title, description and modes, and
// init() (the system and the shortcuts below make them anywhere). perform() takes its isolation
// from the protocol, none, so it awaits the store's main-actor work.

/// 跟总秘书说: a sentence into 总秘书's Bot Chat, as the ⌥Space window sends it. The reply comes
/// back when it comes within a few seconds; otherwise the action says it went out, and the reply
/// arrives as it always does.
struct TellChiefIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "跟总秘书说"
    nonisolated static let description: IntentDescription? = IntentDescription("把一句话发给总秘书，和在 Shion 里说的一样。几秒内有回复，就把回复带回来；没有就回「已发出」，回复照常在通知和对话里。")
    nonisolated static let supportedModes: IntentModes = .background

    nonisolated init() {}

    @Parameter(title: "要说的话", requestValueDialog: IntentDialog("要跟总秘书说什么？"))
    var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let said = try await ShionShortcuts.tell(text)
        await IntentOutcome.note(said, value: .string(said))
        return .result(value: said, dialog: IntentDialog("\(said)"))
    }
}

/// 今天的待办: what 今天 and the menu bar list, planned for or due today or earlier.
struct TodayTodosIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "今天的待办"
    nonisolated static let description: IntentDescription? = IntentDescription("今天要做和今天到期的待办（还有逾期的），和 Shion 的「今天」页一样。")
    nonisolated static let supportedModes: IntentModes = .background

    nonisolated init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<[TodoEntity]> & ProvidesDialog {
        let todos = try await ShionShortcuts.todayTodoEntities()
        let said: String
        if todos.isEmpty {
            said = "今天没有要做的了。"
        } else {
            let listed = todos.prefix(5).map { $0.subtitle.isEmpty ? $0.title : "\($0.title)（\($0.subtitle)）" }
            said = "今天还有 \(todos.count) 件：" + listed.joined(separator: "；") + (todos.count > 5 ? "……" : "。")
        }
        await IntentOutcome.note(said, value: .array(todos.map { .string($0.title) }))
        return .result(value: todos, dialog: IntentDialog("\(said)"))
    }
}

/// 打开助手: an assistant found by name, its chat opened in the main window. A plain AppIntent:
/// OpenIntent's `target` is a synchronous requirement, which a main-actor property cannot answer.
struct OpenAssistantIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "打开助手"
    nonisolated static let description: IntentDescription? = IntentDescription("按名字在 Shion 的助手里找一个，打开它的对话。")
    nonisolated static let supportedModes: IntentModes = .foreground

    nonisolated init() {}

    @Parameter(title: "助手", requestValueDialog: IntentDialog("打开哪个助手？"))
    var assistant: AssistantEntity

    func perform() async throws -> some IntentResult {
        try await ShionShortcuts.openAssistant(assistant.id)
        await IntentOutcome.note("打开了\(assistant.name)", value: .string(assistant.id))
        return .result()
    }
}

/// 打开待你处理: the page with everything waiting on you.
struct OpenConfirmIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "打开待你处理"
    nonisolated static let description: IntentDescription? = IntentDescription("打开 Shion 的「待你处理」：助手要你批准或回答的，和停下来等你的卡片。")
    nonisolated static let supportedModes: IntentModes = .foreground

    nonisolated init() {}

    func perform() async throws -> some IntentResult {
        await ShionShortcuts.openConfirm()
        await IntentOutcome.note("打开了待你处理")
        return .result()
    }
}

// MARK: - what the actions take and give

/// An assistant: a profile on the server, as Shion's sidebar names it.
nonisolated struct AssistantEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "助手")
    static let defaultQuery = AssistantQuery()

    let id: String
    let name: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(title)")
    }
}

/// The assistants of the server Shion is connected to, found by name, description or profile
/// as ⌘K finds them; none (and why) when it is not connected.
nonisolated struct AssistantQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AssistantEntity] {
        try await ShionShortcuts.assistantEntities().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [AssistantEntity] {
        try await ShionShortcuts.assistantEntities(matching: string)
    }

    func suggestedEntities() async throws -> [AssistantEntity] {
        try await ShionShortcuts.assistantEntities()
    }
}

/// A todo from the server's shion plugin.
nonisolated struct TodoEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "待办")
    static let defaultQuery = TodoQuery()

    let id: String
    let title: String
    /// When it is due, or else when it is planned for, in words (「18:00 截止」).
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        subtitle.isEmpty
            ? DisplayRepresentation(title: "\(title)")
            : DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
}

nonisolated struct TodoQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [TodoEntity] {
        try await ShionShortcuts.todoEntities(identifiers)
    }

    func suggestedEntities() async throws -> [TodoEntity] {
        try await ShionShortcuts.todayTodoEntities()
    }
}

/// The phrases Siri knows Shion's actions by, in Chinese; Shortcuts and Spotlight list the same
/// four. Each phrase names the app (`applicationName`); 打开助手 asks which assistant next (a
/// phrase with the assistant in it would need a key path to the intent's main-actor parameter).
nonisolated struct ShionAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TellChiefIntent(),
            phrases: [
                "用\(.applicationName)跟总秘书说",
                "让\(.applicationName)转告总秘书",
                "\(.applicationName)跟总秘书说一声",
            ],
            shortTitle: "跟总秘书说",
            systemImageName: "bubble.left"
        )
        AppShortcut(
            intent: TodayTodosIntent(),
            phrases: [
                "\(.applicationName)今天的待办",
                "用\(.applicationName)看今天的待办",
                "\(.applicationName)今天还有什么要做",
            ],
            shortTitle: "今天的待办",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: OpenAssistantIntent(),
            phrases: [
                "用\(.applicationName)打开助手",
                "在\(.applicationName)里打开助手",
            ],
            shortTitle: "打开助手",
            systemImageName: "person.crop.circle"
        )
        AppShortcut(
            intent: OpenConfirmIntent(),
            phrases: [
                "用\(.applicationName)打开待你处理",
                "用\(.applicationName)打开等你确认",
                "\(.applicationName)有什么等我确认",
            ],
            shortTitle: "待你处理",
            systemImageName: "hand.raised"
        )
    }
}
