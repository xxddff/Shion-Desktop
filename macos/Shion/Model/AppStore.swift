import AppKit
import Observation
import SwiftUI

/// Everything the window shows: the assistants and their Bot Chats from the Hermes server, today,
/// todos and reports from its `shion` plugin, the calendar from this Mac. Before it has connected
/// there is nothing to show but the way to connect (RootView), or the last data it had
/// (AppStore+LastData.swift). Screenshot and test runs start on a made-up day instead (Fixture.swift).
@Observable
final class AppStore {
    /// `now` is the real time, ticking every 30 seconds. A screenshot run's made-up day is pinned
    /// at `demoClock` until the server's own data, the last of it, or this Mac's calendars show.
    let demoClock: Date
    var now: Date { demo == nil || pluginData || lastData.shown || local.realTime ? local.clock : demoClock }
    /// This Mac's calendars, the focus check and the app usage record (AppStore+Local.swift).
    let local = LocalData.forLaunch()
    var route: Route? = LaunchOptions.current.route
    var bots: [Bot]
    var todos: [Todo]
    var events: [CalEvent]
    var cards: [Card]
    var asks: [Ask]
    var chats: [String: [ChatItem]]
    var reports: [Report]
    /// What is typed and not sent, and the message it answers, by chat (AppStore+Compose.swift).
    var drafts: [String: String] = [:]
    var replies: [String: ReplyTarget] = [:]
    /// How a message sent during a turn reaches the assistant (Compose.swift).
    var busyMode = BusyMode.saved {
        didSet { busyMode.save() }
    }
    /// Cards of a chat that are not rows of its transcript: what the assistant's review after a
    /// turn kept, as it came (AppStore+Events.swift).
    var notes: [String: [ChatItem]] = [:]
    /// The skills each assistant wrote by itself, to look at (AppStore+SkillReviews.swift).
    var skillReviews: [String: [SkillReview]] = [:]
    var reviewing: SkillReviewTalk?
    var screens: [BotScreen]

    // the Hermes server
    let gateway = Gateway()
    /// Passwords and keys assistants ask for (AppStore+Secrets.swift); what was asked, never the answer.
    let secrets = Secrets()
    /// What you answered, the line that stays where it was asked (AppStore+Trail.swift).
    let trail = AskTrail()
    // screenshot runs never touch the keychain (a locked one would put up a password prompt)
    var serverSettings = LaunchOptions.current.snapshot ? AppStore.snapshotSettings : ServerSettings.load()
    /// The browser sign-in, when that is how Shion logs in.
    let account = LaunchOptions.current.snapshot
        ? Account(persist: false, tokens: AppStore.snapshotSignIn)
        : Account(persist: true)
    /// Assistants and Bot Chats come from the server.
    private(set) var live = false
    /// Bot ids whose Bot Chat is being opened, and why one could not be.
    private(set) var openingChats: Set<String> = []
    private(set) var chatErrors: [String: String] = [:]
    /// bot id → the cursor of its next older transcript page; absent once the oldest is shown
    private(set) var olderPages: [String: String] = [:]
    /// bot ids whose older page is on its way, and why one did not come
    private(set) var loadingOlder: Set<String> = []
    private(set) var olderErrors: [String: String] = [:]
    /// Bot ids whose turn is under way, from its first event to message.complete: until then the
    /// turn's latest tool calls show one by one, after it they fold into a line (ChatLines.swift).
    private(set) var replying: Set<String> = []
    /// The server's board limits, read after connecting.
    private(set) var boardLimits: BoardLimits?
    /// The server's kanban board, live while connected.
    let board = BoardStore()
    /// The server's profiles, and who leads and who is hidden on this Mac (AppStore+Bots.swift).
    let roster = Roster(persist: !LaunchOptions.current.snapshot)
    /// The chats' pictures and files (AppStore+Media.swift).
    let media = MediaStore()
    /// Stopping and retrying turns (AppStore+Control.swift).
    let control = ChatControl()
    /// The server's data as it last was, for when it cannot be reached (AppStore+LastData.swift).
    let lastData = LastData()
    /// Messages sent that the server has not said it has (AppStore+Reconnect.swift).
    let deliveries = Deliveries()
    /// What `runtime.describe` says the server can do (`session-transcript-v1`, …).
    @ObservationIgnored var serverCapabilities: Set<String> = []
    /// What each session's frames last said that a snapshot says too, and where in its stream: a
    /// snapshot older than that is not put over it (SessionWords, `resumed`).
    @ObservationIgnored var words = SessionWords()
    /// session id → when the `session.resume` whose snapshot is being attached was asked for. A
    /// password or key Hermes asked for after that is no frame and has no place in the stream:
    /// it is newer than the snapshot may be, and is not closed for being left out of it
    /// (AppStore+Secrets.swift resumeSecrets).
    @ObservationIgnored var resumeAsked: [String: Date] = [:]
    /// Today, todos and reports come from the server's `shion` plugin (AppStore+Plugin.swift).
    var pluginData = false
    /// 詩音's paragraph at the top of 今天, from the plugin.
    var todaySummary: String?
    @ObservationIgnored var pluginRevision = 0
    @ObservationIgnored var pluginRefresh: Task<Void, Never>?
    @ObservationIgnored var demoTodos: [Todo] = []
    @ObservationIgnored var demoReports: [Report] = []
    /// bot id → how many of its rows came before the attach that is waiting for its first page
    @ObservationIgnored var attachMarks: [String: Int] = [:]
    /// A kanban_create call shown as a card, waiting for its result to say the card's id:
    /// tool id → (bot id, chat row id).
    @ObservationIgnored private var madeCards: [String: (botId: String, itemId: String)] = [:]
    /// Bot ids whose rows are loaded: chats opened on this connection. The other Bot Chats are
    /// attached only for their approvals, questions and busy state.
    @ObservationIgnored private(set) var loadedChats: Set<String> = []
    @ObservationIgnored private var demoBots: [Bot] = []
    @ObservationIgnored private var demoChats: [String: [ChatItem]] = [:]
    @ObservationIgnored private var demoAsks: [Ask] = []
    /// bot id → its Bot Chat's session id, and back
    @ObservationIgnored private(set) var sessions: [String: String] = [:]
    @ObservationIgnored private(set) var sessionBots: [String: String] = [:]
    /// bot id → the assistant message being streamed
    @ObservationIgnored var streaming: [String: String] = [:]

