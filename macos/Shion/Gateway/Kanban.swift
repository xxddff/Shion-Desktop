import Foundation

/// What the kanban plugin refused, with its own `detail` (Hermes answers 400 for a status it will
/// not set, 409 for a move the board does not allow, naming the open parents).
nonisolated enum KanbanError: LocalizedError {
    case refused(Int, String)

    var status: Int {
        switch self {
        case .refused(let status, _): return status
        }
    }

    var detail: String {
        switch self {
        case .refused(_, let detail): return detail
        }
    }

    var errorDescription: String? {
        switch self {
        case .refused(let status, let detail):
            return detail.isEmpty ? "服务器返回 HTTP \(status)" : "\(detail)（HTTP \(status)）"
        }
    }
}

/// The Hermes kanban plugin, mounted at `/api/plugins/kanban`: REST routes signed as `/api/*` is
/// (the session token as X-Hermes-Session-Token, a sign-in as a bearer, plus the Cloudflare Access
/// headers), and the `/events` socket, whose upgrade only reads the credential from `?token=`.
/// Every route takes `?board=<slug>`; without it the server's current board is meant.
final class KanbanClient {
    typealias Signer = (_ settings: ServerSettings, _ renew: Bool) async throws -> Credential

    static let prefix = "/api/plugins/kanban"

    let settings: ServerSettings
    private let credential: Signer

    init(settings: ServerSettings, credential: @escaping Signer) {
        self.settings = settings
        self.credential = credential
    }

    /// `query`: more parameters than the board, as `include_archived`.
    func get(_ path: String, board: String? = nil, query: [(String, String)] = []) async throws -> JSONValue {
        try await request("GET", path, board: board, query: query)
    }

    /// One call; a 401 renews the credential once and tries again.
    @discardableResult
    func request(_ method: String, _ path: String, board: String? = nil, query: [(String, String)] = [],
                 body: JSONValue = .null) async throws -> JSONValue {
        var renew = false
        while true {
            guard let url = url(path, board: board, query: query) else { throw GatewayError.notConfigured }
            let signed = try await credential(settings, renew)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 15
            settings.applyAccessHeaders(to: &request)
            signed.sign(&request)
            if !body.isNull {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(try body.serialized().utf8)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            try ServerSettings.checkAccess(response)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(decoding: data, as: UTF8.self)
            if status == 401 && !renew {
                renew = true
                continue
            }
            guard (200..<300).contains(status) else {
                let detail = (try? JSONValue.parse(text))?["detail"]?.string ?? ""
                throw KanbanError.refused(status, detail)
            }
            return text.isEmpty ? .null : try JSONValue.parse(text)
        }
    }

    /// `wss://…/api/plugins/kanban/events?board=&since=&token=`, not yet resumed. Frames are
    /// `{"events": [...], "cursor": N}`; a refused credential closes it with 1008.
    func eventSocket(board: String?, since: Int, renew: Bool) async throws -> URLSessionWebSocketTask {
        let signed = try await credential(settings, renew)
        guard let base = settings.base,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw GatewayError.notConfigured }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path += Self.prefix + "/events"
        var items: [(String, String)] = []
        if let board {
            items.append(("board", board))
        }
        items.append(("since", String(since)))
        if !signed.token.isEmpty {
            items.append(("token", signed.token))
        }
        components.percentEncodedQuery = Self.query(items)
        guard let url = components.url else { throw GatewayError.notConfigured }
        var request = URLRequest(url: url)
        settings.applyAccessHeaders(to: &request)
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 16 * 1024 * 1024
        return socket
    }

    private func url(_ path: String, board: String?, query more: [(String, String)] = []) -> URL? {
        let query = Self.query((board.map { [("board", $0)] } ?? []) + more)
        return settings.httpURL(Self.prefix + path + (query.isEmpty ? "" : "?" + query))
    }

    private static func query(_ items: [(String, String)]) -> String {
        items.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
    }

