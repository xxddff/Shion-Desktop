import Foundation
import Observation

/// The server's kanban board while connected: the cards (`GET /board`), every board's counts
/// (`GET /boards`, for the server-wide limit), who is doing what on this board (`GET /assignees`,
/// for the per-assistant limit), and the details the cards need (`GET /tasks/{id}`: a block's
/// reason, the parents a card waits for). Kept current by the plugin's event socket; any event
/// reads the board again.
///
/// Shion never calls `POST /dispatch`: it would start cards past `kanban.max_in_progress` and
/// `max_in_progress_per_profile`. A ready card waits for the dispatcher's next tick.
@Observable
final class BoardStore {
    /// Started for a connected server; the board page shows the demo cards otherwise.
    private(set) var active = false
    /// The first read came back.
    private(set) var loaded = false
    private(set) var loadError: String?
    private(set) var workflow = KanbanWorkflow.standard
    private(set) var boards: [KanbanBoardInfo] = []
    /// The board shown; the server's current one until you pick another.
    private(set) var slug: String?
    private(set) var tasks: [KanbanTask] = []
    private(set) var details: [String: KanbanDetail] = [:]
    /// Profiles and assignees the board knows, for 「交给」.
    private(set) var assigneeNames: [String] = []
    /// assignee → its cards running on this board (the per-assistant limit counts per board)
    private(set) var runningByAssignee: [String: Int] = [:]
    /// The other boards' cards, by board, for 今天's 助手在做 and the cards in chats: the page
    /// shows one board at a time, the rest is read once a minute.
    private(set) var elsewhere: [String: [KanbanTask]] = [:]
    /// Details of the other boards' blocked cards, for their reasons.
    private(set) var elsewhereDetails: [String: KanbanDetail] = [:]
    /// Why the last change did not go through.
    var actionError: String?

    /// The name you signed in with, sent as your comments' author; without it (a session token)
    /// Hermes records them as `dashboard`. Cards you make are always `dashboard`'s: the server sets that.
    @ObservationIgnored private(set) var author: String?
    @ObservationIgnored private var client: KanbanClient?
    /// Bumped by start, stop and a board switch: work begun for an older one stops.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cursor: Int?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var refresh: Task<Void, Never>?
    /// Cards an event touched since their detail was read.
    @ObservationIgnored private var stale: Set<String> = []
    /// The card open in the inspector.
    @ObservationIgnored private var focus: String?
    /// The server's clock minus this Mac's, from `/board`'s `now`.
    @ObservationIgnored private var skew: TimeInterval = 0

    var serverNow: Date { Date().addingTimeInterval(skew) }

    var currentBoard: KanbanBoardInfo? { boards.first { $0.slug == slug } }

    /// Cards running on every board of the server: what `kanban.max_in_progress` counts.
    var totalRunning: Int { boards.reduce(0) { $0 + ($1.counts["running"] ?? 0) } }

    func task(_ id: String) -> KanbanTask? { tasks.first { $0.id == id } }

    // MARK: starting and stopping