    init(now: Date) {
        let demo = Self.fixture(now: now)
        self.demoClock = now
        bots = demo?.bots ?? []
        todos = demo?.todos ?? []
        events = demo?.events ?? []
        cards = demo?.cards ?? []
        asks = demo?.asks ?? []
        chats = demo?.chats ?? [:]
        reports = demo?.reports ?? []
        screens = demo?.screens ?? []
        gateway.onEvent = { [weak self] type, sessionId, payload in
            self?.apply(type, sessionId: sessionId, payload: payload)
        }
        startSecrets()
        gateway.onReconnect = { [weak self] in
            self?.reattach()
        }
        gateway.credential = { [weak self] settings, renew in
            guard let self else { throw GatewayError.offline }
            return try await self.credential(for: settings, renew: renew)
        }
        gateway.onFrame = { [weak self] params in
            self?.words.note(params)
            self?.noteFences(params)
            self?.noteDelivery(params)
        }
        startLastData()
        // screenshot and test runs post nothing and ask for no permission: Notifier sees to that
        Notifier.shared.start(self)
        if canConnect(serverSettings) && !LaunchOptions.current.snapshot {
            Task { await connect() }
        }
        startLocal()
    }

    /// An assistant by id; one hidden in Settings too, for the name on what it left behind.
    func bot(_ id: String) -> Bot? { bots.first { $0.id == id } ?? roster.hiddenBots.first { $0.id == id } }
    func card(_ id: String) -> Card? { cards.first { $0.id == id } }
    func todo(_ id: String) -> Todo? { todos.first { $0.id == id } }

    /// 詩音's id: the profile named `shion`, or whichever assistant leads.
    var chiefId: String { bots.first { $0.chief }?.id ?? "shion" }

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

    /// Events on that day, including ones that began the day before and run into it.
    func events(on day: Date) -> [CalEvent] {
        let start = Fmt.calendar.startOfDay(for: day)
        let end = Fmt.calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return events
            .filter { $0.start < end && ($0.end > start || $0.start >= start) }
            .sorted { $0.start < $1.start }
    }

    /// The session id of an assistant's Bot Chat, once this connection is attached to it.
    func botChatSession(_ botId: String) -> String? {
        sessions[botId]
    }

    /// The next thing on today's calendar that is not a commute.
    var nextEvent: CalEvent? {
        events(on: now).first { $0.start > now && $0.kind != .commute }
    }

    func toggle(_ id: String) {
        guard !readOnly else { return }
        if pluginData { return pluginToggle(id) }
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].done.toggle()
        todos[index].proposed = false
    }

    func confirm(_ id: String) {
        guard !readOnly else { return }
        if pluginData { return pluginConfirm(id) }
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].proposed = false
    }

    func addTodo(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !readOnly else { return }
        if pluginData { return pluginAdd(trimmed) }
        todos.append(Todo(id: UUID().uuidString, title: trimmed, area: .life, source: "你自己加的",
                          doAt: Fmt.calendar.startOfDay(for: now), doAllDay: true))
    }

    func answer(_ ask: Ask, with option: AskOption) {
        guard !readOnly else { return }
        asks.removeAll { $0.id == ask.id }
        Notifier.shared.withdraw(ask.id)
        keepAnswer(ask, with: option)
        if let remote = ask.remote {
            respond(to: ask, remote: remote, with: option)
            return
        }
        chats[ask.botId, default: []].append(ChatItem(id: UUID().uuidString, role: .user, at: now, text: option.label))
        if ask.kind == .takeover && option.primary {
            route = .desktop
        }
    }

    /// Says `text` in a Bot Chat. `mode` is how it reaches an assistant in the middle of a turn:
    /// only a chat's composer passes the way chosen for that (AppStore.sendMessage). Everything
    /// else (the ⌥Space window, a shortcut, 今天's field, a notification's reply) waits for the
    /// turn to end and starts its own, where its answer is looked for.
    func send(_ text: String, to botId: String, mode: BusyMode = .queue) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // not connected: it waits, with the ⌥Space window's sentences, and goes out once connected
        if waits(botId) {
            return QuickAsk.shared.wait(trimmed, for: botId)
        }
        guard !readOnly else { return }
        guard live else {
            chats[botId, default: []].append(ChatItem(id: UUID().uuidString, role: .user, at: now, text: trimmed))
            return
        }
        guard let sessionId = sessions[botId] else {
            chatErrors[botId] = "对话还没打开"
            return
        }
        // with its receipt, or checked once the connection is back (AppStore+Reconnect.swift)
        say(trimmed, to: botId, sessionId: sessionId, mode: mode)
    }
}

// MARK: - the Hermes server

extension AppStore {
    /// Whether these settings have what a dial needs: an address, and a session token or a
    /// sign-in for that address.
    func canConnect(_ settings: ServerSettings) -> Bool {
        let settings = settings.trimmed
        guard settings.isConfigured else { return false }
        switch settings.login {
        case .sessionToken: return true
        case .browser: return account.tokens(for: settings) != nil
        }
    }

