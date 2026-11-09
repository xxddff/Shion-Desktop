import Observation
import SwiftUI

/// Everything the window shows. Starts on demo data; once connected to a Hermes server, the
/// assistants and their Bot Chats come from it (the other pages stay on demo data until the
/// `shion` plugin exists).
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
    var focus: FocusStatus
    var activityLog = true
    var focusCheck = true

    // the Hermes server
    let gateway = Gateway()
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
    /// The server's board limits, read after connecting.
    private(set) var boardLimits: BoardLimits?
    /// What `runtime.describe` says the server can do (`session-transcript-v1`, …).
    @ObservationIgnored private var serverCapabilities: Set<String> = []
    /// bot id → how many of its rows came before the attach that is waiting for its first page
    @ObservationIgnored private var attachMarks: [String: Int] = [:]
    @ObservationIgnored private var demoBots: [Bot] = []
    @ObservationIgnored private var demoChats: [String: [ChatItem]] = [:]
    @ObservationIgnored private var demoAsks: [Ask] = []
    /// bot id → its Bot Chat's session id, and back
    @ObservationIgnored private var sessions: [String: String] = [:]
    @ObservationIgnored private var sessionBots: [String: String] = [:]
    /// bot id → the assistant message being streamed
    @ObservationIgnored private var streaming: [String: String] = [:]

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
        focus = FocusStatus(planTitle: "机器学习 课前小测", plannedAt: demo.at(0, 10, 45), onTrack: false)
        gateway.onEvent = { [weak self] type, sessionId, payload in
            self?.apply(type, sessionId: sessionId, payload: payload)
        }
        gateway.onReconnect = { [weak self] in
            self?.reattach()
        }
        gateway.credential = { [weak self] settings, renew in
            guard let self else { throw GatewayError.offline }
            return try await self.credential(for: settings, renew: renew)
        }
        if canConnect(serverSettings) && !LaunchOptions.current.snapshot {
            Task { await connect() }
        }
    }

    func bot(_ id: String) -> Bot? { bots.first { $0.id == id } }
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

    func events(on day: Date) -> [CalEvent] {
        events.filter { Fmt.dayDiff($0.start, day) == 0 }.sorted { $0.start < $1.start }
    }

    /// The next thing on today's calendar that is not a commute.
    var nextEvent: CalEvent? {
        events(on: now).first { $0.start > now && $0.kind != .commute }
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
        if let remote = ask.remote {
            respond(to: ask, remote: remote, with: option)
            return
        }
        chats[ask.botId, default: []].append(ChatItem(id: UUID().uuidString, role: .user, at: now, text: option.label))
        if ask.kind == .takeover && option.primary {
            route = .desktop
        }
    }

    func send(_ text: String, to botId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard live else {
            chats[botId, default: []].append(ChatItem(id: UUID().uuidString, role: .user, at: now, text: trimmed))
            return
        }
        guard let sessionId = sessions[botId] else {
            chatErrors[botId] = "对话还没打开"
            return
        }
        chats[botId, default: []].append(ChatItem(id: UUID().uuidString, role: .user, at: Date(), text: trimmed))
        let params: JSONValue = [
            "profile": .string(botId),
            "session_id": .string(sessionId),
            "text": .string(trimmed),
            "submission_id": .string(UUID().uuidString),
        ]
        Task {
            do {
                try await gateway.call("prompt.submit", params)
            } catch {
                note("没发出去：\(error.localizedDescription)", in: botId)
            }
        }
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
        await loadBoardLimits()
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
    private var pagesTranscripts: Bool { serverCapabilities.contains("session-transcript-v1") }

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
        gateway.disconnect()
        leaveLive()
    }

    /// Screenshot and test runs keep what they type in memory: no keychain, no preferences.
    private func keepSettings() {
        serverSettings = serverSettings.trimmed
        if !LaunchOptions.current.snapshot {
            serverSettings.save()
        }
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

    /// One assistant per profile; the profile named `shion` (else the default one) leads.
    private func enterLive(with rows: [JSONValue]) {
        if !live {
            demoBots = bots
            demoChats = chats
            demoAsks = asks
        }
        let names = rows.compactMap { $0["name"]?.string }
        let defaultRow = rows.first(where: { $0["is_default"]?.bool == true })
        let chiefName = names.contains("shion") ? "shion" : (defaultRow?["name"]?.string ?? names.first ?? "")
        var liveBots: [Bot] = []
        for (index, row) in rows.enumerated() {
            guard let name = row["name"]?.string else { continue }
            // the name Bot Mode shows: its ui_meta title, then the profile's display name
            let display = [row["ui_meta"]?["hermes-bots"]?["title"]?.string, row["display_name"]?.string]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? name
            let description = row["description"]?.string ?? ""
            let chief = name == chiefName
            liveBots.append(Bot(
                id: name,
                name: display,
                title: chief ? "总秘书" : (description.isEmpty ? name : description),
                chief: chief,
                hue: chief ? Palette.accent : Palette.hues[index % Palette.hues.count],
                status: .idle,
                statusNote: ""
            ))
        }
        bots = liveBots.filter { $0.chief } + liveBots.filter { !$0.chief }
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
        guard live else { return }
        live = false
        bots = demoBots
        chats = demoChats
        asks = demoAsks
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
    }

    /// Finds the assistant's Bot Chat (the session titled "Bot Chat" in its profile), creates it
    /// when there is none, and attaches this connection to it.
    func openChat(_ botId: String) async {
        guard live, gateway.phase == .online, sessions[botId] == nil, !openingChats.contains(botId) else { return }
        openingChats.insert(botId)
        defer { openingChats.remove(botId) }
        chatErrors[botId] = nil
        do {
            let listed = try await gateway.call("session.list", [
                "profile": .string(botId), "title": "Bot Chat", "limit": 200, "include_hidden": true,
            ])
            let row = (listed["sessions"]?.array ?? []).first(where: { candidate in
                let root = candidate["root_title"]?.string
                return root == "Bot Chat" || (root == nil && candidate["title"]?.string == "Bot Chat")
            })
            let snapshot: JSONValue
            if let row, let id = row["resolved_id"]?.string ?? row["id"]?.string ?? row["session_id"]?.string {
                snapshot = try await gateway.call("session.resume", resumeParams(botId, id))
            } else {
                snapshot = try await gateway.call("session.create", createParams(botId))
            }
            attach(botId, snapshot: snapshot)
            try await loadLatestPage(botId, snapshot: snapshot)
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
    private func resumeParams(_ botId: String, _ sessionId: String) -> JSONValue {
        pagesTranscripts
            ? ["profile": .string(botId), "session_id": .string(sessionId), "omit_messages": true]
            : ["profile": .string(botId), "session_id": .string(sessionId), "display_projection": true]
    }

    private func attach(_ botId: String, snapshot: JSONValue) {
        guard let sessionId = snapshot["session_id"]?.string else { return }
        sessions[botId] = sessionId
        sessionBots[sessionId] = botId
        streaming[botId] = nil
        if snapshot["messages_omitted"]?.bool == true {
            // the rows held now stay up until the latest page replaces them; anything that
            // streams in meanwhile lands after this mark and is kept
            attachMarks[botId] = chats[botId]?.count ?? 0
        } else {
            let rows = snapshot["display_messages"]?.array ?? snapshot["messages"]?.array ?? []
            chats[botId] = rows.compactMap(chatItem(from:))
            olderPages[botId] = nil
        }
        setRunning(botId, snapshot["running"]?.bool ?? false)
        for prompt in snapshot["prompts"]?.array ?? [] {
            addPrompt(prompt, sessionId: sessionId, botId: botId)
        }
    }

    /// The newest page of a resumed transcript (`session.transcript`, latest first), in place of
    /// whatever was held, keeping what streamed in since the attach.
    private func loadLatestPage(_ botId: String, snapshot: JSONValue) async throws {
        guard snapshot["messages_omitted"]?.bool == true, let sessionId = sessions[botId] else { return }
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
        let streamed = held[mark...].filter { item in
            item.streaming || !recent.contains { $0.role == item.role && $0.text == item.text }
        }
        chats[botId] = rows + streamed
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
            // `reset`: the server started over from the newest page (a rotated lineage)
            chats[botId] = page["reset"]?.bool == true ? rows : rows + (chats[botId] ?? [])
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
    /// were folded into a summary.
    private func transcriptItems(_ page: JSONValue) -> [ChatItem] {
        (page["rows"]?.array ?? []).compactMap { row in
            guard row["row_kind"]?.string == "compaction" else { return chatItem(from: row) }
            let at = row["timestamp"]?.number.map { Date(timeIntervalSince1970: $0) } ?? Date()
            let id = row["row_id"]?.int.map { "row-\($0)" } ?? UUID().uuidString
            return ChatItem(id: id, role: .system, at: at, text: "更早的对话压缩成了摘要")
        }
    }

    /// Attachments are per socket: after a reconnect every open Bot Chat resumes, from its
    /// newest page again.
    private func reattach() {
        let open = sessions
        Task {
            for (botId, sessionId) in open {
                guard let snapshot = try? await gateway.call("session.resume", resumeParams(botId, sessionId)) else { continue }
                attach(botId, snapshot: snapshot)
                try? await loadLatestPage(botId, snapshot: snapshot)
            }
        }
    }

    private func chatItem(from row: JSONValue) -> ChatItem? {
        let at = row["timestamp"]?.number.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let id = row["row_id"]?.int.map { "row-\($0)" } ?? row["row_id"]?.string ?? UUID().uuidString
        switch row["role"]?.string {
        case "user":
            guard row["display_kind"]?.string != "hidden" else { return nil }
            return ChatItem(id: id, role: .user, at: at, text: text(of: row))
        case "assistant":
            let body = text(of: row)
            return body.isEmpty ? nil : ChatItem(id: id, role: .assistant, at: at, text: body)
        case "tool":
            let name = row["name"]?.string ?? row["tool_name"]?.string ?? "tool"
            return ChatItem(id: id, role: .tool, at: at, text: toolLine(name, row["context"]?.string ?? ""))
        default:
            return nil
        }
    }

    private func text(of row: JSONValue) -> String {
        if let text = row["text"]?.string { return text }
        if let content = row["content"]?.string { return content }
        return (row["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined()
    }

    private func toolLine(_ name: String, _ context: String) -> String {
        context.isEmpty ? name : "\(name) · \(context)"
    }

    // MARK: events

    private func apply(_ type: String, sessionId: String?, payload: JSONValue) {
        guard let sessionId, let botId = sessionBots[sessionId] else { return }
        switch type {
        case "message.start":
            beginReply(botId)
        case "message.delta":
            if let text = payload["text"]?.string {
                appendReply(botId, text)
            }
        case "message.interim":
            if payload["already_streamed"]?.bool != true, let text = payload["text"]?.string {
                appendReply(botId, text)
                endReply(botId)
            }
        case "message.complete":
            completeReply(botId, payload)
        case "tool.start":
            endReply(botId)
            let name = payload["name"]?.string ?? payload["tool_name"]?.string ?? "tool"
            append(ChatItem(id: UUID().uuidString, role: .tool, at: Date(), text: toolLine(name, payload["context"]?.string ?? "")), to: botId)
        case "session.info":
            if let running = payload["running"]?.bool {
                setRunning(botId, running)
            }
        case "approval.request", "clarify.request":
            addPrompt(payload, sessionId: sessionId, botId: botId)
        case "approval.settled", "clarify.settled":
            if let promptId = payload["prompt_id"]?.string {
                asks.removeAll { $0.id == promptId }
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
        if chats[botId]?[index].text.isEmpty == true {
            chats[botId]?.remove(at: index)
        }
    }

    private func completeReply(_ botId: String, _ payload: JSONValue) {
        let final = payload["text"]?.string ?? ""
        if let id = streaming[botId], let index = chats[botId]?.firstIndex(where: { $0.id == id }) {
            if !final.isEmpty {
                chats[botId]?[index].text = final
            }
        } else if !final.isEmpty {
            append(ChatItem(id: UUID().uuidString, role: .assistant, at: Date(), text: final), to: botId)
        }
        endReply(botId)
        if payload["status"]?.string == "error" {
            note("这一轮出错了：\(payload["error_surface"]?.string ?? "没有说明")", in: botId)
        }
    }

    private func append(_ item: ChatItem, to botId: String) {
        chats[botId, default: []].append(item)
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
                try await gateway.call(method, params, timeout: 300)
            } catch {
                note("没能回复：\(error.localizedDescription)", in: ask.botId)
            }
        }
    }
}