    func start(_ settings: ServerSettings, credential: KanbanClient.Signer?, author: String?) {
        stop()
        self.author = author
        guard let credential else { return }
        client = KanbanClient(settings: settings, credential: credential)
        active = true
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            await self.begin(token)
        }
    }

    func stop() {
        generation += 1
        close()
        poller?.cancel()
        poller = nil
        client = nil
        active = false
        loaded = false
        loadError = nil
        workflow = .standard
        boards = []
        slug = nil
        tasks = []
        details = [:]
        assigneeNames = []
        runningByAssignee = [:]
        elsewhere = [:]
        elsewhereDetails = [:]
        actionError = nil
        stale = []
        focus = nil
    }

    /// Shows another board: its own cards and its own event stream.
    func switchTo(_ slug: String) {
        guard active, slug != self.slug else { return }
        generation += 1
        close()
        self.slug = slug
        tasks = []
        details = [:]
        stale = []
        loaded = false
        loadError = nil
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            await self.reload()
            guard token == self.generation else { return }
            self.listen(token)
            await self.readElsewhere(token)
        }
    }

    private func begin(_ token: Int) async {
        guard let client else { return }
        if let reply = try? await client.get("/workflow"), let parsed = KanbanWorkflow(reply) {
            workflow = parsed
        }
        guard token == generation else { return }
        await reload()
        guard token == generation else { return }
        listen(token)
        await readElsewhere(token)
        // other boards have no event stream here: their counts (the server-wide limit) and cards
        // are read now and then
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, token == self.generation else { return }
                await self.reload()
                await self.readElsewhere(token)
            }
        }
    }

    private func close() {
        listener?.cancel()
        listener = nil
        refresh?.cancel()
        refresh = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        cursor = nil
    }

    // MARK: reading

    /// The boards, this board's cards and assignees, then the details its cards need.
    func reload() async {
        let token = generation
        guard let client else { return }
        do {
            let listing = try await client.get("/boards")
            guard token == generation else { return }
            boards = (listing["boards"]?.array ?? []).compactMap { KanbanBoardInfo($0) }
            if slug == nil || !boards.contains(where: { $0.slug == slug }) {
                slug = listing["current"]?.string ?? boards.first(where: \.isCurrent)?.slug ?? boards.first?.slug
            }
            let reply = try await client.get("/board", board: slug)
            let assignees = try? await client.get("/assignees", board: slug)
            guard token == generation else { return }
            apply(reply, assignees: assignees)
            loaded = true
            loadError = nil
        } catch {
            guard token == generation, !Self.cancelled(error) else { return }
            loadError = error.localizedDescription
            return
        }
        await fetchDetails(token)
    }

    /// A `/board` reply's cards, less the archived ones.
    private static func tasks(in reply: JSONValue) -> [KanbanTask] {
        (reply["columns"]?.array ?? [])
            .filter { $0["name"]?.string != KanbanWorkflow.archived }
            .flatMap { column in (column["tasks"]?.array ?? []).compactMap { KanbanTask($0) } }
    }

    /// The other boards' cards, and the reasons their blocked ones give; a board with no cards is
    /// not read.
    private func readElsewhere(_ token: Int) async {
        guard let client else { return }
        var cards: [String: [KanbanTask]] = [:]
        var blocked: [String: KanbanDetail] = [:]
        for info in boards where info.slug != slug && info.counts.values.contains(where: { $0 > 0 }) {
            guard let reply = try? await client.get("/board", board: info.slug) else { continue }
            guard token == generation else { return }
            let found = Self.tasks(in: reply)
            cards[info.slug] = found
            for task in found where task.status == "blocked" {
                if let detail = try? await client.get("/tasks/\(KanbanClient.encode(task.id))", board: info.slug) {
                    blocked[task.id] = KanbanDetail(detail)
                }
            }
        }
        guard token == generation else { return }
        elsewhere = cards
        elsewhereDetails = blocked
    }

    private func apply(_ reply: JSONValue, assignees: JSONValue?) {
        tasks = Self.tasks(in: reply)
        if let now = reply["now"]?.number {
            skew = Date(timeIntervalSince1970: now).timeIntervalSinceNow
        }
        if cursor == nil {
            cursor = reply["latest_event_id"]?.int ?? 0
        }
        var names = (reply["assignees"]?.array ?? []).compactMap { $0.string }
        var running: [String: Int] = [:]
        for row in assignees?["assignees"]?.array ?? [] {
            guard let name = row["name"]?.string else { continue }
            if !names.contains(name) {
                names.append(name)
            }
            running[name] = row["counts"]?["running"]?.int ?? 0
        }
        assigneeNames = names
        runningByAssignee = running
        let ids = Set(tasks.map(\.id))
        details = details.filter { ids.contains($0.key) }
    }

    /// Blocked cards (for the reason) and cards waiting on parents (for their titles), plus the one
    /// in the inspector.
    private func fetchDetails(_ token: Int) async {
        let wanted = tasks.filter { task in
            task.id == focus || task.status == "blocked" || task.status == "scheduled"
                || (task.status == "todo" && task.parents > 0)
        }
        for task in wanted where details[task.id] == nil || stale.contains(task.id) {
            guard token == generation else { return }
            await loadDetail(task.id)
        }
    }

    func loadDetail(_ id: String) async {
        let token = generation
        guard let client else { return }
        guard let reply = try? await client.get("/tasks/\(KanbanClient.encode(id))", board: slug),
              token == generation
        else { return }
        details[id] = KanbanDetail(reply)
        stale.remove(id)
    }

    /// The card shown in the inspector: its detail is read now and kept fresh.
    func select(_ id: String?) {
        focus = id
        guard let id, active, details[id] == nil || stale.contains(id) else { return }
        Task { await loadDetail(id) }
    }

    // MARK: live updates

    private func listen(_ token: Int) {
        listener?.cancel()
        listener = Task { [weak self] in
            guard let self else { return }
            await self.runEvents(token)
        }
    }

    /// Reads the event stream until stopped; reconnects from the last cursor, so nothing is missed.
    private func runEvents(_ token: Int) async {
        var renew = false
        var failures = 0
        while token == generation, !Task.isCancelled {
            guard let client else { return }
            do {
                let socket = try await client.eventSocket(board: slug, since: cursor ?? 0, renew: renew)
                guard token == generation else {
                    socket.cancel(with: .normalClosure, reason: nil)
                    return
                }
                self.socket = socket
                socket.resume()
                while true {
                    let message = try await socket.receive()
                    guard token == generation else { return }
                    failures = 0
                    renew = false
                    switch message {
                    case .string(let text): handle(text)
                    case .data(let data): handle(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                // 1008: the credential was refused; renew it once before backing off
                if socket?.closeCode == .policyViolation, !renew {
                    renew = true
                    continue
                }
                failures += 1
                // the board may have moved on while the stream was down
                scheduleRefresh()
                try? await Task.sleep(for: .seconds(min(30, pow(2, Double(min(failures, 5))))))
            }
        }
    }

    private func handle(_ text: String) {
        guard let frame = try? JSONValue.parse(text) else { return }
        if let next = frame["cursor"]?.int {
            cursor = max(cursor ?? 0, next)
        }
        let touched = (frame["events"]?.array ?? []).compactMap { $0["task_id"]?.string }
        guard !touched.isEmpty else { return }
        stale.formUnion(touched)
        scheduleRefresh()
    }

    /// Events come in bursts (a move writes several): read the board once they settle.
    private func scheduleRefresh() {
        refresh?.cancel()
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            await self.reload()
        }
    }

    // MARK: changing

    /// Moves a card to another column (`PATCH /tasks/{id}`): shown at once, put back if refused.
    func move(_ id: String, to key: String) {
        guard let client, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let before = tasks[index]
        guard before.status != key else { return }
        if key == KanbanWorkflow.archived {
            tasks.remove(at: index)
        } else {
            tasks[index].status = key
        }
        let slug = self.slug
        let token = generation
        Task {
            do {
                try await client.request("PATCH", "/tasks/\(KanbanClient.encode(id))", board: slug, body: ["status": .string(key)])
            } catch {
                guard token == generation else { return }
                if let now = tasks.firstIndex(where: { $0.id == id }) {
                    tasks[now] = before
                } else {
                    tasks.insert(before, at: min(index, tasks.count))
                }
                actionError = moveFailure(error, card: before, to: key)
            }
            stale.insert(id)
            scheduleRefresh()
        }
    }

    private func moveFailure(_ error: Error, card: KanbanTask, to key: String) -> String {
        let move = "「\(card.title)」没能移到「\(Self.label(key))」"
        guard let refused = error as? KanbanError else { return "\(move)：\(error.localizedDescription)" }
        if refused.status == 409 {
            let open = (details[card.id]?.parents ?? []).filter { $0.status != "done" && $0.status != KanbanWorkflow.archived }
            if !open.isEmpty {
                return "\(move)：前面的「\(open.map(\.title).joined(separator: "」「"))」还没做完"
            }
        }
        return "\(move)：\(refused.localizedDescription)"
    }

    /// A new card (`POST /tasks`); with an assignee and nothing before it, it is ready at once.
    func create(title: String, body: String, assignee: String?) async throws -> String? {
        guard let client else { throw GatewayError.offline }
        var fields: [String: JSONValue] = ["title": .string(title)]
        if !body.isEmpty {
            fields["body"] = .string(body)
        }
        if let assignee {
            fields["assignee"] = .string(assignee)
        }
        let reply = try await client.request("POST", "/tasks", board: slug, body: .object(fields))
        if let row = reply["task"], let task = KanbanTask(row), !tasks.contains(where: { $0.id == task.id }) {
            tasks.append(task)
        }
        scheduleRefresh()
        return reply["task"]?["id"]?.string
    }

    /// A comment on the card; with `resume`, a blocked card then goes back to ready (what a
    /// worker reads first when it runs again is the comment thread).
    func comment(_ id: String, _ text: String, resume: Bool) async {
        guard let client else { return }
        let path = "/tasks/\(KanbanClient.encode(id))"
        do {
            var comment: [String: JSONValue] = ["body": .string(text)]
            if let author { comment["author"] = .string(author) }
            try await client.request("POST", path + "/comments", board: slug, body: .object(comment))
            if resume {
                try await client.request("PATCH", path, board: slug, body: ["status": "ready"])
            }
        } catch {
            actionError = "没能留言：\(error.localizedDescription)"
        }
        stale.insert(id)
        await loadDetail(id)
        scheduleRefresh()
    }

    // MARK: in words

    /// What a card is doing, waiting on, or delivered. A queued card says what holds it: its
    /// parents, its assistant's own limit, the server's, or the dispatcher's next tick. Hermes
    /// keeps no record of the two limits, so they are worked out from the running counts.
    func line(_ task: KanbanTask, limits: BoardLimits?, name: (String) -> String) -> String {
        let detail = details[task.id] ?? elsewhereDetails[task.id]
        switch task.status {
        case "running":
            guard let start = task.runStartedAt ?? task.startedAt else { return "在做" }
            let minutes = Int(serverNow.timeIntervalSince(start) / 60)
            if minutes < 1 { return "刚开始做" }
            return minutes < 60 ? "做了 \(minutes) 分钟" : "做了 \(minutes / 60) 小时"
        case "blocked":
            let reason = detail?.blockReason
            switch task.blockKind {
            case "capability": return reason.map { "缺少能力：\($0)" } ?? "缺少它需要的能力"
            case "transient": return reason.map { "出错停下了：\($0)" } ?? "出错停下了"
            default: return reason ?? "卡住了，等你"
            }
        case "review":
            return task.latestSummary.map { "做完了，等你看：\($0)" } ?? "做完了，等你看"
        case "done":
            return task.latestSummary ?? task.result ?? "做完了"
        case "triage":
            return "还没整理"
        case "scheduled":
            return detail?.scheduleReason ?? "到时间再开始"
        case "todo":
            let open = (detail?.parents ?? []).filter { $0.status != "done" && $0.status != KanbanWorkflow.archived }
            if let first = open.first {
                return open.count == 1 ? "等「\(first.title)」做完" : "等「\(first.title)」等 \(open.count) 件做完"
            }
            return task.parents > 0 ? "等前面的卡做完" : "还没排进就绪"
        case "ready":
            guard let assignee = task.assignee else { return "还没交给助手" }
            if let each = limits?.perAssistant, (runningByAssignee[assignee] ?? 0) >= each {
                return each == 1
                    ? "「\(name(assignee))」手上还有一件，做完就开始"
                    : "「\(name(assignee))」手上已经有 \(each) 件，做完一件就开始"
            }
            if let most = limits?.effectiveMax, totalRunning >= most {
                return "服务器同时在做的满了（\(most) 件），空出来就开始"
            }
            return "等下一轮派发"
        default:
            return workflow.column(task.status)?.label ?? task.status
        }
    }

    /// The board in board order, as the page lays it out.
    func items(limits: BoardLimits?, name: (String) -> String) -> [BoardItem] {
        var order: [String: Int] = [:]
        for (index, column) in workflow.columns.enumerated() {
            order[column.key] = index
        }
        return tasks.enumerated()
            .sorted { (order[$0.element.status] ?? 99, $0.offset) < (order[$1.element.status] ?? 99, $1.offset) }
            .map { pair in
                let task = pair.element
                return BoardItem(
                    id: task.id,
                    title: task.title,
                    assignee: task.assignee,
                    status: task.status,
                    line: line(task, limits: limits, name: name),
                    progress: task.progress.map { "\($0.done)/\($0.total)" },
                    comments: task.comments
                )
            }
    }

    /// The column names in Shion's words; a column Hermes adds later keeps the server's label.
    static func label(_ key: String, server: String? = nil) -> String {
        switch key {
        case "triage": return "待整理"
        case "todo": return "待办"
        case "scheduled": return "定时"
        case "ready": return "就绪"
        case "running": return "在做"
        case "blocked": return "卡住"
        case "review": return "待检查"
        case "done": return "完成"
        case KanbanWorkflow.archived: return "归档"
        default: return server ?? key
        }
    }

    private static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// A card as the board page shows it, from the server or from the demo data.
struct BoardItem: Identifiable, Hashable {
    let id: String
    let title: String
    let assignee: String?
    /// A workflow column key; demo cards get the nearest one.
    let status: String
    let line: String
    var progress: String?
    var comments = 0

    var group: CardStatus { CardStatus(key: status) }

    init(id: String, title: String, assignee: String?, status: String, line: String, progress: String? = nil, comments: Int = 0) {
        self.id = id
        self.title = title
        self.assignee = assignee
        self.status = status
        self.line = line
        self.progress = progress
        self.comments = comments
    }

    init(demo card: Card) {
        self.init(id: card.id, title: card.title, assignee: card.assignee, status: card.status.demoKey, line: card.line)
    }
}

extension CardStatus {
    /// Shion's four columns over Hermes's eight: triage, todo, scheduled and ready queue; blocked
    /// and review wait on you.
    init(key: String) {
        switch key {
        case "running": self = .running
        case "blocked", "review": self = .waiting
        case "done": self = .done
        default: self = .queued
        }
    }

    var key: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .waiting: return "waiting"
        case .done: return "done"
        }
    }

    /// Where a card dropped on this column goes, in order of preference; running is the
    /// dispatcher's, so nothing is dropped there.
    var dropKeys: [String] {
        switch self {
        case .queued: return ["ready", "todo", "triage"]
        case .running: return []
        case .waiting: return ["blocked"]
        case .done: return ["done"]
        }
    }

    fileprivate var demoKey: String {
        switch self {
        case .queued: return "ready"
        case .running: return "running"
        case .waiting: return "blocked"
        case .done: return "done"
        }
    }
}