    /// Saves the settings and connects; on success the assistants come from the server.
    func connect() async {
        keepSettings()
        await gateway.connect(serverSettings)
        guard gateway.phase == .online else { return }
        await describeRuntime()
        await loadProfiles()
        await loadPluginData()
        await loadAllSkillReviews()
        await loadBoardLimits()
        board.start(serverSettings, credential: gateway.credential, author: signedInName)
        settleLastData()
        // the plugin wakes the 总秘书 chosen on this Mac (AppStore+Local.swift)
        await local.syncChief()
        await attachAll()
        await loadAttachedChats()
    }

    /// Attaches every assistant's existing Bot Chat, without its rows, so approvals, questions and
    /// busy states come from all of them, not only from the chats you open. A Bot Chat is only
    /// created when you open the chat. Needs the paged transcript (an attach without rows).
    func attachAll() async {
        guard pagesTranscripts else { return }
        for bot in bots where sessions[bot.id] == nil {
            guard live, gateway.phase == .online else { return }
            guard let id = try? await findBotChat(bot.id), sessions[bot.id] == nil,
                  let snapshot = try? await resumed(bot.id, id),
                  sessions[bot.id] == nil  // opened meanwhile
            else { continue }
            attach(bot.id, snapshot: snapshot)
        }
    }

    /// The assistant's Bot Chat: the session titled "Bot Chat" in its profile, if there is one.
    private func findBotChat(_ botId: String) async throws -> String? {
        let listed = try await gateway.call("session.list", [
            "profile": .string(botId), "title": "Bot Chat", "limit": 200, "include_hidden": true,
        ])
        let row = (listed["sessions"]?.array ?? []).first(where: { candidate in
            let root = candidate["root_title"]?.string
            return root == "Bot Chat" || (root == nil && candidate["title"]?.string == "Bot Chat")
        })
        return row.flatMap { $0["resolved_id"]?.string ?? $0["id"]?.string ?? $0["session_id"]?.string }
    }

    /// `GET /api/config` (the configured values) and the server's memory (`/api/status`), which
    /// sets the default when the overall limit is unset.
    private func loadBoardLimits() async {
        guard let config = try? await gateway.rest("/api/config") else {
            boardLimits = nil
            return
        }
        // as the dispatcher reads them: anything but a positive whole number counts as unset
        func positive(_ value: JSONValue?) -> Int? {
            value?.int.flatMap { $0 >= 1 ? $0 : nil }
        }
        let status = try? await serverSettings.status()
        boardLimits = BoardLimits(
            maxInProgress: positive(config["kanban"]?["max_in_progress"]),
            perAssistant: positive(config["kanban"]?["max_in_progress_per_profile"]),
            memoryMB: status?.memoryMB
        )
    }

    /// One transcript page: rows counted on the server before projection, so a page of tool
    /// calls shows fewer lines.
    static let pageSize = 50

    /// The transcript is paged where the server has `session.transcript`; older servers send it whole.
    var pagesTranscripts: Bool { serverCapabilities.contains("session-transcript-v1") }

    private func describeRuntime() async {
        guard let reply = try? await gateway.call("runtime.describe", [:]) else { return }
        serverCapabilities = Set((reply["capabilities"]?.array ?? []).compactMap { $0.string })
    }

    /// Saves the settings, signs in through the server's login page, then connects.
    func signIn() async {
        keepSettings()
        guard await account.signIn(serverSettings) else { return }
        await connect()
    }

    func signOut() {
        account.signOut()
        if serverSettings.login == .browser {
            disconnect()
        }
    }

    func disconnect() {
        keepLastData()
        gateway.disconnect()
        leaveLive()
        showLastData()
    }

    /// An assistant Shion stops following (hidden in Settings, or deleted): its Bot Chat's events,
    /// approvals and questions no longer come in, and what it had in 待你处理 goes.
    func forgetChat(_ botId: String) {
        if let sessionId = sessions.removeValue(forKey: botId) {
            sessionBots[sessionId] = nil
        }
        streaming[botId] = nil
        attachMarks[botId] = nil
        loadedChats.remove(botId)
        olderPages[botId] = nil
        olderErrors[botId] = nil
        chats[botId] = nil
        replying.remove(botId)
        deliveries.forget(botId)
        for ask in asks where ask.botId == botId {
            Notifier.shared.withdraw(ask.id)
        }
        asks.removeAll { $0.botId == botId }
        forgetSecrets(botId)
    }

    /// Screenshot and test runs keep what they type in memory: no keychain, no preferences.
    private func keepSettings() {
        serverSettings = serverSettings.trimmed
        if !LaunchOptions.current.snapshot {
            serverSettings.save()
        }
    }

    /// The name you signed in with in the browser (Hermes's `user_id`: the user name, for a user
    /// name and password); a session token has none.
    private var signedInName: String? {
        guard serverSettings.login == .browser,
              let name = account.tokens(for: serverSettings)?.userId, !name.isEmpty
        else { return nil }
        return name
    }

    private func credential(for settings: ServerSettings, renew: Bool) async throws -> Credential {
        switch settings.login {
        case .sessionToken:
            return .sessionToken(settings.token)
        case .browser:
            return .bearer(try await account.accessToken(for: settings, renew: renew))
        }
    }

    /// Screenshot runs: no server, unless `-ShionDemoSignIn YES` asks to show a signed-in account.
    static var snapshotSettings: ServerSettings {
        LaunchOptions.current.demoSignIn ? ServerSettings(address: "hermes.example.dev") : ServerSettings()
    }

    static var snapshotSignIn: SignInTokens? {
        guard LaunchOptions.current.demoSignIn else { return nil }
        return SignInTokens(
            server: "https://hermes.example.dev", accessToken: "demo", refreshToken: "demo",
            expiresAt: 0, provider: "basic", userId: "kaede"
        )
    }

