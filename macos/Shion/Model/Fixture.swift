import Foundation

/// The made-up day that screenshots and UI tests run on in place of a server (DemoData.swift).
/// It is in debug builds only, and shown only when one is started with `-ShionSnapshot YES`: the
/// app you install is built without it (the DemoData files compile for DEBUG alone, and so does
/// the launch option), so every `demo?.…` in the code finds nothing there.
protocol Fixture {
    var bots: [Bot] { get }
    var todos: [Todo] { get }
    var events: [CalEvent] { get }
    var cards: [Card] { get }
    var asks: [Ask] { get }
    var chats: [String: [ChatItem]] { get }
    var reports: [Report] { get }
    var screens: [BotScreen] { get }
    /// The board's side of the demo cards (DemoData+Board.swift).
    var runs: [String: [KanbanRun]] { get }
    var blocks: [String: CardAsk] { get }
    /// Pictures of single states, each asked for by its own launch option.
    var failedTurn: [ChatItem] { get }
    var quickExchange: [ChatItem] { get }
    var reconnectChat: [ChatItem] { get }
    var reconnectUnsent: String { get }
    var reconnectWaiting: [(text: String, at: Date)] { get }
    var secretChatBot: String { get }
    var secretChat: [ChatItem] { get }
    var secretRequests: [SecretRequest] { get }
    func answeredAsks(server: String) -> [AnsweredAsk]
}

extension AppStore {
    /// The fixture of a screenshot run; nil in the app you use.
    var demo: (any Fixture)? {
        Self.fixture(now: demoClock)
    }

    static func fixture(now: Date) -> (any Fixture)? {
        #if DEBUG
        return LaunchOptions.current.snapshot ? DemoData(now: now) : nil
        #else
        return nil
        #endif
    }
}