// MARK: - the board page's data, live or demo

extension AppStore {
    var boardItems: [BoardItem] {
        guard board.active else {
            return cards.sorted { $0.updatedAt > $1.updatedAt }.map { BoardItem(demo: $0) }
        }
        return board.items(limits: boardLimits) { self.bot($0)?.name ?? $0 }
    }

    func boardItem(_ id: String) -> BoardItem? { boardItems.first { $0.id == id } }

    /// Where a card dropped on `group` goes, or nil when it may not go there.
    func boardTarget(for item: BoardItem, into group: CardStatus) -> String? {
        guard item.group != group else { return nil }
        guard board.active else { return group.dropKeys.first }
        let workflow = board.workflow
        return group.dropKeys.first { key in
            workflow.canMove(item.status, to: key) && workflow.column(key)?.dragTarget != false
        }
    }

    /// The columns a card can be sent to from its menu.
    func boardTargets(for item: BoardItem) -> [String] {
        guard board.active else {
            return CardStatus.allCases.filter { $0 != item.group && $0 != .running }.map(\.demoKey)
        }
        return board.workflow.targets(from: item.status)
    }

    func boardLabel(_ key: String) -> String {
        BoardStore.label(key, server: board.workflow.column(key)?.label)
    }

    func moveCard(_ id: String, to key: String) {
        guard board.active else {
            guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
            cards[index].status = CardStatus(key: key)
            cards[index].updatedAt = Date()
            return
        }
        board.move(id, to: key)
    }