    private func loadProfiles() async {
        do {
            let result = try await gateway.call("profiles.list", [:])
            let rows = result["profiles"]?.array ?? []
            guard !rows.isEmpty else { return }
            enterLive(with: rows)
        } catch {
            chatErrors["*"] = error.localizedDescription
        }
    }

    /// One assistant per profile, named as Bot Mode names it (its ui_meta title, then the profile's
    /// display name); 总秘书 leads, and the ones hidden in Settings are left out (AppStore+Bots.swift).
    private func enterLive(with rows: [JSONValue]) {
        if !live {
            demoBots = bots
            demoChats = chats
            demoAsks = asks
        }
        bots = assistants(from: rows)
        chats = [:]
        asks = []
        sessions = [:]
        sessionBots = [:]
        streaming = [:]
        chatErrors = [:]
        resetPages()
        live = true
        if case .chat(let id)? = route, bot(id) == nil {
            route = .today
        }
    }

    private func leaveLive() {
        boardLimits = nil
        stopPluginData()
        board.stop()
        guard live else { return }
        live = false
        bots = demoBots
        chats = demoChats
        asks = demoAsks
        // another server's, for all this knows: the last data brings back what is this one's
        notes = [:]
        skillReviews = [:]
        reviewing = nil
        sessions = [:]
        sessionBots = [:]
        streaming = [:]
        chatErrors = [:]
        resetPages()
        if case .chat(let id)? = route, bot(id) == nil {
            route = .today
        }
    }

    private func resetPages() {
        olderPages = [:]
        loadingOlder = []
        olderErrors = [:]
        attachMarks = [:]
        loadedChats = []
        replying = []
        Notifier.shared.withdrawAll()
        endSecrets()
    }

    /// Finds the assistant's Bot Chat (the session titled "Bot Chat" in its profile), creates it
    /// when there is none, and attaches this connection to it.
    func openChat(_ botId: String) async {
        guard live, gateway.phase == .online, !loadedChats.contains(botId), !openingChats.contains(botId) else { return }
        openingChats.insert(botId)
        defer { openingChats.remove(botId) }
        chatErrors[botId] = nil
        do {
            if sessions[botId] != nil {
                // attached in the background: only the rows are missing
                try await loadLatestPage(botId)
            } else {
                let snapshot: JSONValue
                if let id = try await findBotChat(botId) {
                    snapshot = try await resumed(botId, id)
                } else {
                    snapshot = try await gateway.call("session.create", createParams(botId))
                }
                attach(botId, snapshot: snapshot)
                if snapshot["messages_omitted"]?.bool == true {
                    try await loadLatestPage(botId)
                }
            }
            loadedChats.insert(botId)
        } catch {
            chatErrors[botId] = error.localizedDescription
        }
    }

    /// A new Bot Chat. `source` is the interface the assistant is told it talks through, fixed for
    /// the session's life: `gui` reads as the desktop app (`cli`, the default, as a terminal). Where
    /// the server takes it, `client` names Shion; a label for viewers, it changes nothing else.
    private func createParams(_ botId: String) -> JSONValue {
        var fields: [String: JSONValue] = [
            "profile": .string(botId), "title": "Bot Chat", "hidden": true, "follow_profile_config": true,
            "request_id": .string(UUID().uuidString), "source": "gui",
        ]
        if serverCapabilities.contains("session-client-v1") {
            let info = Bundle.main.infoDictionary ?? [:]
            let version = "\(info["CFBundleShortVersionString"] as? String ?? "0")+\(info["CFBundleVersion"] as? String ?? "0")"
            fields["client"] = ["name": "shion", "version": .string(version)]
        }
        return .object(fields)
    }

    /// With paging, the resume only attaches (`omit_messages`) and the rows come a page at a time;
    /// otherwise it carries the whole transcript, projected for display.
    func resumeParams(_ botId: String, _ sessionId: String) -> JSONValue {
        pagesTranscripts
            ? ["profile": .string(botId), "session_id": .string(sessionId), "omit_messages": true]
            : ["profile": .string(botId), "session_id": .string(sessionId), "display_projection": true]
    }

    /// `session.resume` for a Bot Chat. Hermes reads the session with this socket already on its
    /// stream and answers a moment later, so frames can come before a snapshot that is older than
    /// they are (a turn that ends in that moment: its end is here, the snapshot still says it
    /// runs and still lists what it asked). Such a snapshot is not the session as it is: it is
    /// asked for again, a few times at most, and what the frames said since stands over whatever
    /// it then still says otherwise (SessionWords.current): whether a turn runs, and what waits
    /// for an answer of yours. So however often it comes back older than the frames, an ask a
    /// frame brought is not dropped and one a frame settled does not come back. The moment the
    /// answer's own call went out is kept for what is not a frame (`resumeAsked`).
    func resumed(_ botId: String, _ sessionId: String) async throws -> JSONValue {
        var asked = Date()
        var snapshot = try await gateway.call("session.resume", resumeParams(botId, sessionId))
        var again = 0
        while again < SessionWords.rereads, words.outdate(snapshot) {
            again += 1
            asked = Date()
            snapshot = try await gateway.call("session.resume", resumeParams(botId, sessionId))
        }
        resumeAsked[sessionId] = asked
        return words.current(snapshot)
    }

    /// Whether a turn runs in the session a snapshot is of: the newest word there is, a frame's
    /// taken since the snapshot was read before the snapshot's own.
    func runs(_ snapshot: JSONValue) -> Bool {
        words.running(after: snapshot) ?? snapshot["running"]?.bool ?? false
    }

