import Foundation

/// Today, todos and reports from the server's `shion` plugin: `plugin.shion.*` over the gateway
/// socket, as hermes-plugin/README.md describes. Without the plugin these pages keep their demo
/// data. The assistants read and write the same store through the plugin's tools.
extension AppStore {
    private static let allTopics = ["todos", "today", "reports", "usage"]

    /// Asks the plugin for its state; when it answers, today, todos and reports come from it.
    /// `sync.state` also starts the plugin's pushes (`plugin.shion.changed`).
    func loadPluginData() async {
        guard live, serverCapabilities.contains("plugin-rpc-v1"),
              let state = try? await pluginCall("sync.state")  // -32601: not installed in that profile
        else { return }
        if !pluginData {
            demoTodos = todos
            demoReports = reports
            pluginData = true
        }
        pluginRevision = state["revision"]?.int ?? 0
        await reloadPlugin(Self.allTopics)
        startPluginRefresh()
    }

    /// After a reconnect: what changed while away, since pushes are not replayed.
    func syncPluginData() async {
        guard pluginData, let state = try? await pluginCall("sync.state") else { return }
        if state["revision"]?.int != pluginRevision {
            await catchUpPlugin()
        }
    }

    func stopPluginData() {
        pluginRefresh?.cancel()
        pluginRefresh = nil
        guard pluginData else { return }
        pluginData = false
        todos = demoTodos
        reports = demoReports
        forgetReports()
        ScreenTime.shared.forget()
        todaySummary = nil
        pluginRevision = 0
    }

    /// `plugin.shion.changed`: the store moved on; fetch only what changed.
    func pluginChanged(_ payload: JSONValue) {
        guard pluginData, let revision = payload["revision"]?.int, revision > pluginRevision else { return }
        pluginRevision = revision
        let topics = payload["reset"]?.bool == true
            ? Self.allTopics
            : (payload["topics"]?.array ?? []).compactMap { $0.string }
        Task { await reloadPlugin(topics) }
    }

    private func catchUpPlugin() async {
        guard pluginData,
              let changes = try? await pluginCall("changes.since", ["revision": .number(Double(pluginRevision))])
        else { return }
        pluginRevision = changes["revision"]?.int ?? pluginRevision
        let topics = changes["reset"]?.bool == true
            ? Self.allTopics
            : (changes["topics"]?.array ?? []).compactMap { $0.string }
        await reloadPlugin(topics)
    }