    /// Who a card can be given to: the assistants, then anyone else the board knows.
    var boardAssignees: [String] {
        let ids = bots.map(\.id)
        guard board.active else { return ids }
        return ids + board.assigneeNames.filter { !ids.contains($0) }
    }

    func createCard(title: String, body: String, assignee: String?) async throws -> String? {
        guard board.active else {
            let id = "demo-\(UUID().uuidString.prefix(8))"
            cards.append(Card(id: id, title: title, assignee: assignee ?? chiefId, status: .queued, line: "等下一轮派发", updatedAt: Date()))
            return id
        }
        return try await board.create(title: title, body: body, assignee: assignee)
    }

    /// 今天's 助手在做: what the assistants are doing and what waits on you, on every board while
    /// connected (waiting on you first, then the newest); the demo cards otherwise.
    var workingCards: [Card] {
        guard board.active else { return cards.filter { $0.status == .running || $0.status == .waiting } }
        return serverCards.map(\.card)
            .filter { $0.status == .running || $0.status == .waiting }
            .sorted { a, b in
                if (a.status == .waiting) != (b.status == .waiting) { return a.status == .waiting }
                return a.updatedAt > b.updatedAt
            }
    }

    /// The card a chat row stands for: in the demo, a demo card; connected, the server's card by
    /// its id, or else by the title and assignee it was made with (a transcript keeps the
    /// kanban_create call, not its result). `known` is false when the server has no such card
    /// (yet): the row's own title and assignee, without a status.
    func chatCard(_ item: ChatItem) -> (card: Card, known: Bool)? {
        guard board.active else { return item.cardId.flatMap { card($0) }.map { (card: $0, known: true) } }
        let all = serverCards
        if let id = item.cardId, let found = all.first(where: { $0.id == id }) {
            return (card: found.card, known: true)
        }
        guard let title = item.cardTitle, !title.isEmpty else { return nil }
        let named = all.filter { $0.title == title && (item.cardAssignee == nil || $0.assignee == item.cardAssignee) }
        // the same title twice: the one made closest after the call
        let made = named.filter { $0.createdAt.map { $0 >= item.at.addingTimeInterval(-60) } ?? false }
        if let found = (made.min { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) } ?? named.first) {
            return (card: found.card, known: true)
        }
        let unknown = Card(id: item.id, title: title, assignee: item.cardAssignee ?? "", status: .queued, line: "", updatedAt: item.at)
        return (card: unknown, known: false)
    }

    /// Every board's cards as 今天 and the chats show them.
    private var serverCards: [ServerCard] {
        (board.tasks + board.elsewhere.values.joined()).map { task in
            ServerCard(
                card: Card(
                    id: task.id,
                    title: task.title,
                    assignee: task.assignee ?? "",
                    status: CardStatus(key: task.status),
                    line: board.line(task, limits: boardLimits) { self.bot($0)?.name ?? $0 },
                    updatedAt: task.runStartedAt ?? task.startedAt ?? task.createdAt ?? .distantPast
                ),
                createdAt: task.createdAt
            )
        }
    }

    /// Who wrote a comment or made a card: a profile is its assistant; the dashboard, and the name
    /// you signed in with, are you.
    func boardAuthor(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        if ["dashboard", "user", "you", "shion-app"].contains(name) || name == board.author { return "你" }
        return bot(name)?.name ?? name
    }
}

/// A server card as 今天 and the chats show it, with when it was made (to tell apart two cards an
/// assistant made with the same title).
struct ServerCard {
    let card: Card
    let createdAt: Date?

    var id: String { card.id }
    var title: String { card.title }
    var assignee: String { card.assignee }
    var status: CardStatus { card.status }
    var updatedAt: Date { card.updatedAt }
}