    /// Unreserved characters only: URLQueryItem leaves "+" alone, which a server reads as a space.
    static func encode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - what the board says

/// One column of the board (`GET /workflow`): its stable key, the server's label, and whether a
/// card may be dragged into it (`running`, `review` and `scheduled` are reached otherwise).
struct KanbanColumn: Hashable {
    let key: String
    let label: String
    let dragTarget: Bool
}

/// The columns in board order and the manual moves a person may ask for (`src → [dst]`).
/// Archiving is always allowed and not listed.
struct KanbanWorkflow: Equatable {
    var columns: [KanbanColumn]
    var manual: [String: Set<String>]

    static let archived = "archived"

    /// `hermes_cli/kanban_workflow.py`'s DEFAULT_WORKFLOW, for a server that does not answer.
    static let standard = KanbanWorkflow(
        columns: [
            KanbanColumn(key: "triage", label: "Triage", dragTarget: true),
            KanbanColumn(key: "todo", label: "Todo", dragTarget: true),
            KanbanColumn(key: "scheduled", label: "Scheduled", dragTarget: false),
            KanbanColumn(key: "ready", label: "Ready", dragTarget: true),
            KanbanColumn(key: "running", label: "Running", dragTarget: false),
            KanbanColumn(key: "blocked", label: "Blocked", dragTarget: true),
            KanbanColumn(key: "review", label: "Review", dragTarget: false),
            KanbanColumn(key: "done", label: "Done", dragTarget: true),
        ],
        manual: [
            "triage": ["todo", "ready"],
            "todo": ["triage", "scheduled", "ready"],
            "scheduled": ["triage", "todo", "ready"],
            "ready": ["triage", "todo", "scheduled", "blocked", "review", "done"],
            "running": ["triage", "todo", "scheduled", "ready", "blocked", "review", "done"],
            "blocked": ["triage", "todo", "scheduled", "ready", "done"],
            "review": ["triage", "todo", "ready", "done"],
            "done": ["triage", "todo", "ready"],
            "archived": ["triage", "todo", "ready"],
        ]
    )

    init(columns: [KanbanColumn], manual: [String: Set<String>]) {
        self.columns = columns
        self.manual = manual
    }

    init?(_ reply: JSONValue) {
        let columns = (reply["columns"]?.array ?? []).compactMap { row -> KanbanColumn? in
            guard let key = row["key"]?.string else { return nil }
            return KanbanColumn(key: key, label: row["label"]?.string ?? key, dragTarget: row["drag_target"]?.bool ?? true)
        }
        guard !columns.isEmpty, case .object(let table)? = reply["manual"] else { return nil }
        self.columns = columns
        manual = table.mapValues { Set($0.array.compactMap { $0.string }) }
    }

    func column(_ key: String) -> KanbanColumn? { columns.first { $0.key == key } }

    /// Whether a person may move a card from `src` to `dst`, as the server's own check.
    func canMove(_ src: String, to dst: String) -> Bool {
        guard src != dst else { return false }
        if dst == Self.archived { return true }
        return manual[src]?.contains(dst) ?? false
    }

    /// Where a card can be dragged or sent from `src`, in board order, archiving last.
    func targets(from src: String) -> [String] {
        columns.filter { $0.dragTarget && canMove(src, to: $0.key) }.map(\.key) + (src == Self.archived ? [] : [Self.archived])
    }
}

/// A board on the server (`GET /boards`), with how many of its cards are in each status.
struct KanbanBoardInfo: Identifiable, Hashable {
    let slug: String
    let name: String
    let isCurrent: Bool
    let counts: [String: Int]

    var id: String { slug }