    /// Every five minutes, in case a push was lost.
    private func startPluginRefresh() {
        pluginRefresh?.cancel()
        pluginRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await self?.catchUpPlugin()
            }
        }
    }

    private func reloadPlugin(_ topics: [String]) async {
        if topics.contains("todos") { await reloadTodos() }
        if topics.contains("today") { await reloadToday() }
        if topics.contains("reports") { await reloadReports() }
        // the days of screen time on screen are read again (ScreenTime.swift)
        if topics.contains("usage") { ScreenTime.shared.changed() }
    }

    /// Everything open, and the latest done ones.
    private func reloadTodos() async {
        guard let open = try? await pluginCall("todos.list", ["status": "open", "limit": 1000]),
              let done = try? await pluginCall("todos.list", ["status": "done", "limit": 100]),
              pluginData
        else { return }
        todos = ((open["todos"]?.array ?? []) + (done["todos"]?.array ?? [])).compactMap(pluginTodo(from:))
    }

    private func reloadToday() async {
        guard let reply = try? await pluginCall("today.get"), pluginData else { return }
        let text = reply["summary"]?["text"]?.string ?? ""
        todaySummary = text.isEmpty ? nil : text
    }

    /// The newest report of each kind, with its blocks (the list leaves them out).
    private func reloadReports() async {
        guard let list = try? await pluginCall("reports.list", ["limit": 60]) else { return }
        var newest: [String: (date: String, kind: String)] = [:]
        for row in list["reports"]?.array ?? [] {
            guard let kind = row["kind"]?.string, let date = row["date"]?.string, newest[kind] == nil else { continue }
            newest[kind] = (date, kind)
        }
        var loaded: [Report] = []
        for (date, kind) in newest.values {
            guard let reply = try? await pluginCall("reports.get", ["date": .string(date), "kind": .string(kind)]),
                  let report = pluginReport(from: reply["report"])
            else { continue }
            loaded.append(report)
        }
        guard pluginData else { return }
        // one written since Shion connected is a notification (AppStore+Notices.swift)
        noticeReports(loaded)
        reports = loaded.sorted { $0.date > $1.date }
    }

    /// One report by its day and kind: a notification's, when it is no longer the newest of its
    /// kind (Landing.swift).
    func fetchReport(day: String, kind: ReportKind) async -> Report? {
        guard pluginData,
              let reply = try? await pluginCall("reports.get", ["date": .string(day), "kind": .string(kind.rawValue)])
        else { return nil }
        return pluginReport(from: reply["report"])
    }

    /// One day's app use as the plugin adds it up, for the screen time under a report
    /// (ScreenTime.swift). Nil without the plugin, or where it has no `usage.day`.
    func fetchUsage(day: String) async -> UsageDay? {
        guard pluginData, let reply = try? await pluginCall("usage.day", ["date": .string(day)]), pluginData else { return nil }
        return UsageDay(reply, day: day)
    }

    // MARK: writes, shown at once and confirmed by the push that follows

    func pluginToggle(_ id: String) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].done.toggle()
        todos[index].proposed = false
        pluginWrite("todos.update", ["id": .string(id), "done": .bool(todos[index].done)])
    }

    func pluginConfirm(_ id: String) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].proposed = false
        pluginWrite("todos.update", ["id": .string(id), "proposed": false])
    }

    /// Shion names the todo itself, so sending it again after a dropped connection is safe.
    func pluginAdd(_ title: String) {
        let id = "mac_" + UUID().uuidString.lowercased()
        let at = Date()
        todos.append(Todo(id: id, title: title, area: .life, source: "你自己加的", doAt: at))
        pluginWrite("todos.add", [
            "id": .string(id), "title": .string(title), "area": "life", "do_at": .string(Self.isoTime(at)),
        ])
    }

    /// On a refusal the server's list replaces what was shown.
    private func pluginWrite(_ method: String, _ params: [String: JSONValue]) {
        Task {
            do {
                _ = try await pluginCall(method, params)
            } catch {
                await reloadTodos()
            }
        }
    }

    /// Every call names 詩音's profile: the plugin is installed in the assistants' profiles, not
    /// necessarily in the one the connection is bound to, and they all share one store.
    private func pluginCall(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        var fields = params
        fields["profile"] = .string(chiefId)
        return try await gateway.call("plugin.shion." + method, .object(fields))
    }

    // MARK: the plugin's rows

    private func pluginTodo(from row: JSONValue) -> Todo? {
        guard let id = row["id"]?.string, let title = row["title"]?.string else { return nil }
        let source = row["source"]?.string ?? ""
        let detail = row["source_detail"]?.string ?? ""
        return Todo(
            id: id,
            title: title,
            area: Area(rawValue: row["area"]?.string ?? "") ?? .life,
            // where it came from when the plugin knows, else who added it
            source: !detail.isEmpty ? detail : (bot(source).map { "\($0.name) 加的" } ?? source),
            doAt: Self.parseTime(row["do_at"]),
            dueAt: Self.parseTime(row["due_at"]),
            done: row["done"]?.bool ?? false,
            nudges: row["nudges"]?.int ?? 0,
            proposed: row["proposed"]?.bool ?? false
        )
    }

    private func pluginReport(from row: JSONValue?) -> Report? {
        guard let row, let day = row["date"]?.string,
              let kind = ReportKind(rawValue: row["kind"]?.string ?? "")
        else { return nil }
        let blocks = (row["blocks"]?.array ?? []).map { block in
            ReportBlock(heading: block["heading"]?.string ?? "", items: (block["items"]?.array ?? []).compactMap { $0.string })
        }
        return Report(
            id: row["id"]?.string ?? "\(day)-\(kind.rawValue)",
            kind: kind,
            botId: row["author"]?.string ?? "",
            date: Self.parseTime(row["updated_at"]) ?? Date(),
            headline: row["headline"]?.string ?? "",
            blocks: blocks
        )
    }

    /// ISO 8601 with an offset, as the plugin writes and expects them.
    private static func parseTime(_ value: JSONValue?) -> Date? {
        guard let text = value?.string, !text.isEmpty else { return nil }
        return isoFormatter.date(from: text)
    }

    private static func isoTime(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