    func attach(_ botId: String, snapshot: JSONValue) {
        guard let sessionId = snapshot["session_id"]?.string else { return }
        noteFences(snapshot)
        sessions[botId] = sessionId
        sessionBots[sessionId] = botId
        streaming[botId] = nil
        if snapshot["messages_omitted"]?.bool == true {
            // the rows held now stay up until the latest page replaces them; anything that
            // streams in meanwhile lands after this mark and is kept
            attachMarks[botId] = chats[botId]?.count ?? 0
        } else {
            let rows = snapshot["display_messages"]?.array ?? snapshot["messages"]?.array ?? []
            chats[botId] = uniqued(rows.flatMap(chatItems(from:)))
            olderPages[botId] = nil
        }
        setRunning(botId, runs(snapshot))
        setReplying(botId, runs(snapshot))
        for prompt in snapshot["prompts"]?.array ?? [] {
            addPrompt(prompt, sessionId: sessionId, botId: botId)
        }
        resumeSecrets(botId, sessionId: sessionId, snapshot: snapshot)
    }

    /// The newest page of a resumed transcript (`session.transcript`, latest first), in place of
    /// whatever was held, keeping what streamed in since the attach, and any message of yours
    /// Hermes has not said it has unless a row of the page can be it (`onPage`).
    func loadLatestPage(_ botId: String) async throws {
        guard let sessionId = sessions[botId] else { return }
        let page = try await gateway.call("session.transcript", [
            "profile": .string(botId), "session_id": .string(sessionId),
            "order": "latest", "limit": .number(Double(Self.pageSize)),
        ])
        guard sessions[botId] == sessionId else { return }
        let rows = transcriptItems(page)
        let held = chats[botId] ?? []
        let mark = min(attachMarks.removeValue(forKey: botId) ?? 0, held.count)
        // a turn that finished between the attach and this read is in both: keep the page's copy
        let recent = rows.suffix(8)
        // a message of yours still on its way, in doubt or not sent: not what an older row in
        // the same words stands for (AppStore+Reconnect.swift)
        let own = onPage(held, page: page, rows: rows, botId: botId)
        // nor a card put in from the newest rows meanwhile (followNotices), which the page has under the same id
        let streamed = held[mark...].filter { item in
            if item.streaming { return true }
            if let there = own[item.id] { return !there }
            // a notice's card that came as a frame: its row, anywhere on the page, is the card (NoticeCards.swift)
            if NoticeCards.stage(of: item.id) != nil,
               rows.contains(where: { $0.role == .card && $0.event == item.event && $0.text == item.text }) {
                return false
            }
            return !(recent.contains { $0.role == item.role && $0.text == item.text } || rows.contains { $0.id == item.id })
        }
        // one said before the attach is not on the page either: it stays, ahead of what came since
        let waiting = held[..<mark].filter { own[$0.id] == false }
        chats[botId] = rows + uniqued(waiting + streamed, besides: rows)
        olderPages[botId] = page["next_cursor"]?.string
        olderErrors[botId] = nil
    }

    /// The next older page, above what is shown. Called as the transcript's top comes into view.
    func loadOlder(_ botId: String) async {
        guard live, let cursor = olderPages[botId], let sessionId = sessions[botId],
              !loadingOlder.contains(botId), olderErrors[botId] == nil
        else { return }
        loadingOlder.insert(botId)
        defer { loadingOlder.remove(botId) }
        do {
            let page = try await gateway.call("session.transcript", [
                "profile": .string(botId), "session_id": .string(sessionId),
                "order": "latest", "limit": .number(Double(Self.pageSize)), "cursor": .string(cursor),
            ])
            guard sessions[botId] == sessionId, olderPages[botId] == cursor else { return }
            let rows = transcriptItems(page)
            // `reset`: the server started over from the newest page (a rotated lineage). Otherwise
            // the rows already shown keep their ids, so the one at the top can be scrolled back to
            let held = page["reset"]?.bool == true ? [] : chats[botId] ?? []
            chats[botId] = uniqued(rows, besides: held) + held
            olderPages[botId] = page["next_cursor"]?.string
        } catch {
            olderErrors[botId] = error.localizedDescription
        }
    }

    func retryOlder(_ botId: String) async {
        olderErrors[botId] = nil
        await loadOlder(botId)
    }

    /// A transcript page's rows, oldest first. A compaction row stands where older messages
    /// were folded into a summary. Hermes gives it the `row_id` of the message it was stored on,
    /// which shows as its own row right after it when it holds real content too: their ids differ.
    func transcriptItems(_ page: JSONValue) -> [ChatItem] {
        uniqued((page["rows"]?.array ?? []).flatMap { row -> [ChatItem] in
            guard row["row_kind"]?.string == "compaction" else { return chatItems(from: row) }
            let at = row["timestamp"]?.number.map { Date(timeIntervalSince1970: $0) } ?? Date()
            let id = row["row_id"]?.int.map { "compaction-\($0)" } ?? UUID().uuidString
            return [ChatItem(id: id, role: .system, at: at, text: "更早的对话压缩成了摘要")]
        })
    }

    /// `items` with every id distinct, from each other and from `taken`'s: a repeat gets the
    /// first free `#2`, `#3`… suffix, in order, so the same rows come out with the same ids.
    private func uniqued(_ items: [ChatItem], besides taken: [ChatItem] = []) -> [ChatItem] {
        var seen = Set(taken.map(\.id))
        return items.map { item in
            var item = item
            if seen.contains(item.id) {
                let base = item.id
                var n = 2
                while seen.contains("\(base)#\(n)") { n += 1 }
                item.id = "\(base)#\(n)"
            }
            seen.insert(item.id)
            return item
        }
    }

    /// Attachments are per socket: after a reconnect every attached Bot Chat gets what it missed
    /// and resumes (AppStore+Reconnect.swift).
    private func reattach() {
        Task { await comeBack() }
    }

