import AppKit
import KeyboardShortcuts
import Observation

/// The global shortcut (⌥Space unless changed in Settings) and the small window it brings up over
/// whatever app is in front (QuickAskPanel.swift): one sentence to 詩音, her reply streaming in
/// under it. The sentence goes into her Bot Chat like any other, so the whole conversation is a
/// click away. The shortcut is a preference, not a secret, so it lives in the defaults; screenshot
/// and test runs keep ⌥Space in memory and leave the defaults alone.
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
    /// What is being typed: it stays when the window goes away, and goes once it is sent.
    var draft = ""
    private(set) var shown = false
    /// How the window came up last: "hotkey", "menu" or "launch" (screenshots); the end-to-end
    /// test reads it to tell the global shortcut from the menu.
    private(set) var openedBy = ""
    /// The sentence this window sent last: what follows it in 詩音's chat is the answer.
    private(set) var asked: Asked?

    struct Asked: Equatable {
        /// The row it went in as; empty until it is in the chat.
        var itemId: String
        let text: String
        let at: Date
    }

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var window: QuickAskWindow?
    @ObservationIgnored private var listener: Task<Void, Never>?

    private static let defaultsKey = "QuickAskShortcut"

    private init() {
        shortcut = LaunchOptions.current.snapshot ? Self.defaultShortcut : Self.storedShortcut()
    }

    /// The store the window shows and sends through; set when the app starts.
    func attach(_ store: AppStore) {
        self.store = store
    }

    /// Once the app has launched: the shortcut goes live. Screenshots can ask for the window with
    /// a sentence and its answer already in it (`-ShionQuickDemo YES`).
    func launched() {
        listen()
        guard LaunchOptions.current.snapshot, UserDefaults.standard.bool(forKey: "ShionQuickDemo"), let store else { return }
        let demo = DemoData(now: store.demoClock).quickExchange
        store.chats[store.chiefId, default: []] += demo
        if let first = demo.first {
            asked = Asked(itemId: first.id, text: first.text, at: first.at)
        }
        show(by: "launch")
    }

    // MARK: the shortcut

    private static func storedShortcut() -> KeyboardShortcuts.Shortcut? {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: defaultsKey) == "none" { return nil }
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data)
        else { return defaultShortcut }
        return stored
    }

    private func save() {
        guard !LaunchOptions.current.snapshot else { return }
        let defaults = UserDefaults.standard
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: Self.defaultsKey)
        } else {
            defaults.set("none", forKey: Self.defaultsKey)
        }
    }

    /// Registers the shortcut with the system (a Carbon hot key, through KeyboardShortcuts): it
    /// works in every app, needs no permission, and is put back while Settings records a new one.
    private func listen() {
        listener?.cancel()
        listener = nil
        guard let shortcut, store != nil else { return }
        listener = Task { [weak self] in
            for await event in KeyboardShortcuts.events(for: shortcut) where event == .keyDown {
                self?.toggle()
            }
        }
    }

    // MARK: the window

    /// The shortcut: up when it is away, away when it has the keyboard, the keyboard back to it
    /// when it is up behind another app's window.
    func toggle() {
        if shown && window?.isKeyWindow == true {
            hide()
        } else {
            show(by: "hotkey")
        }
    }

    func show(by source: String = "menu") {
        guard let store else { return }
        openedBy = source
        let window = self.window ?? QuickAskWindow(store: store, quick: self)
        self.window = window
        if !shown {
            window.place()
        }
        shown = true
        // a panel that does not activate Shion: the app in front stays in front
        window.makeKeyAndOrderFront(nil)
        window.focusField()
        // 詩音's Bot Chat is attached by the time the sentence is typed
        Task { await store.openChief() }
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

    /// The window is up and shows what 詩音 says to it: her reply and her asks need no
    /// notification then.
    func showsAnswer(from botId: String) -> Bool {
        shown && asked != nil && botId == store?.chiefId
    }

    func send() {
        guard let store else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let chief = store.chiefId
        asked = Asked(itemId: "", text: text, at: Date())
        Task {
            await store.openChief()
            store.send(text, to: chief)
            // the chat's newest row from you, added as it went out
            if let item = store.chats[chief]?.last(where: { $0.role == .user && $0.text == text }), asked?.text == text {
                asked?.itemId = item.id
            }
        }
    }

    /// 詩音's whole chat in the main window.
    func openFullChat() {
        guard let store else { return }
        store.route = .chat(store.chiefId)
        hide()
        MainWindow.show()
    }

    /// 詩音's chat from the sentence on. Found by the row it went in as; once the chat has been
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
}
