import AppKit
import KeyboardShortcuts
import Observation

/// The global shortcut (⌥Space unless changed in Settings) and the small window it brings up over
/// whatever app is in front (QuickAskPanel.swift): one sentence to 总秘书, the reply streaming in
/// under it. The sentence goes into 总秘书's Bot Chat like any other, so the whole conversation is a
/// click away; sent while no server is connected, it waits and goes out once one is.
///
/// The shortcut is a preference, not a secret, so it lives in the defaults; screenshot and test
/// runs keep ⌥Space in memory and leave the defaults alone, and only register it with the system
/// when the run asks for it (`-ShionHotKey YES`), so a screenshot run does not hold the key.
@Observable
final class QuickAsk {
    static let shared = QuickAsk()

    /// ⌥Space: Spotlight has ⌘Space, the input sources ⌃Space and ⌃⌥Space.
    static let defaultShortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])

    /// nil once cleared in Settings: no global shortcut then.
    var shortcut: KeyboardShortcuts.Shortcut? {
        didSet {
            guard shortcut != oldValue else { return }
            save()
            listen()
        }
    }
    /// Whether the system took the shortcut; Settings says so when another app holds it.
    private(set) var hotKeyState: GlobalHotKey.State = .off
    /// What is being typed: it stays when the window goes away, and goes once it is sent.
    var draft = ""
    private(set) var shown = false
    /// The sentence this window sent last: what follows it in the chat is the answer.
    private(set) var asked: Asked?
    /// Sentences sent while no server was connected, oldest first: they go out, together, as soon
    /// as one is, and are kept across launches until then.
    private(set) var waiting: [QuickAskWaiting] = []

    struct Asked: Equatable {
        /// The row it went in as; empty until it is in the chat.
        var itemId: String
        let text: String
        let at: Date
    }

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var window: QuickAskWindow?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Settings is recording a new shortcut: the old one is let go meanwhile, so it can be pressed
    /// into the recorder like any other.
    @ObservationIgnored private var recording = false

    private static let shortcutKey = "QuickAskShortcut"
    private static let waitingKey = "QuickAskWaiting"

    private init() {
        let snapshot = LaunchOptions.current.snapshot
        shortcut = snapshot ? Self.defaultShortcut : Self.storedShortcut()
        waiting = snapshot ? [] : Self.storedWaiting()
    }

    /// The store the window shows and sends through; set when the app starts.
    func attach(_ store: AppStore) {
        self.store = store
    }

    /// Once the app has launched: the shortcut goes live, and waiting sentences go out whenever a
    /// server is connected. Screenshots can ask for the window with a sentence and its answer
    /// already in it (`-ShionQuickDemo YES`).
    func launched() {
        hotKey = GlobalHotKey { [weak self] in
            self?.toggle()
        }
        let center = NotificationCenter.default
        // KeyboardShortcuts' recorder says when it starts and stops recording (its own name for
        // the notification, in the 3.1 line this project pins)
        observers.append(center.addObserver(
            forName: Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange"), object: nil, queue: .main
        ) { [weak self] note in
            let active = note.userInfo?["isActive"] as? Bool ?? false
            MainActor.assumeIsolated {
                self?.recording = active
                self?.listen()
            }
        })
        // another app may have let the shortcut go meanwhile
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryHotKey()
            }
        })
        listen()
        watchConnection()
        guard LaunchOptions.current.snapshot, UserDefaults.standard.bool(forKey: "ShionQuickDemo"), let store else { return }
        let demo = DemoData(now: store.demoClock).quickExchange
        store.chats[store.chiefId, default: []] += demo
        if let first = demo.first {
            asked = Asked(itemId: first.id, text: first.text, at: first.at)
        }
        show()
    }

    // MARK: the shortcut

    private static func storedShortcut() -> KeyboardShortcuts.Shortcut? {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: shortcutKey) == "none" { return nil }
        guard let data = defaults.data(forKey: shortcutKey),
              let stored = try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data)
        else { return defaultShortcut }
        return stored
    }

    private func save() {
        guard !LaunchOptions.current.snapshot else { return }
        let defaults = UserDefaults.standard
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: Self.shortcutKey)
        } else {
            defaults.set("none", forKey: Self.shortcutKey)
        }
    }

    /// Screenshot runs leave the key alone; a test that presses it asks for it.
    private static var registersHotKey: Bool {
        !LaunchOptions.current.snapshot || UserDefaults.standard.bool(forKey: "ShionHotKey")
    }

    /// Registers the shortcut with the system (GlobalHotKey.swift): it works in every app and
    /// needs no permission.
    private func listen() {
        guard let hotKey else { return }
        if let shortcut, store != nil, Self.registersHotKey, !recording {
            hotKeyState = hotKey.register(keyCode: shortcut.carbonKeyCode, modifiers: shortcut.carbonModifiers)
        } else {
            hotKey.unregister()
            hotKeyState = hotKey.state
        }
    }

    /// Tries the shortcut again where the system refused it: when Shion comes to the front, when
    /// the 快捷键 tab opens, or from its button.
    func retryHotKey() {
        guard hotKeyState != .registered, hotKeyState != .off else { return }
        listen()
    }

    // MARK: the window

    /// The shortcut: up when it is away, away when it has the keyboard, the keyboard back to it
    /// when it is up behind another app's window.
    func toggle() {
        if shown && window?.isKeyWindow == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let store else { return }
        let window = self.window ?? QuickAskWindow(store: store, quick: self)
        self.window = window
        // named for whoever is 总秘书 now
        window.title = "跟\(store.chiefName)说"
        if !shown {
            window.place()
        }
        shown = true
        // a panel that does not activate Shion: the app in front stays in front
        window.makeKeyAndOrderFront(nil)
        window.focusField()
        // 总秘书's Bot Chat is attached by the time the sentence is typed; what still waits (the
        // chat would not open last time) goes now
        if Self.connected(store) {
            Task {
                await store.openChief()
                sendWaiting()
            }
        }
    }

    func hide() {
        guard shown else { return }
        shown = false
        window?.orderOut(nil)
        // a sentence still waiting for its answer comes back with the window; an answered one goes
        if let store, !store.live || answered(in: store) {
            asked = nil
        }
    }

    /// The window is up and shows what 总秘书 says to it: the reply and the asks need no
    /// notification then.
    func showsAnswer(from botId: String) -> Bool {
        shown && asked != nil && botId == store?.chiefId
    }

    /// Return in the field: the answer to the question 总秘书 is waiting on, or a new sentence.
    func send() {
        guard let store else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if let question = question(in: store) {
            store.answer(question, with: AskOption(value: text, label: text))
            return
        }
        // behind anything still waiting, and out with it when a server is connected
        waiting.append(QuickAskWaiting(id: UUID().uuidString, text: text, at: Date()))
        saveWaiting()
        sendWaiting()
    }

    /// 总秘书's whole chat in the main window.
    func openFullChat() {
        guard let store else { return }
        store.route = .chat(store.chiefId)
        hide()
        MainWindow.show()
    }

    /// The question 总秘书 asked in this exchange that wants words, not a choice: the field
    /// answers it.
    func question(in store: AppStore) -> Ask? {
        asks(in: store).first { $0.kind == .clarify && $0.options.allSatisfy { $0.value.isEmpty } }
    }

    /// What 总秘书 asks in this exchange, approvals and questions, oldest first.
    func asks(in store: AppStore) -> [Ask] {
        guard store.live, let since = asked?.at else { return [] }
        return store.asks.filter { $0.botId == store.chiefId && $0.at >= since }.reversed()
    }

    /// 总秘书's chat from the sentence on. Found by the row it went in as; once the chat has been
    /// read again (a reconnect gives the row the server's id), by its words, sent no earlier.
    func exchange(in store: AppStore) -> [ChatItem] {
        guard let asked else { return [] }
        let items = store.chats[store.chiefId] ?? []
        let since = asked.at.addingTimeInterval(-120)
        let start = items.lastIndex { !asked.itemId.isEmpty && $0.id == asked.itemId }
            ?? items.lastIndex { $0.role == .user && $0.text == asked.text && $0.at >= since }
        guard let start else {
            // on its way into the chat
            return [ChatItem(id: "quick-asked", role: .user, at: asked.at, text: asked.text)]
        }
        return Array(items[start...])
    }

    /// The turn is over and something came after the sentence: a reply, a card, a note.
    private func answered(in store: AppStore) -> Bool {
        !store.replying.contains(store.chiefId) && exchange(in: store).count > 1
    }

    // MARK: sending, now or once connected

    private static func connected(_ store: AppStore) -> Bool {
        store.live && store.gateway.phase == .online
    }

    /// Into 总秘书's Bot Chat as one message, a line each: a second message during the answer to
    /// the first would cut that answer short (Hermes's `display.busy_input_mode` is `interrupt`
    /// unless the server says otherwise). The window shows the exchange from it. Should the chat
    /// not open, they wait again; the reason shows under the field.
    private func deliver(_ sentences: [QuickAskWaiting], to store: AppStore) {
        let text = sentences.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return }
        let chief = store.chiefId
        asked = Asked(itemId: "", text: text, at: Date())
        Task {
            await store.openChief()
            let before = store.chats[chief]?.count ?? 0
            if Self.connected(store), store.chiefId == chief {
                store.send(text, to: chief)
            }
            // the chat's row from you, added as it went out
            let rows = store.chats[chief] ?? []
            guard rows.count > before, let row = rows.last, row.role == .user, row.text == text else {
                waiting = sentences + waiting
                saveWaiting()
                if asked?.text == text {
                    asked = nil
                }
                return
            }
            if asked?.text == text {
                asked?.itemId = row.id
            }
        }
    }

    /// What waits, once a server is connected.
    private func sendWaiting() {
        guard let store, Self.connected(store), !waiting.isEmpty else { return }
        let sentences = waiting
        waiting = []
        saveWaiting()
        deliver(sentences, to: store)
    }

    /// Follows the connection: when it comes up, what waits goes out.
    private func watchConnection() {
        guard let store else { return }
        withObservationTracking {
            _ = store.live
            _ = store.gateway.phase
        } onChange: { [weak self] in
            // called before the change lands: look once it has
            Task { @MainActor in
                self?.sendWaiting()
                self?.watchConnection()
            }
        }
        sendWaiting()
    }

    private static func storedWaiting() -> [QuickAskWaiting] {
        guard let data = UserDefaults.standard.data(forKey: waitingKey),
              let stored = try? JSONDecoder().decode([QuickAskWaiting].self, from: data)
        else { return [] }
        return stored
    }

    private func saveWaiting() {
        guard !LaunchOptions.current.snapshot else { return }
        if waiting.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.waitingKey)
        } else if let data = try? JSONEncoder().encode(waiting) {
            UserDefaults.standard.set(data, forKey: Self.waitingKey)
        }
    }
}

/// A sentence for 总秘书 from the window that has not gone out yet.
nonisolated struct QuickAskWaiting: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    let at: Date
}