    /// A transcript row as the chat shows it: usually one item, none for a row that is not for you,
    /// one card per line for the board's notices.
    func chatItems(from row: JSONValue) -> [ChatItem] {
        let at = row["timestamp"]?.number.map { Date(timeIntervalSince1970: $0) } ?? Date()
        // Hermes's tool rows have no row_id; their call's id keeps them the same across reads
        let id = row["row_id"]?.int.map { "row-\($0)" } ?? row["row_id"]?.string
            ?? row["tool_call_id"]?.string.map { "tool-\($0)" } ?? UUID().uuidString
        switch row["role"]?.string {
        case "user":
            guard row["display_kind"]?.string != "hidden" else { return [] }
            let body = text(of: row)
            // the plugin's focus-check line that woke 詩音: for her, not for the transcript
            guard !body.hasPrefix("［专注检查］") else { return [] }
            // what you put into a turn already running (session.steer): your words, in that turn
            if row["display_kind"]?.string == "steer" {
                var item = Self.userItem(id: id, at: at, text: body)
                item.midTurn = true
                return [item]
            }
            // what Hermes gave the assistant as a turn in your name: the board's word, another
            // assistant's message, a background result. A card each, not a message of yours
            let notices = Notices.read(body, kind: row["display_kind"]?.string,
                                       display: row["display_metadata"]?["display_text"]?.string)
            guard notices.isEmpty else { return Self.noticeCards(notices, id: id, at: at) }
            return [Self.userItem(id: id, at: at, text: body)]
        case "assistant":
            let body = text(of: row)
            // the row Hermes closes a failed turn with (AppStore+Control.swift)
            if let failed = Self.failedTurn(row, id: id, at: at, body: body) { return [failed] }
            // a reply you stopped: Hermes marks the row it kept (an empty one when nothing had come)
            let stopped = row["display_metadata"]?["interrupted"]?.bool == true
            guard !body.isEmpty else {
                return stopped ? [ChatItem(id: id, role: .system, at: at, text: "已停止", stopped: true)] : []
            }
            // nothing to say, said with a marker: no row (Silence.swift)
            guard !Silence.isMarker(body) else { return [] }
            return [ChatItem(id: id, role: .assistant, at: at, text: Silence.withoutClosingMarker(body), stopped: stopped)]
        case "tool":
            let name = row["name"]?.string ?? row["tool_name"]?.string ?? "tool"
            if let message = Self.sentMessage(name, args: row["args"]) {
                return [ChatItem(id: id, role: .card, at: at, text: message.words, event: .sent(to: message.to))]
            }
            if let made = Self.madeCard(name, args: row["args"]) {
                return [ChatItem(id: id, role: .card, at: at, cardTitle: made.title, cardAssignee: made.assignee)]
            }
            return [ChatItem(id: id, role: .tool, at: at, text: toolLine(name, row["context"]?.string ?? ""))]
        default:
            return []
        }
    }

    /// A notice's cards, the first under the row's id: a row read again is the same cards.
    static func noticeCards(_ notices: [Notices.Notice], id: String, at: Date) -> [ChatItem] {
        notices.enumerated().map { index, notice in
            ChatItem(id: index == 0 ? id : "\(id)-card\(index + 1)", role: .card, at: at, text: notice.text,
                     event: notice.event, cardId: notice.cardId, cardTitle: notice.cardTitle, cardAssignee: notice.assignee)
        }
    }

    /// A message_agent call: what this assistant wrote to another, and to whom (its profile).
    static func sentMessage(_ name: String, args: JSONValue?) -> (to: String, words: String)? {
        guard name == "message_agent", let words = args?["message"]?.string, !words.isEmpty else { return nil }
        return (args?["target"]?.string ?? "", words)
    }

    /// A kanban_create call's card: the title it was made with and who it was handed to.
    private static func madeCard(_ name: String, args: JSONValue?) -> (title: String, assignee: String?)? {
        guard name == "kanban_create", let title = args?["title"]?.string, !title.isEmpty else { return nil }
        let assignee = args?["assignee"]?.string ?? ""
        return (title, assignee.isEmpty ? nil : assignee)
    }

    /// The id of the card a kanban_create call made, from its result (`{"ok": true, "task_id": …}`,
    /// as an object or as its JSON text).
    private static func madeCardId(_ payload: JSONValue) -> String? {
        for value in [payload["result"], payload["result_text"]] {
            if let id = value?["task_id"]?.string { return id }
            if let text = value?.string, let parsed = try? JSONValue.parse(text), let id = parsed["task_id"]?.string {
                return id
            }
        }
        return nil
    }