    init?(_ row: JSONValue) {
        guard let slug = row["slug"]?.string else { return nil }
        self.slug = slug
        let name = row["name"]?.string ?? ""
        self.name = name.isEmpty ? slug : name
        isCurrent = row["is_current"]?.bool ?? false
        var counts: [String: Int] = [:]
        if case .object(let table)? = row["counts"] {
            for (status, count) in table {
                counts[status] = count.int ?? 0
            }
        }
        self.counts = counts
    }
}

/// A card as `GET /board` lists it.
struct KanbanTask: Identifiable, Hashable {
    let id: String
    var title: String
    var body: String?
    var assignee: String?
    var status: String
    var priority: Int
    var createdBy: String?
    var createdAt: Date?
    var startedAt: Date?
    var completedAt: Date?
    /// The current run's start (`startedAt` is the first run's).
    var runStartedAt: Date?
    var result: String?
    /// dependency, needs_input, capability or transient; nil on old cards and on blocks that did
    /// not say. Hermes keeps it (and `blockRecurrences`) across an unblock; only done clears it.
    var blockKind: String?
    /// How many times in a row the card stopped for `blockKind`: the same kind again after an
    /// unblock, at BLOCK_RECURRENCE_LIMIT, sends the card to triage instead of blocked.
    var blockRecurrences = 0
    /// The worker's last heartbeat in the current run.
    var lastHeartbeatAt: Date?
    /// The newest run's handoff, cut to 200 characters on the board.
    var latestSummary: String?
    var parents = 0
    var children = 0
    var comments = 0
    /// Children done of all children, for a card that has any.
    var progress: (done: Int, total: Int)?

    init?(_ row: JSONValue) {
        guard let id = row["id"]?.string, let status = row["status"]?.string else { return nil }
        self.id = id
        self.status = status
        title = row["title"]?.string ?? id
        body = Self.text(row["body"])
        assignee = Self.text(row["assignee"])
        priority = row["priority"]?.int ?? 0
        createdBy = Self.text(row["created_by"])
        createdAt = Self.date(row["created_at"])
        startedAt = Self.date(row["started_at"])
        completedAt = Self.date(row["completed_at"])
        runStartedAt = Self.date(row["current_run_started_at"])
        result = Self.text(row["result"])
        blockKind = Self.text(row["block_kind"])
        blockRecurrences = row["block_recurrences"]?.int ?? 0
        lastHeartbeatAt = Self.date(row["last_heartbeat_at"])
        latestSummary = Self.text(row["latest_summary"])
        parents = row["link_counts"]?["parents"]?.int ?? 0
        children = row["link_counts"]?["children"]?.int ?? 0
        comments = row["comment_count"]?.int ?? 0
        if let total = row["progress"]?["total"]?.int, total > 0 {
            progress = (row["progress"]?["done"]?.int ?? 0, total)
        }
    }

    static func == (a: KanbanTask, b: KanbanTask) -> Bool {
        a.id == b.id && a.title == b.title && a.body == b.body && a.assignee == b.assignee && a.status == b.status
            && a.priority == b.priority && a.runStartedAt == b.runStartedAt && a.result == b.result
            && a.blockKind == b.blockKind && a.blockRecurrences == b.blockRecurrences
            && a.startedAt == b.startedAt && a.completedAt == b.completedAt && a.lastHeartbeatAt == b.lastHeartbeatAt
            && a.latestSummary == b.latestSummary && a.parents == b.parents
            && a.children == b.children && a.comments == b.comments
            && a.progress?.done == b.progress?.done && a.progress?.total == b.progress?.total
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(status)
    }

    /// Text that is there: nil for null and for "".
    static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.string, !text.isEmpty else { return nil }
        return text
    }

    /// Unix seconds.
    static func date(_ value: JSONValue?) -> Date? {
        value?.number.map { Date(timeIntervalSince1970: $0) }
    }
}

struct KanbanComment: Identifiable, Equatable {
    let id: String
    let author: String
    let body: String
    let at: Date?
}

/// One attempt at a card (`task_runs`): opened on claim, closed on complete, block, crash,
/// timeout or reclaim.
struct KanbanRun: Identifiable, Equatable {
    let id: String
    let profile: String?
    let outcome: String?
    let startedAt: Date?
    let endedAt: Date?
    let summary: String?
    let error: String?
}

