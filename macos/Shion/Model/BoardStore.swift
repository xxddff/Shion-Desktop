import Foundation
import Observation

/// The server's kanban board while connected: the cards (`GET /board`), every board's counts
/// (`GET /boards`, for the server-wide limit), who is doing what on this board (`GET /assignees`,
/// for the per-assistant limit), and the details the cards need (`GET /tasks/{id}`: a block's
/// reason, the parents a card waits for, the runs of the cards that ran today). Kept current by
/// the plugin's event socket; any event reads the board again. The other boards are read when
/// their counts move (checked every 15 seconds) and once a minute.
///
/// Across every board it also keeps what concerns you: the cards waiting on your answer (for
/// 等你确认), each assistant's runs today (its 工作记录), and the changes worth a notification
/// (`onMoment`), worked out in BoardWork.swift.
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
    /// Details of the other boards' cards: the blocked ones (for their reasons), the waiting ones,
    /// and the ones that ran today.
    private(set) var elsewhereDetails: [String: KanbanDetail] = [:]
    /// Archived cards that ran today, by board, and their details: 工作记录's. They are read (with
    /// `include_archived`) only while a 工作记录 is open; the board page shows no archived card.
    private(set) var archived: [String: [KanbanTask]] = [:]
    private(set) var archivedDetails: [String: KanbanDetail] = [:]
    /// Why the last change did not go through.
    var actionError: String?
    /// Whether a card being done is a notification too; a card stopped on you, or handed to you
    /// to check, always is. Kept in the preferences, except in screenshot and test runs.
    var notifyDone = BoardStore.savedNotifyDone {
        didSet {
            guard !LaunchOptions.current.snapshot else { return }
            UserDefaults.standard.set(notifyDone, forKey: Self.notifyDoneKey)
        }
    }
    /// A card to open on the board page (from a notification, or 等你确认), until the page has.
    var revealing: CardRef?
    /// Told of a card whose moment changed to one worth a notification (Notifier listens).
    @ObservationIgnored var onMoment: ((CardMoment) -> Void)?

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
    /// The card open in an inspector away from the board page (an assistant's 工作记录), when it is
    /// on another board: its detail is kept fresh as the other boards are read.
    @ObservationIgnored private var focusElsewhere: CardRef?
    /// The server's clock minus this Mac's, from `/board`'s `now`.
    @ObservationIgnored private var skew: TimeInterval = 0
    /// board → card → its moment (BoardWork.momentKey) at the last read. A board not in it has not
    /// been read yet: what is on it then is not news.
    @ObservationIgnored private var moments: [String: [String: String]] = [:]
    /// The other boards' cards as they were when their details were read (BoardWork.signature).
    @ObservationIgnored private var elsewhereSigns: [String: String] = [:]
    /// Reads the boards' counts every 15 seconds.
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// The generation a read of this board (of the other boards) is under way for, and whether
    /// another was asked for meanwhile.
    @ObservationIgnored private var reading: Int?
    @ObservationIgnored private var readAgain = false
    @ObservationIgnored private var readingElsewhere: Int?
    @ObservationIgnored private var readElsewhereAgain = false
    /// The other boards' counts as the last read of them found them.
    @ObservationIgnored private var readCounts: [String: [String: Int]] = [:]
    /// How many 工作记录 are open; the archived cards as they were when their details were read;
    /// each board's archived count at the last read of them; whether a read of them is under way.
    @ObservationIgnored private var archivedWanted = 0
    @ObservationIgnored private var archivedSigns: [String: String] = [:]
    @ObservationIgnored private var archivedCounts: [String: Int] = [:]
    @ObservationIgnored private var readingArchived = false

    private static let notifyDoneKey = "BoardNotifyDone"

    private static var savedNotifyDone: Bool {
        guard !LaunchOptions.current.snapshot else { return true }
        return UserDefaults.standard.object(forKey: notifyDoneKey) as? Bool ?? true
    }

    var serverNow: Date { Date().addingTimeInterval(skew) }

    var currentBoard: KanbanBoardInfo? { boards.first { $0.slug == slug } }

    /// Cards running on every board of the server: what `kanban.max_in_progress` counts.
    var totalRunning: Int { boards.reduce(0) { $0 + ($1.counts["running"] ?? 0) } }

    func task(_ id: String) -> KanbanTask? { tasks.first { $0.id == id } }

    /// Whether `board` names the board shown (nil does).
    private func isShown(_ board: String?) -> Bool { board == nil || board == slug }

    /// A card on any board, archived ones of 工作记录 too.
    func task(_ id: String, on board: String?) -> KanbanTask? {
        let live = isShown(board) ? task(id) : board.flatMap { name in elsewhere[name]?.first { $0.id == id } }
        return live ?? (board ?? slug).flatMap { name in archived[name]?.first { $0.id == id } }
    }

    func detail(_ id: String, on board: String?) -> KanbanDetail? {
        (isShown(board) ? details[id] : elsewhereDetails[id]) ?? archivedDetails[id]
    }

    func boardInfo(_ board: String?) -> KanbanBoardInfo? {
        let wanted = board ?? slug
        return boards.first { $0.slug == wanted }
    }

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
        archived = [:]
        archivedDetails = [:]
        archivedSigns = [:]
        archivedCounts = [:]
        actionError = nil
        stale = []
        focus = nil
        focusElsewhere = nil
        moments = [:]
        elsewhereSigns = [:]
        readCounts = [:]
        watcher?.cancel()
        watcher = nil
        revealing = nil
    }

    /// Shows another board: its own cards and its own event stream. The board left counts as one
    /// of the others from now on, and the one shown starts from what was read of it.
    func switchTo(_ slug: String) {
        guard active, slug != self.slug else { return }
        generation += 1
        close()
        if let old = self.slug {
            elsewhere[old] = tasks
            for task in tasks {
                guard let detail = details[task.id] else { continue }
                elsewhereDetails[task.id] = detail
                elsewhereSigns[task.id] = BoardWork.signature(task)
            }
        }
        let incoming = elsewhere.removeValue(forKey: slug) ?? []
        self.slug = slug
        tasks = incoming
        details = incoming.reduce(into: [:]) { held, task in
            held[task.id] = elsewhereDetails[task.id]
        }
        // read again with the board: what was read of it may be a minute old
        stale = Set(incoming.map(\.id))
        loaded = false
        loadError = nil
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            await self.reload()
            guard token == self.generation else { return }
            self.listen(token)
            await self.readElsewhere(token)
            self.poll(token)
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
        poll(token)
    }

    /// Other boards have no event stream here: their counts (the server-wide limit) and cards are
    /// read once a minute, and again whenever their counts move (checked every 15 seconds), so a
    /// card there that stops on you or is done is noticed soon after. Restarted with each board.
    private func poll(_ token: Int) {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, token == self.generation else { return }
                await self.reload()
                await self.readElsewhere(token)
            }
        }
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, token == self.generation, let client = self.client else { return }
                guard let listing = try? await client.get("/boards"), token == self.generation else { continue }
                let fresh = (listing["boards"]?.array ?? []).compactMap { KanbanBoardInfo($0) }
                if fresh != self.boards {
                    self.boards = fresh
                }
                // against what the last read of them saw: a read of this board updates the counts too
                if self.otherCounts(fresh) != self.readCounts {
                    await self.readElsewhere(token)
                }
                // a card archived (or brought back) while a 工作记录 is open
                if self.archivedWanted > 0, Self.archivedCounts(fresh) != self.archivedCounts {
                    await self.readArchived()
                }
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

    /// The boards, this board's cards and assignees, then the details its cards need, then what
    /// changed that is worth telling. One read at a time: one asked for meanwhile follows it, so
    /// an older read never lands after a newer one.
    func reload() async {
        let token = generation
        if reading == token {
            readAgain = true
            return
        }
        reading = token
        repeat {
            readAgain = false
            await readShown(token)
        } while readAgain && token == generation
        if reading == token {
            reading = nil
        }
    }

    private func readShown(_ token: Int) async {
        guard let client, token == generation else { return }
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
        guard token == generation, let slug else { return }
        // a detail an event touched and not read since is the card as it was
        notice(slug, tasks) { id in self.stale.contains(id) ? nil : self.details[id] }
    }

    /// A `/board` reply's cards, less the archived ones.
    private static func tasks(in reply: JSONValue) -> [KanbanTask] {
        (reply["columns"]?.array ?? [])
            .filter { $0["name"]?.string != KanbanWorkflow.archived }
            .flatMap { column in (column["tasks"]?.array ?? []).compactMap { KanbanTask($0) } }
    }

    /// The archived column of a `/board?include_archived=true` reply.
    static func archivedTasks(in reply: JSONValue) -> [KanbanTask] {
        (reply["columns"]?.array ?? [])
            .filter { $0["name"]?.string == KanbanWorkflow.archived }
            .flatMap { column in (column["tasks"]?.array ?? []).compactMap { KanbanTask($0) } }
            .filter { $0.status == KanbanWorkflow.archived }
    }

    /// The other boards' cards and the details they need (a detail read before is kept while its
    /// card has not changed), then what changed on them that is worth telling. One read at a
    /// time, as `reload`. A board with no cards is not read.
    private func readElsewhere(_ token: Int) async {
        if readingElsewhere == token {
            readElsewhereAgain = true
            return
        }
        readingElsewhere = token
        repeat {
            readElsewhereAgain = false
            await readOthers(token)
        } while readElsewhereAgain && token == generation
        if readingElsewhere == token {
            readingElsewhere = nil
        }
    }

    /// The counts of the boards not shown, by board.
    private func otherCounts(_ list: [KanbanBoardInfo]) -> [String: [String: Int]] {
        Dictionary(list.filter { $0.slug != slug }.map { ($0.slug, $0.counts) }, uniquingKeysWith: { first, _ in first })
    }

    private func readOthers(_ token: Int) async {
        guard let client, token == generation else { return }
        let start = BoardWork.today(serverNow)
        var counts = otherCounts(boards)
        var cards: [String: [KanbanTask]] = [:]
        var kept: [String: KanbanDetail] = [:]
        var signs: [String: String] = [:]
        var read: Set<String> = []
        for info in boards where info.slug != slug {
            guard info.counts.values.contains(where: { $0 > 0 }) else {
                // nothing on it: whatever comes later is news
                if moments[info.slug] == nil {
                    moments[info.slug] = [:]
                }
                continue
            }
            guard let reply = try? await client.get("/board", board: info.slug) else {
                // not read this time: what was read of it stays, and it is read again soon
                guard token == generation else { return }
                counts[info.slug] = nil
                let held = elsewhere[info.slug] ?? []
                cards[info.slug] = held
                for task in held {
                    kept[task.id] = elsewhereDetails[task.id]
                    signs[task.id] = elsewhereSigns[task.id]
                }
                continue
            }
            guard token == generation else { return }
            let found = Self.tasks(in: reply)
            cards[info.slug] = found
            read.insert(info.slug)
            for task in found where wantsDetail(task, since: start) || focusElsewhere == CardRef(board: info.slug, id: task.id) {
                let sign = BoardWork.signature(task)
                if let held = elsewhereDetails[task.id], elsewhereSigns[task.id] == sign {
                    kept[task.id] = held
                    signs[task.id] = sign
                    continue
                }
                guard let reply = try? await client.get("/tasks/\(KanbanClient.encode(task.id))", board: info.slug) else { continue }
                guard token == generation else { return }
                kept[task.id] = KanbanDetail(reply)
                signs[task.id] = sign
            }
        }
        guard token == generation else { return }
        elsewhere = cards
        elsewhereDetails = kept
        elsewhereSigns = signs
        readCounts = counts
        for board in read {
            notice(board, cards[board] ?? []) { kept[$0] }
        }
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

    /// The details this board's cards need, plus the one in the inspector.
    private func fetchDetails(_ token: Int) async {
        let start = BoardWork.today(serverNow)
        let wanted = tasks.filter { $0.id == focus || wantsDetail($0, since: start) }
        for task in wanted where details[task.id] == nil || stale.contains(task.id) {
            guard token == generation else { return }
            await loadDetail(task.id)
        }
    }

    /// Cards whose detail is kept: blocked ones (for the reason), ones waiting on parents (for
    /// their titles) or on time, and the ones that ran today (their runs are the 工作记录).
    private func wantsDetail(_ task: KanbanTask, since start: Date) -> Bool {
        task.status == "blocked" || task.status == "scheduled" || (task.status == "todo" && task.parents > 0)
            || BoardWork.touched(task, since: start)
    }

    /// A card's detail, on this board or another.
    func loadDetail(_ id: String, on board: String? = nil) async {
        let token = generation
        let board = board ?? slug
        guard let client else { return }
        guard let reply = try? await client.get("/tasks/\(KanbanClient.encode(id))", board: board),
              token == generation
        else { return }
        // an archived card of 工作记录 (commented on in its detail): kept with the archived ones,
        // which a read of its board would not drop; one back on its board is that board's again
        if task(id, on: board)?.status == KanbanWorkflow.archived {
            archivedDetails[id] = KanbanDetail(reply)
            return
        }
        if isShown(board) {
            details[id] = KanbanDetail(reply)
            stale.remove(id)
        } else {
            elsewhereDetails[id] = KanbanDetail(reply)
            if let board, let task = elsewhere[board]?.first(where: { $0.id == id }) {
                elsewhereSigns[id] = BoardWork.signature(task)
            }
        }
    }

    /// The card shown in an inspector: its detail is read now and kept fresh.
    func select(_ id: String?, on board: String? = nil) {
        let here = isShown(board)
        if here {
            focus = id
        } else {
            focusElsewhere = id.map { CardRef(board: board, id: $0) }
        }
        guard let id, active, archivedDetails[id] == nil else { return }
        if here {
            guard details[id] == nil || stale.contains(id) else { return }
        } else {
            guard elsewhereDetails[id] == nil else { return }
        }
        Task { await loadDetail(id, on: board) }
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
    func comment(_ id: String, _ text: String, resume: Bool, on board: String? = nil) async {
        if let failure = await answer(id, on: board, text: text, resume: resume) {
            actionError = failure
        }
    }

    /// Your word on a card, as a comment under the name you signed in with (none: Hermes writes
    /// `dashboard`); with `resume` the card then goes on: PATCH ready unblocks a blocked card, and
    /// takes one the loop breaker moved to triage back to the queue. Its worker reads the comments
    /// first when it runs again. The move shows at once and is put back if refused. Returns why
    /// it did not go through.
    func answer(_ id: String, on board: String?, text: String, resume: Bool) async -> String? {
        guard let client else { return GatewayError.offline.localizedDescription }
        let board = board ?? slug
        let path = "/tasks/\(KanbanClient.encode(id))"
        let before = resume ? setStatus(id, on: board, to: "ready") : nil
        var failure: String?
        do {
            if !text.isEmpty {
                var comment: [String: JSONValue] = ["body": .string(text)]
                if let author { comment["author"] = .string(author) }
                try await client.request("POST", path + "/comments", board: board, body: .object(comment))
            }
        } catch {
            failure = "没能留言：\(error.localizedDescription)"
        }
        if resume, failure == nil {
            do {
                try await client.request("PATCH", path, board: board, body: ["status": "ready"])
            } catch {
                failure = "没能让它继续：\(error.localizedDescription)"
            }
        }
        if failure != nil, let before {
            put(before, on: board)
        }
        await refreshCard(id, on: board)
        return failure
    }

    /// Opens a card on the board page, switching to its board first when it is another one.
    func reveal(_ id: String, on board: String?) {
        if active, let board, !isShown(board), boards.contains(where: { $0.slug == board }) {
            switchTo(board)
        }
        revealing = CardRef(board: board, id: id)
    }

    /// A card's status in what is shown, before the server says so; returns it as it was.
    private func setStatus(_ id: String, on board: String?, to status: String) -> KanbanTask? {
        if isShown(board) {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
            let before = tasks[index]
            tasks[index].status = status
            return before
        }
        guard let board, let index = elsewhere[board]?.firstIndex(where: { $0.id == id }) else { return nil }
        let before = elsewhere[board]?[index]
        elsewhere[board]?[index].status = status
        return before
    }

    private func put(_ task: KanbanTask, on board: String?) {
        if isShown(board) {
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            }
        } else if let board, let index = elsewhere[board]?.firstIndex(where: { $0.id == task.id }) {
            elsewhere[board]?[index] = task
        }
    }

    /// After a change to a card: its detail and its board again.
    private func refreshCard(_ id: String, on board: String?) async {
        if isShown(board) {
            stale.insert(id)
            await loadDetail(id)
            scheduleRefresh()
        } else {
            await loadDetail(id, on: board)
            await readElsewhere(generation)
        }
    }

    // MARK: every board

    /// Every board's cards with the board each is on, this one's first.
    var allCards: [(board: String?, task: KanbanTask)] {
        tasks.map { (board: slug, task: $0) }
            + elsewhere.keys.sorted().flatMap { board in
                (elsewhere[board] ?? []).map { (board: Optional(board), task: $0) }
            }
    }

    /// The cards waiting on your answer, on every board, the latest first, each with what was
    /// said on it since it stopped.
    var waitingOnYou: [BoardAsk] {
        allCards.compactMap { board, task -> BoardAsk? in
            let detail = detail(task.id, on: board)
            guard let ask = BoardWork.ask(task, detail: detail) else { return nil }
            let since = (ask.at ?? .distantPast).addingTimeInterval(-60)
            return BoardAsk(board: board, cardId: task.id, title: task.title, assignee: task.assignee, ask: ask,
                            comments: (detail?.comments ?? []).filter { ($0.at ?? .distantPast) >= since })
        }
        .sorted { ($0.ask.at ?? .distantPast) > ($1.ask.at ?? .distantPast) }
    }

    /// What `profile` ran today, on every board: each card with its runs today, the latest first.
    /// Cards archived since are in it too, once read (`followArchived`).
    func workLog(_ profile: String) -> [WorkLogEntry] {
        let start = BoardWork.today(serverNow)
        let live = allCards
        let ids = Set(live.map(\.task.id))
        // a card brought back from the archive is on its board again; until the archive is read
        // again it would be in both
        let gone = archived.keys.sorted().flatMap { board in
            (archived[board] ?? []).filter { !ids.contains($0.id) }.map { (board: Optional(board), task: $0) }
        }
        return (live + gone).compactMap { board, task -> WorkLogEntry? in
            guard let detail = detail(task.id, on: board) else { return nil }
            let runs = BoardWork.runs(of: detail, card: task, by: profile, since: start)
            guard !runs.isEmpty else { return nil }
            return WorkLogEntry(board: board, boardName: boardInfo(board)?.name, cardId: task.id, title: task.title,
                                assignee: task.assignee, status: task.status, runs: runs)
        }
        .sorted { $0.latest > $1.latest }
    }

    /// While a 工作记录 is open (its view's task): the archived cards are read now, every minute,
    /// and when a board's archived count moves (the 15-second check of the counts).
    func followArchived() async {
        archivedWanted += 1
        defer { archivedWanted -= 1 }
        while !Task.isCancelled {
            await readArchived()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// Each board's archived count, from `/boards`.
    private static func archivedCounts(_ list: [KanbanBoardInfo]) -> [String: Int] {
        Dictionary(list.map { ($0.slug, $0.counts[KanbanWorkflow.archived] ?? 0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The archived cards that ran today: every board with archived cards is read with
    /// `include_archived`, and those touched today get their details (a detail read before is kept
    /// while its card has not changed). The board page and its counts do not change.
    func readArchived() async {
        guard active, let client, !readingArchived else { return }
        readingArchived = true
        defer { readingArchived = false }
        let token = generation
        let start = BoardWork.today(serverNow)
        let counts = Self.archivedCounts(boards)
        var cards: [String: [KanbanTask]] = [:]
        var kept: [String: KanbanDetail] = [:]
        var signs: [String: String] = [:]
        for info in boards where (counts[info.slug] ?? 0) > 0 {
            guard let reply = try? await client.get("/board", board: info.slug, query: [("include_archived", "true")]) else {
                // not read this time: what was read of it stays
                guard token == generation else { return }
                let held = archived[info.slug] ?? []
                cards[info.slug] = held
                for task in held {
                    kept[task.id] = archivedDetails[task.id]
                    signs[task.id] = archivedSigns[task.id]
                }
                continue
            }
            guard token == generation else { return }
            let found = Self.archivedTasks(in: reply).filter { BoardWork.touched($0, since: start) }
            cards[info.slug] = found
            for task in found {
                let sign = BoardWork.signature(task)
                if let held = archivedDetails[task.id], archivedSigns[task.id] == sign {
                    kept[task.id] = held
                    signs[task.id] = sign
                    continue
                }
                guard let detail = try? await client.get("/tasks/\(KanbanClient.encode(task.id))", board: info.slug) else { continue }
                guard token == generation else { return }
                kept[task.id] = KanbanDetail(detail)
                signs[task.id] = sign
            }
        }
        guard token == generation else { return }
        archived = cards
        archivedDetails = kept
        archivedSigns = signs
        archivedCounts = counts
    }

    /// Tells `onMoment` about the cards of `board` whose moment changed since its last read: one
    /// that stopped on you, was handed to you to check, or is done. The first read of a board only
    /// takes note. A card whose detail is needed and not in (or not fresh) is looked at again next
    /// time.
    private func notice(_ board: String, _ cards: [KanbanTask], _ details: (String) -> KanbanDetail?) {
        guard !Task.isCancelled else { return }
        let before = moments[board]
        var now: [String: String] = [:]
        for task in cards {
            guard let key = BoardWork.momentKey(task) else { continue }
            now[task.id] = key
            guard let before, before[task.id] != key else { continue }
            switch BoardWork.news(task, detail: details(task.id)) {
            case .wait:
                now[task.id] = before[task.id]
            case .none:
                break
            case .tell(let kind, let text):
                onMoment?(CardMoment(board: board, cardId: task.id, title: task.title, assignee: task.assignee,
                                     kind: kind, text: text))
            }
        }
        moments[board] = now
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
            // what stopped it last: the card's own kind may be left from an earlier block
            let stop = detail?.stop
            let reason = stop?.reason ?? detail?.blockReason
            if stop?.event == "gave_up" {
                return reason.map { "反复出错，停下了：\($0)" } ?? "反复出错，停下了"
            }
            switch stop?.blockKind ?? task.blockKind {
            case "capability": return reason.map { "缺少能力：\($0)" } ?? "缺少它需要的能力"
            case "transient": return reason.map { "出错停下了：\($0)" } ?? "出错停下了"
            default: return reason ?? "卡住了，等你"
            }
        case "review":
            return task.latestSummary.map { "做完了，等你看：\($0)" } ?? "做完了，等你看"
        case "done":
            return task.latestSummary ?? task.result ?? "做完了"
        case KanbanWorkflow.archived:
            return task.latestSummary ?? task.result ?? "已归档"
        case "triage":
            // the loop breaker's: it stopped on the same thing again after it was let go on
            if BoardWork.looped(task), let stop = detail?.stop, stop.event == "block_loop_detected" {
                return stop.reason.map { "又卡在同一处：\($0)" } ?? "又卡在同一处了"
            }
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
    /// The board it is on, when that is not the one the board page shows (an assistant's
    /// 工作记录 opens cards from every board).
    var board: String?

    var group: CardStatus { CardStatus(key: status) }

    init(id: String, title: String, assignee: String?, status: String, line: String, progress: String? = nil,
         comments: Int = 0, board: String? = nil) {
        self.id = id
        self.title = title
        self.assignee = assignee
        self.status = status
        self.line = line
        self.progress = progress
        self.comments = comments
        self.board = board
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

    var demoKey: String {
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
        guard !readOnly else { return }
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
        guard !readOnly else { return nil }
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
        guard board.active else {
            // the demo's cards, or the last data's: by id, else (a call read from the transcript) by title
            let found = item.cardId.flatMap { card($0) }
                ?? item.cardTitle.flatMap { title in cards.first { $0.title == title } }
            return found.map { (card: $0, known: true) }
        }
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