    func text(of row: JSONValue) -> String {
        if let text = row["text"]?.string { return text }
        if let content = row["content"]?.string { return content }
        return (row["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined()
    }

    private func toolLine(_ name: String, _ context: String) -> String {
        context.isEmpty ? name : "\(name) · \(context)"
    }

    // MARK: events

    private func apply(_ type: String, sessionId: String?, payload: JSONValue) {
        if type == "plugin.shion.changed" {
            return pluginChanged(payload)
        }
        // a skill being talked over has a session of its own (SkillReviewTalk)
        if let talk = reviewing, talk.take(type, sessionId: sessionId, payload) {
            // its subscription on this socket was ended, the socket kept: it is no Bot Chat's, so
            // noteDelivery does not see to it. Read and attached again
            if type == "session.replay_gap" {
                Task { await talk.rejoin(in: self) }
            }
            return
        }
        guard let sessionId, let botId = sessionBots[sessionId] else { return }
        FollowTrace.log("frame \(type) \(botId)")
        secretEvent(type, sessionId: sessionId, payload: payload)
        // a chat not opened yet has no rows to add to: its first page brings them
        let shown = loadedChats.contains(botId)
        switch type {
        case "message.start", "message.delta", "message.interim", "tool.start":
            setReplying(botId, true)
        case "message.complete":
            setReplying(botId, false)
        case "session.info" where payload["running"]?.bool == false:
            setReplying(botId, false)
        default:
            break
        }
        switch type {
        case "message.start":
            if shown {
                // a turn Hermes started itself says with what: its card first, then the reply
                noteTurnStart(payload, in: botId)
                beginReply(botId)
                followNotices(botId, atStart: true)
            }
        case "message.delta":
            if shown, let text = payload["text"]?.string {
                appendReply(botId, text)
            }
        case "message.interim":
            if shown, payload["already_streamed"]?.bool != true, let text = payload["text"]?.string {
                appendReply(botId, text)
                endReply(botId)
            }
        case "message.complete":
            // what streamed, when the end does not repeat it: read before the reply is closed
            var text = payload["text"]?.string ?? ""
            if text.isEmpty, shown, let id = streaming[botId] {
                text = chats[botId]?.first(where: { $0.id == id })?.text ?? ""
            }
            if shown {
                let reply = streaming[botId]
                let held = chats[botId]?.count ?? 0
                completeReply(botId, payload)
                // the rows the turn was stored as: its reply's bubble (the one that streamed, or
                // the one its end brought whole) and the cards its start made are those rows now
                let whole = (chats[botId]?.count ?? 0) > held ? chats[botId]?.last?.id : nil
                noteTurnRows(payload["persisted_turn"], in: botId, reply: reply ?? whole)
                // a turn of someone else's making: what started it is a row to read (AppStore+Events.swift)
                let submission = payload["persisted_turn"]?["submission_id"]?.string
                if submission == nil || chats[botId]?.contains(where: { $0.id == submission }) != true {
                    // the end names the row the turn began with: read up to it
                    followNotices(botId, atStart: false, row: payload["persisted_turn"]?["user_row_id"]?.int)
                }
            }
            if payload["status"]?.string == "error" {
                notifyReply(botId, Self.failureLine(payload, streamed: ""), payload)
            } else if payload["status"]?.string != "interrupted", !Silence.isMarker(text) {
                // a turn that ended with nothing to say (Silence.swift) is no news
                notifyReply(botId, Silence.withoutClosingMarker(text), payload)
            }
        case "tool.start":
            guard shown else { break }
            endReply(botId)
            let name = payload["name"]?.string ?? payload["tool_name"]?.string ?? "tool"
            if let message = Self.sentMessage(name, args: payload["args"]) {
                // under the id the transcript gives the call's row, so a read of it is the same card
                let id = freshId(payload["tool_id"]?.string.map { "tool-\($0)" }, in: botId)
                append(ChatItem(id: id, role: .card, at: Date(), text: message.words, event: .sent(to: message.to)), to: botId)
            } else if let made = Self.madeCard(name, args: payload["args"]) {
                let id = UUID().uuidString
                if let call = payload["tool_id"]?.string {
                    madeCards[call] = (botId, id)
                }
                append(ChatItem(id: id, role: .card, at: Date(), cardTitle: made.title, cardAssignee: made.assignee), to: botId)
            } else {
                // the id the transcript gives the call's row, so a read of it keeps the line's id
                let id = freshId(payload["tool_id"]?.string.map { "tool-\($0)" }, in: botId)
                append(ChatItem(id: id, role: .tool, at: Date(), text: toolLine(name, payload["context"]?.string ?? "")), to: botId)
            }
        case "tool.complete":
            toolFinished(payload, botId: botId)
            // a kanban_create call's result names the card it made
            guard let call = payload["tool_id"]?.string, let made = madeCards.removeValue(forKey: call),
                  let cardId = Self.madeCardId(payload),
                  let index = chats[made.botId]?.firstIndex(where: { $0.id == made.itemId })
            else { break }
            chats[made.botId]?[index].cardId = cardId
        case "status.update":
            // the board's word on a card this chat made, just before the turn it starts
            if shown { noteStatus(payload, in: botId) }
        case "review.summary":
            // what the review after a turn kept: skills, memory (AppStore+Events.swift)
            noteLearned(payload, in: botId)
        case "session.info":
            if let running = payload["running"]?.bool {
                setRunning(botId, running)
            }
        case "approval.request", "clarify.request":
            addPrompt(payload, sessionId: sessionId, botId: botId)
        case "approval.settled", "clarify.settled":
            if let promptId = payload["prompt_id"]?.string {
                asks.removeAll { $0.id == promptId }
                Notifier.shared.withdraw(promptId)
            }
        default:
            break
        }
    }

    private func beginReply(_ botId: String) {
        let id = UUID().uuidString
        append(ChatItem(id: id, role: .assistant, at: Date(), streaming: true), to: botId)
        streaming[botId] = id
    }

    private func appendReply(_ botId: String, _ text: String) {
        if streaming[botId] == nil {
            beginReply(botId)
        }
        guard let id = streaming[botId], let index = chats[botId]?.firstIndex(where: { $0.id == id }) else { return }
        chats[botId]?[index].text += text
    }

    private func endReply(_ botId: String) {
        guard let id = streaming.removeValue(forKey: botId),
              let index = chats[botId]?.firstIndex(where: { $0.id == id })
        else { return }
        chats[botId]?[index].streaming = false
        // nothing came, or only the marker for nothing to say: no bubble (Silence.swift)
        let text = chats[botId]?[index].text ?? ""
        if text.isEmpty || Silence.isMarker(text) {
            chats[botId]?.remove(at: index)
        } else {
            chats[botId]?[index].text = Silence.withoutClosingMarker(text)
        }
    }

    private func completeReply(_ botId: String, _ payload: JSONValue) {
        // stopped: what had come stays (AppStore+Control.swift)
        if payload["status"]?.string == "interrupted" {
            return markStopped(botId, reply: streaming.removeValue(forKey: botId))
        }
        // failed: a line says why (AppStore+Control.swift)
        if payload["status"]?.string == "error" {
            return failReply(botId, payload, reply: streaming.removeValue(forKey: botId))
        }
        let final = payload["text"]?.string ?? ""
        if let id = streaming[botId], let index = chats[botId]?.firstIndex(where: { $0.id == id }) {
            if !final.isEmpty {
                chats[botId]?[index].text = final
            }
        } else if !final.isEmpty, !Silence.isMarker(final) {
            append(ChatItem(id: UUID().uuidString, role: .assistant, at: Date(), text: Silence.withoutClosingMarker(final)), to: botId)
        }
        endReply(botId)
    }

    func append(_ item: ChatItem, to botId: String) {
        chats[botId, default: []].append(item)
    }

    /// `preferred`, unless the chat already has a row with it.
    private func freshId(_ preferred: String?, in botId: String) -> String {
        guard let preferred, !(chats[botId] ?? []).contains(where: { $0.id == preferred }) else { return UUID().uuidString }
        return preferred
    }

    private func setReplying(_ botId: String, _ on: Bool) {
        guard replying.contains(botId) != on else { return }
        if on {
            replying.insert(botId)
        } else {
            replying.remove(botId)
        }
    }

    private func note(_ text: String, in botId: String) {
        append(ChatItem(id: UUID().uuidString, role: .system, at: Date(), text: text), to: botId)
    }

    private func setRunning(_ botId: String, _ running: Bool) {
        guard let index = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[index].status = running ? .working : .idle
        bots[index].statusNote = running ? "在回复" : ""
    }

    // MARK: approvals and questions

    private func addPrompt(_ prompt: JSONValue, sessionId: String, botId: String) {
        guard let promptId = prompt["prompt_id"]?.string, !asks.contains(where: { $0.id == promptId }) else { return }
        let generation = prompt["execution_generation"]?.int ?? 0
        let choices = (prompt["choices"]?.array ?? []).compactMap { $0.string }
        if prompt["kind"]?.string == "clarify" {
            var options = choices.enumerated().map { pair in
                AskOption(value: pair.element, label: pair.element, primary: pair.offset == 0)
            }
            if options.isEmpty {
                options = [AskOption(value: "", label: "跳过")]
            }
            asks.insert(Ask(
                id: promptId, kind: .clarify, botId: botId, at: Date(),
                title: prompt["question"]?.string ?? "",
                options: options,
                remote: RemotePrompt(sessionId: sessionId, generation: generation, isClarify: true)
            ), at: 0)
        } else {
            let command = prompt["command"]?.string ?? ""
            let description = prompt["description"]?.string ?? ""
            asks.insert(Ask(
                id: promptId, kind: .approval, botId: botId, at: Date(),
                title: description.isEmpty ? "要执行这条命令吗？" : description,
                preview: command.isEmpty ? nil : command,
                options: (choices.isEmpty ? ["once", "deny"] : choices).map { choice in
                    AskOption(value: choice, label: approvalLabel(choice), primary: choice == "once")
                },
                remote: RemotePrompt(sessionId: sessionId, generation: generation, isClarify: false)
            ), at: 0)
        }
        if let ask = asks.first, ask.id == promptId {
            notifyAsk(ask)
        }
    }

    /// Unless 待你处理 or the assistant's chat is in front of you, or the ⌥Space window shows it.
    private func notifyAsk(_ ask: Ask) {
        guard !(NSApp.isActive && (route == .confirm || route == .chat(ask.botId))),
              !QuickAsk.shared.showsAnswer(from: ask.botId) else { return }
        Notifier.shared.ask(ask, from: bot(ask.botId)?.name ?? ask.botId)
    }

    /// Unless the assistant's chat is in front of you, or the ⌥Space window shows the reply, or a
    /// Shortcuts action is waiting to hand it back (ShionShortcuts.swift). A click finds the reply
    /// by the row Hermes stored it as (`persisted_turn`), or by the row it streamed into.
    private func notifyReply(_ botId: String, _ text: String, _ payload: JSONValue) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !(NSApp.isActive && route == .chat(botId)),
              !QuickAsk.shared.showsAnswer(from: botId), !ShionShortcuts.awaitsReply(from: botId) else { return }
        Notifier.shared.reply(text, from: bot(botId)?.name ?? botId, botId: botId,
                              row: payload["persisted_turn"]?["final_assistant_row_id"]?.int,
                              item: chats[botId]?.last(where: { $0.role == .assistant })?.id)
    }

    private func approvalLabel(_ choice: String) -> String {
        switch choice {
        case "once": return "允许这一次"
        case "session": return "这次对话都允许"
        case "always": return "以后都允许"
        case "deny": return "拒绝"
        default: return choice
        }
    }

    private func respond(to ask: Ask, remote: RemotePrompt, with option: AskOption) {
        var params: JSONValue = [
            "profile": .string(ask.botId),
            "session_id": .string(remote.sessionId),
            "execution_generation": .number(Double(remote.generation)),
            "prompt_id": .string(ask.id),
        ]
        if case .object(var fields) = params {
            fields[remote.isClarify ? "answer" : "choice"] = .string(option.value)
            params = .object(fields)
        }
        let method = remote.isClarify ? "clarify.respond" : "approval.respond"
        Task {
            do {
                // on a new socket, once the chat is attached again (AppStore+Reconnect.swift)
                await waitForChat(ask.botId)
                try await gateway.call(method, params, timeout: 300)
            } catch {
                note("没能回复：\(error.localizedDescription)", in: ask.botId)
            }
        }
    }
}