/// A card at the other end of a dependency.
struct KanbanLink: Identifiable, Equatable {
    let id: String
    let title: String
    let status: String
}

/// The newest event that stopped a card for someone: a block (`blocked`), the loop breaker's
/// move to triage after the same block came back (`block_loop_detected`), or the failure
/// breaker's after the worker kept failing (`gave_up`, with its error for a reason).
struct KanbanStop: Equatable {
    let id: Int
    /// The event's kind.
    let event: String
    /// The block's kind as the worker gave it (needs_input, capability, transient), nil when it
    /// gave none; nil for gave_up.
    let blockKind: String?
    let reason: String?
    let at: Date?

    static let events: Set<String> = ["blocked", "block_loop_detected", "gave_up"]
}

/// `GET /tasks/{id}`: what the board leaves out. A block's reason lives only in its event.
struct KanbanDetail: Equatable {
    var body: String?
    var summary: String?
    var result: String?
    var comments: [KanbanComment] = []
    var runs: [KanbanRun] = []
    var parents: [KanbanLink] = []
    var children: [KanbanLink] = []
    var blockReason: String?
    var scheduleReason: String?
    /// What stopped the card last; the card's own `block_kind` may be left from an earlier block.
    var stop: KanbanStop?

    init(_ reply: JSONValue) {
        let task = reply["task"]
        body = KanbanTask.text(task?["body"])
        summary = KanbanTask.text(task?["latest_summary"])
        result = KanbanTask.text(task?["result"])
        comments = (reply["comments"]?.array ?? []).compactMap { row in
            guard let body = row["body"]?.string else { return nil }
            return KanbanComment(
                id: row["id"]?.int.map { String($0) } ?? UUID().uuidString,
                author: row["author"]?.string ?? "",
                body: body,
                at: KanbanTask.date(row["created_at"])
            )
        }
        runs = (reply["runs"]?.array ?? []).map { row in
            KanbanRun(
                id: row["id"]?.int.map { String($0) } ?? UUID().uuidString,
                profile: KanbanTask.text(row["profile"]),
                outcome: KanbanTask.text(row["outcome"]),
                startedAt: KanbanTask.date(row["started_at"]),
                endedAt: KanbanTask.date(row["ended_at"]),
                summary: KanbanTask.text(row["summary"]),
                error: KanbanTask.text(row["error"])
            )
        }
        var known: [String: KanbanLink] = [:]
        for row in reply["link_tasks"]?.array ?? [] {
            guard let id = row["id"]?.string else { continue }
            known[id] = KanbanLink(id: id, title: row["title"]?.string ?? id, status: row["status"]?.string ?? "")
        }
        func links(_ key: String) -> [KanbanLink] {
            (reply["links"]?[key]?.array ?? []).compactMap { $0.string }.map { known[$0] ?? KanbanLink(id: $0, title: $0, status: "") }
        }
        parents = links("parents")
        children = links("children")
        let events = reply["events"]?.array ?? []
        blockReason = events.last { $0["kind"]?.string == "blocked" }.flatMap { KanbanTask.text($0["payload"]?["reason"]) }
        scheduleReason = events.last { $0["kind"]?.string == "scheduled" }.flatMap { KanbanTask.text($0["payload"]?["reason"]) }
        stop = events.last { KanbanStop.events.contains($0["kind"]?.string ?? "") }.map { row in
            let event = row["kind"]?.string ?? ""
            return KanbanStop(
                id: row["id"]?.int ?? 0,
                event: event,
                blockKind: event == "gave_up" ? nil : KanbanTask.text(row["payload"]?["kind"]),
                reason: KanbanTask.text(row["payload"]?["reason"]) ?? KanbanTask.text(row["payload"]?["error"]),
                at: KanbanTask.date(row["created_at"])
            )
        }
    }
}
