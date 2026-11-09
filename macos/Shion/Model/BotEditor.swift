import AppKit
import Foundation
import Observation

/// What an assistant's page could not get done.
nonisolated enum AssistantError: LocalizedError {
    case notSaved(String)
    case offline
    /// The profile was made; only Bot Mode's title did not go in.
    case titleNotSet(String)

    var errorDescription: String? {
        switch self {
        case .notSaved(let what): return "\(what)没有存上：服务器没有接受"
        case .offline: return "没有连上服务器"
        case .titleNotSet(let reason): return "助手建好了，但显示名没有写上（\(reason)），在它的设置页里再改一次"
        }
    }
}

/// A model and the provider that serves it.
struct ModelChoice: Hashable {
    let provider: String
    let model: String
}

/// A provider and its models, as `/api/model/options` lists them for a profile.
struct ModelProvider: Identifiable, Equatable {
    let slug: String
    let name: String
    let models: [String]

    var id: String { slug }

    init(slug: String, name: String, models: [String]) {
        self.slug = slug
        self.name = name
        self.models = models
    }

    /// A provider row; nil for one that is not signed in or lists no models.
    init?(row: JSONValue) {
        guard let slug = row["slug"]?.string, row["authenticated"]?.bool != false else { return nil }
        let models = (row["models"]?.array ?? []).compactMap { $0.string }
        guard !models.isEmpty else { return nil }
        self.slug = slug
        let name = row["name"]?.string ?? ""
        self.name = name.isEmpty ? slug : name
        self.models = models
    }

    static func list(_ reply: JSONValue) -> [ModelProvider] {
        (reply["providers"]?.array ?? []).compactMap { ModelProvider(row: $0) }
    }
}

/// A model pick the server warns about (its price, its data policy): written once you agree.
struct ModelWarning: Equatable {
    let choice: ModelChoice
    let message: String
}

/// An MCP server in a profile's config (`GET /api/mcp/servers`). Its env values never come back
/// whole, and the page shows only their names.
struct McpServer: Identifiable, Equatable {
    let name: String
    /// `http` or `stdio`.
    let transport: String
    /// The URL, or the command and its arguments.
    let target: String
    /// `oauth`, `header` (a bearer token), or empty.
    let auth: String
    let envNames: [String]
    var enabled: Bool
    /// Brought by a plugin: Hermes does not let it be changed or removed.
    let fromPlugin: Bool

    var id: String { name }

    init(name: String, transport: String, target: String, auth: String = "", envNames: [String] = [],
         enabled: Bool = true, fromPlugin: Bool = false) {
        self.name = name
        self.transport = transport
        self.target = target
        self.auth = auth
        self.envNames = envNames
        self.enabled = enabled
        self.fromPlugin = fromPlugin
    }

    init?(row: JSONValue) {
        guard let name = row["name"]?.string else { return nil }
        self.name = name
        transport = row["transport"]?.string ?? ""
        let args = (row["args"]?.array ?? []).compactMap { $0.string }
        if let url = row["url"]?.string, !url.isEmpty {
            target = url
        } else {
            target = ([row["command"]?.string ?? ""] + args).joined(separator: " ")
        }
        auth = row["auth"]?.string ?? ""
        if case .object(let env)? = row["env"] {
            envNames = env.keys.sorted()
        } else {
            envNames = []
        }
        enabled = row["enabled"]?.bool ?? true
        fromPlugin = row["source"]?.string == "plugin"
    }
}

/// What testing an MCP server found.
enum McpProbe: Equatable {
    case running
    case works(Int)
    case failed(String)
}

/// Where an MCP server's OAuth sign-in stands.
enum McpSignIn: Equatable {
    case waiting
    case done
    case failed(String)
}

/// What the 添加 MCP 服务器 sheet sends. The token and the env values go out in that one request
/// (Hermes keeps them in the profile's .env and config) and are not kept here.
struct NewMcpServer {
    var name = ""
    /// An HTTP server's URL; empty for a command.
    var url = ""
    /// A command and its arguments, as you would type them.
    var command = ""
    /// `none`, `oauth` or `header`.
    var auth = "none"
    var token = ""
    var env: [EnvPair] = []
}

/// One env variable typed into the sheet; the value only ever sits in a secure field.
struct EnvPair: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""
}

/// An entry of Hermes's MCP catalog (`GET /api/mcp/catalog`), with the env values it asks for.
struct McpCatalogEntry: Identifiable, Equatable {
    struct Env: Equatable {
        let name: String
        let prompt: String
        let required: Bool
    }

    let name: String
    let description: String
    let env: [Env]
    let installed: Bool

    var id: String { name }

    init(name: String, description: String, env: [Env] = [], installed: Bool = false) {
        self.name = name
        self.description = description
        self.env = env
        self.installed = installed
    }

    init?(row: JSONValue) {
        guard let name = row["name"]?.string else { return nil }
        self.name = name
        description = row["description"]?.string ?? ""
        env = (row["required_env"]?.array ?? []).compactMap { item -> Env? in
            guard let key = item["name"]?.string else { return nil }
            return Env(name: key, prompt: item["prompt"]?.string ?? "", required: item["required"]?.bool ?? true)
        }
        installed = row["installed"]?.bool ?? false
    }
}

/// A skill in a profile (`GET /api/skills`): on or off, and whether it is locked against the
/// assistant's own edits.
struct SkillRow: Identifiable, Equatable {
    let name: String
    let description: String
    var enabled: Bool
    let locked: Bool

    var id: String { name }

    init(name: String, description: String, enabled: Bool = true, locked: Bool = false) {
        self.name = name
        self.description = description
        self.enabled = enabled
        self.locked = locked
    }

    init?(row: JSONValue) {
        guard let name = row["name"]?.string else { return nil }
        self.name = name
        description = row["description"]?.string ?? ""
        enabled = row["enabled"]?.bool ?? true
        locked = row["locked"]?.bool ?? false
    }
}

/// A toolset the profile can turn on (`GET /api/tools/toolsets`).
struct ToolsetRow: Identifiable, Equatable {
    let name: String
    let label: String
    let description: String
    var enabled: Bool
    /// Its keys are there; without them it is on in name only.
    let configured: Bool

    var id: String { name }

    init(name: String, label: String, description: String, enabled: Bool = true, configured: Bool = true) {
        self.name = name
        self.label = label
        self.description = description
        self.enabled = enabled
        self.configured = configured
    }

    init?(row: JSONValue) {
        guard let name = row["name"]?.string else { return nil }
        self.name = name
        let label = row["label"]?.string ?? ""
        self.label = label.isEmpty ? name : label
        description = row["description"]?.string ?? ""
        enabled = row["enabled"]?.bool ?? false
        configured = row["configured"]?.bool ?? true
    }
}

/// The config values the page sets for an assistant, from its config.yaml over Hermes's defaults.
struct AgentSettings: Equatable {
    /// `approvals.mode`: manual, smart or off.
    var approvals = "smart"
    /// `memory.memory_enabled`
    var memory = true
    /// `memory.user_profile_enabled`
    var userProfile = true
    /// `agent.max_turns`; nil is no limit.
    var maxTurns: Int?

    init() {}

    /// `raw` is config.yaml as written (`include_defaults=false`, so no `${VAR}` is expanded into
    /// a key), `defaults` Hermes's own (`/api/config/defaults`).
    init(raw: JSONValue, defaults: JSONValue) {
        func value(_ section: String, _ key: String) -> JSONValue? {
            raw[section]?[key] ?? defaults[section]?[key]
        }
        approvals = Self.approvalMode(value("approvals", "mode"))
        memory = value("memory", "memory_enabled")?.bool ?? true
        userProfile = value("memory", "user_profile_enabled")?.bool ?? true
        maxTurns = Self.turns(value("agent", "max_turns"))
    }

    /// As Hermes reads it (tools/approval_context.py): YAML's bare `off` arrives as false, and a
    /// word it does not know means manual.
    static func approvalMode(_ value: JSONValue?) -> String {
        switch value {
        case .bool(let on)?: return on ? "manual" : "off"
        case .string(let word)?:
            let mode = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["manual", "smart", "off"].contains(mode) ? mode : "manual"
        default: return "smart"
        }
    }

    /// `resolve_turn_limit`: null, 0, a negative number, "none", "unlimited" or "inf" is no limit;
    /// so, here, is a count past any a turn could reach.
    static func turns(_ value: JSONValue?) -> Int? {
        switch value {
        case .number(let count)?: return count >= 1 && count <= 1_000_000_000 ? Int(count) : nil
        case .string(let word)?: return Int(word.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 >= 1 ? $0 : nil }
        default: return nil
        }
    }
}

/// The parts of an assistant's page, each read and written on its own.
enum EditorPart: Hashable {
    case basics, soul, model, mcp, catalog, skills, toolsets, settings, delete
}

/// One assistant's settings page: what its profile says, read and written part by part, every
/// call naming that profile. A demo page (no server) keeps its edits to itself.
@Observable
final class BotEditor {
    let name: String
    let demo: Bool

    var title = ""
    private(set) var savedTitle = ""
    var description = ""
    private(set) var savedDescription = ""
    var soul = ""
    private(set) var savedSoul = ""
    private(set) var soulLoaded = false
    /// The server's SOUL changed after this page read it: saving waits for your word.
    var soulChanged = false
    private(set) var model: ModelChoice?
    private(set) var providers: [ModelProvider] = []
    var modelWarning: ModelWarning?
    private(set) var servers: [McpServer] = []
    private(set) var probes: [String: McpProbe] = [:]
    private(set) var signIns: [String: McpSignIn] = [:]
    private(set) var catalog: [McpCatalogEntry] = []
    private(set) var skills: [SkillRow] = []
    private(set) var toolsets: [ToolsetRow] = []
    private(set) var settings = AgentSettings()
    private(set) var loading: Set<EditorPart> = []
    private(set) var errors: [EditorPart: String] = [:]
    /// Writes in flight, by what they write.
    private(set) var busy: Set<String> = []

    @ObservationIgnored private let store: AppStore?

    init(name: String, store: AppStore) {
        self.name = name
        self.store = store
        demo = false
        if let profile = store.roster.profile(name) {
            savedTitle = profile.title.isEmpty ? profile.displayName : profile.title
            savedDescription = profile.description
        }
        title = savedTitle
        description = savedDescription
    }

    // MARK: reading

    /// Reads every part, side by side.
    func load() {
        guard !demo else { return }
        Task { await loadModel() }
        Task { await loadSoul() }
        Task { await loadModels() }
        Task { await loadServers() }
        Task { await loadSkills() }
        Task { await loadToolsets() }
        Task { await loadSettings() }
    }

    /// The model each profile runs is in the REST list: the socket's lists only the gateway's own.
    private func loadModel() async {
        guard let api = store?.api else { return }
        loading.insert(.basics)
        defer { loading.remove(.basics) }
        do {
            let reply = try await api.get("/api/profiles")
            let row = (reply["profiles"]?.array ?? []).first { $0["name"]?.string == name }
            if let model = row?["model"]?.string, !model.isEmpty {
                self.model = ModelChoice(provider: row?["provider"]?.string ?? "", model: model)
            }
            errors[.basics] = nil
        } catch {
            errors[.basics] = error.localizedDescription
        }
    }

    private func loadSoul() async {
        guard let api = store?.api else { return }
        loading.insert(.soul)
        defer { loading.remove(.soul) }
        do {
            let reply = try await api.get(HermesAPI.profilePath(name, "/soul"))
            savedSoul = reply["content"]?.string ?? ""
            soul = savedSoul
            soulLoaded = true
            errors[.soul] = nil
        } catch {
            errors[.soul] = error.localizedDescription
        }
    }

    private func loadModels() async {
        guard let api = store?.api else { return }
        loading.insert(.model)
        defer { loading.remove(.model) }
        do {
            // a cold catalog can take the server a while
            let reply = try await api.get("/api/model/options", HermesAPI.scope(name), timeout: 60)
            providers = ModelProvider.list(reply)
            errors[.model] = nil
        } catch {
            errors[.model] = error.localizedDescription
        }
    }

    private func loadServers() async {
        guard let api = store?.api else { return }
        loading.insert(.mcp)
        defer { loading.remove(.mcp) }
        do {
            let reply = try await api.get("/api/mcp/servers", HermesAPI.scope(name))
            servers = (reply["servers"]?.array ?? []).compactMap { McpServer(row: $0) }
            errors[.mcp] = nil
        } catch {
            errors[.mcp] = error.localizedDescription
        }
    }

    func loadCatalog() async {
        if demo {
            catalog = Self.demoCatalog
            return
        }
        guard let api = store?.api else { return }
        loading.insert(.catalog)
        defer { loading.remove(.catalog) }
        do {
            let reply = try await api.get("/api/mcp/catalog", HermesAPI.scope(name))
            catalog = (reply["entries"]?.array ?? []).compactMap { McpCatalogEntry(row: $0) }
            errors[.catalog] = nil
        } catch {
            errors[.catalog] = error.localizedDescription
        }
    }

    private func loadSkills() async {
        guard let api = store?.api else { return }
        loading.insert(.skills)
        defer { loading.remove(.skills) }
        do {
            let reply = try await api.get("/api/skills", HermesAPI.scope(name))
            skills = reply.array.compactMap { SkillRow(row: $0) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            errors[.skills] = nil
        } catch {
            errors[.skills] = error.localizedDescription
        }
    }

    private func loadToolsets() async {
        guard let api = store?.api else { return }
        loading.insert(.toolsets)
        defer { loading.remove(.toolsets) }
        do {
            let reply = try await api.get("/api/tools/toolsets", HermesAPI.scope(name))
            toolsets = reply.array.compactMap { ToolsetRow(row: $0) }
            errors[.toolsets] = nil
        } catch {
            errors[.toolsets] = error.localizedDescription
        }
    }

    private func loadSettings() async {
        guard let api = store?.api else { return }
        loading.insert(.settings)
        defer { loading.remove(.settings) }
        do {
            let raw = try await api.get("/api/config", HermesAPI.scope(name) + [("include_defaults", "false")])
            let defaults = (try? await api.get("/api/config/defaults")) ?? .null
            settings = AgentSettings(raw: raw, defaults: defaults)
            errors[.settings] = nil
        } catch {
            errors[.settings] = error.localizedDescription
        }
    }

    // MARK: writing

    /// One write: busy until it settles; a refusal is kept for its part of the page.
    private func run(_ part: EditorPart, _ key: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        errors[part] = nil
        Task { @MainActor in
            do {
                try await work()
            } catch {
                self.errors[part] = error.localizedDescription
            }
            self.busy.remove(key)
        }
    }

    private var api: HermesAPI? { store?.api }

    var basicsChanged: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) != savedTitle
            || description.trimmingCharacters(in: .whitespacesAndNewlines) != savedDescription
    }

    func revertBasics() {
        title = savedTitle
        description = savedDescription
    }

    /// The description (`PUT /api/profiles/{name}/description`), then the title (Bot Mode's
    /// ui_meta, over the socket).
    func saveBasics() {
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newTitle != savedTitle || newDescription != savedDescription else { return }
        if demo {
            savedTitle = newTitle
            savedDescription = newDescription
            return
        }
        guard let store, let api else {
            errors[.basics] = AssistantError.offline.localizedDescription
            return
        }
        run(.basics, "basics") {
            if newDescription != self.savedDescription {
                try await api.request("PUT", HermesAPI.profilePath(self.name, "/description"),
                                      body: ["description": .string(newDescription)])
                self.savedDescription = newDescription
                self.description = newDescription
            }
            if newTitle != self.savedTitle {
                // reads the list again itself
                try await store.setTitle(newTitle, of: self.name)
                self.savedTitle = newTitle
                self.title = newTitle
            } else {
                await store.refreshProfiles()
            }
        }
    }

    var soulEdited: Bool { soul != savedSoul }

    /// The whole SOUL.md (`PUT /api/profiles/{name}/soul`). When the server's copy changed since
    /// this page read it, nothing is written until you say so (`force`).
    func saveSoul(force: Bool = false) {
        let text = soul
        if demo {
            savedSoul = text
            return
        }
        guard let api else {
            errors[.soul] = AssistantError.offline.localizedDescription
            return
        }
        run(.soul, "soul") {
            if !force {
                let current = try await api.get(HermesAPI.profilePath(self.name, "/soul"))["content"]?.string ?? ""
                if current != self.savedSoul {
                    self.soulChanged = true
                    return
                }
            }
            try await api.request("PUT", HermesAPI.profilePath(self.name, "/soul"), body: ["content": .string(text)])
            self.savedSoul = text
            self.soulChanged = false
        }
    }

    func revertSoul() {
        soul = savedSoul
    }

    /// The server's newer SOUL in place of the edit.
    func reloadSoul() {
        soulChanged = false
        Task { await loadSoul() }
    }

    /// `profiles.configure` with the model and its provider, as Bot Mode switches it: a pick the
    /// server warns about is written only after you agree (`confirmed`).
    func chooseModel(_ choice: ModelChoice, confirmed: Bool = false) {
        guard choice != model || confirmed else { return }
        if demo {
            model = choice
            return
        }
        guard let store, store.live else {
            errors[.model] = AssistantError.offline.localizedDescription
            return
        }
        run(.model, "model") {
            var params: [String: JSONValue] = [
                "name": .string(self.name), "model": .string(choice.model), "provider": .string(choice.provider),
            ]
            if confirmed {
                params["confirm_expensive_model"] = .bool(true)
            }
            let reply = try await store.gateway.call("profiles.configure", .object(params), timeout: 60)
            if reply["confirm_required"]?.bool == true {
                self.modelWarning = ModelWarning(choice: choice, message: reply["confirm_message"]?.string ?? "")
                return
            }
            guard reply["applied"]?["model"]?.bool == true else { throw AssistantError.notSaved("模型") }
            self.model = choice
        }
    }

    // MARK: MCP servers

    func setServer(_ server: String, enabled: Bool) {
        if demo {
            if let index = servers.firstIndex(where: { $0.name == server }) {
                servers[index].enabled = enabled
            }
            return
        }
        guard let api else { return }
        run(.mcp, "mcp-\(server)") {
            try await api.request("PUT", HermesAPI.serverPath(server, "/enabled"), HermesAPI.scope(self.name),
                                  body: ["enabled": .bool(enabled)])
            if let index = self.servers.firstIndex(where: { $0.name == server }) {
                self.servers[index].enabled = enabled
            }
        }
    }

    func removeServer(_ server: String) {
        if demo {
            servers.removeAll { $0.name == server }
            return
        }
        guard let api else { return }
        run(.mcp, "mcp-\(server)") {
            try await api.request("DELETE", HermesAPI.serverPath(server), HermesAPI.scope(self.name))
            self.servers.removeAll { $0.name == server }
            self.probes.removeValue(forKey: server)
        }
    }

    /// Hermes connects to the server, lists its tools and hangs up.
    func testServer(_ server: String) {
        if demo {
            probes[server] = .works(4)
            return
        }
        guard let api else { return }
        probes[server] = .running
        run(.mcp, "test-\(server)") {
            do {
                let reply = try await api.request("POST", HermesAPI.serverPath(server, "/test"), HermesAPI.scope(self.name),
                                                  timeout: 90)
                if reply["ok"]?.bool == true {
                    self.probes[server] = .works(reply["tools"]?.array.count ?? 0)
                } else {
                    self.probes[server] = .failed(reply["error"]?.string ?? "连不上")
                }
            } catch {
                self.probes[server] = .failed(error.localizedDescription)
            }
        }
    }

    /// OAuth: Hermes starts the flow and hands back the provider's page, which opens in your
    /// browser; the provider sends the browser back to the server, which finishes it.
    func signIn(_ server: String) {
        if demo {
            signIns[server] = .done
            return
        }
        guard let api else { return }
        signIns[server] = .waiting
        run(.mcp, "auth-\(server)") {
            do {
                var flow = try await api.request("POST", HermesAPI.serverPath(server, "/auth"), HermesAPI.scope(self.name),
                                                 timeout: 60)
                guard let id = flow["flow_id"]?.string else { throw AssistantError.notSaved("登录") }
                var opened = false
                // the server waits five minutes for the browser to come back
                for _ in 0..<160 {
                    switch flow["status"]?.string {
                    case "approved"?:
                        self.signIns[server] = .done
                        return
                    case "error"?:
                        self.signIns[server] = .failed(flow["error"]?.string ?? "没有登录成功")
                        return
                    default:
                        break
                    }
                    if !opened, let link = flow["authorization_url"]?.string, let url = URL(string: link),
                       ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        NSWorkspace.shared.open(url)
                        opened = true
                    }
                    try await Task.sleep(for: .seconds(2))
                    flow = try await api.get("/api/mcp/oauth/flows/" + KanbanClient.encode(id))
                }
                self.signIns[server] = .failed("等浏览器里的登录超时了")
            } catch {
                self.signIns[server] = .failed(error.localizedDescription)
            }
        }
    }

    /// `POST /api/mcp/servers`: a URL (with no sign-in, OAuth, or a bearer token) or a command
    /// with its env.
    func addServer(_ new: NewMcpServer) async throws {
        let serverName = new.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = new.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Self.words(new.command)
        if demo {
            let envNames = new.env.map { $0.key }.filter { !$0.isEmpty }.sorted()
            servers.removeAll { $0.name == serverName }
            servers.append(McpServer(name: serverName, transport: url.isEmpty ? "stdio" : "http",
                                     target: url.isEmpty ? words.joined(separator: " ") : url, auth: new.auth,
                                     envNames: envNames))
            return
        }
        guard let api else { throw AssistantError.offline }
        var body: [String: JSONValue] = ["name": .string(serverName)]
        if !url.isEmpty {
            body["url"] = .string(url)
            body["auth"] = .string(new.auth)
            if new.auth == "header" {
                body["bearer_token"] = .string(new.token.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            body["command"] = .string(words.first ?? "")
            body["args"] = .array(words.dropFirst().map { JSONValue.string($0) })
            var env: [String: JSONValue] = [:]
            for pair in new.env {
                let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    env[key] = .string(pair.value)
                }
            }
            body["env"] = .object(env)
        }
        let reply = try await api.request("POST", "/api/mcp/servers", HermesAPI.scope(name), body: .object(body))
        if let server = McpServer(row: reply) {
            servers.removeAll { $0.name == server.name }
            servers.append(server)
        }
        await loadServers()
    }

    /// `POST /api/mcp/catalog/install`: the entry, with the env values it declares.
    func install(_ entry: McpCatalogEntry, env: [String: String]) async throws {
        if demo {
            servers.removeAll { $0.name == entry.name }
            servers.append(McpServer(name: entry.name, transport: "stdio", target: entry.description))
            catalog = catalog.map { item in
                item.name == entry.name
                    ? McpCatalogEntry(name: item.name, description: item.description, env: item.env, installed: true)
                    : item
            }
            return
        }
        guard let api else { throw AssistantError.offline }
        let values = env.filter { !$0.value.isEmpty }.mapValues { JSONValue.string($0) }
        try await api.request("POST", "/api/mcp/catalog/install", HermesAPI.scope(name), body: [
            "name": .string(entry.name), "env": .object(values), "enable": true,
        ], timeout: 90)
        await loadServers()
        await loadCatalog()
    }

    /// A command line as you would type it: words apart by spaces, kept together in quotes.
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var started = false
        for character in line {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    word.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started || !word.isEmpty {
                    words.append(word)
                }
                word = ""
                started = false
            } else {
                word.append(character)
            }
        }
        if started || !word.isEmpty {
            words.append(word)
        }
        return words
    }

    // MARK: skills and toolsets

    func setSkill(_ skill: String, enabled: Bool) {
        if demo {
            if let index = skills.firstIndex(where: { $0.name == skill }) {
                skills[index].enabled = enabled
            }
            return
        }
        guard let api else { return }
        run(.skills, "skill-\(skill)") {
            try await api.request("PUT", "/api/skills/toggle", HermesAPI.scope(self.name),
                                  body: ["name": .string(skill), "enabled": .bool(enabled)])
            if let index = self.skills.firstIndex(where: { $0.name == skill }) {
                self.skills[index].enabled = enabled
            }
        }
    }

    func setToolset(_ toolset: String, enabled: Bool) {
        if demo {
            if let index = toolsets.firstIndex(where: { $0.name == toolset }) {
                toolsets[index].enabled = enabled
            }
            return
        }
        guard let api else { return }
        run(.toolsets, "toolset-\(toolset)") {
            try await api.request("PUT", "/api/tools/toolsets/" + KanbanClient.encode(toolset), HermesAPI.scope(self.name),
                                  body: ["enabled": .bool(enabled)])
            if let index = self.toolsets.firstIndex(where: { $0.name == toolset }) {
                self.toolsets[index].enabled = enabled
            }
        }
    }

    // MARK: config

    func setApprovals(_ mode: String) {
        var change = settings
        change.approvals = mode
        save(change, key: "approvals", ["approvals": ["mode": .string(mode)]])
    }

    func setMemory(_ on: Bool) {
        var change = settings
        change.memory = on
        save(change, key: "memory", ["memory": ["memory_enabled": .bool(on)]])
    }

    func setUserProfile(_ on: Bool) {
        var change = settings
        change.userProfile = on
        save(change, key: "user-profile", ["memory": ["user_profile_enabled": .bool(on)]])
    }

    func setMaxTurns(_ turns: Int?) {
        var change = settings
        change.maxTurns = turns
        let value: JSONValue = turns.map { JSONValue.number(Double($0)) } ?? .null
        save(change, key: "max-turns", ["agent": ["max_turns": value]])
    }

    /// `PUT /api/config` with only the value that changed (Hermes merges it into config.yaml).
    /// Shown at once; put back if the server says no.
    private func save(_ change: AgentSettings, key: String, _ config: JSONValue) {
        guard change != settings, !busy.contains("setting-\(key)") else { return }
        if demo {
            settings = change
            return
        }
        guard let api else { return }
        let before = settings
        settings = change
        run(.settings, "setting-\(key)") {
            do {
                try await api.request("PUT", "/api/config", HermesAPI.scope(self.name), body: ["config": config])
            } catch {
                self.settings = before
                throw error
            }
        }
    }

    // MARK: the demo

    /// A page with no server behind it, filled in for the demo assistant.
    init(demo bot: Bot?, id: String) {
        name = id
        store = nil
        demo = true
        savedTitle = bot?.name ?? id
        title = savedTitle
        let chief = bot?.chief ?? false
        savedDescription = chief ? "统筹学习、工作和生活里的事，拆开派给各个助手，到时间提醒你" : (bot?.title ?? "")
        description = savedDescription
        let shown = bot?.name ?? id
        savedSoul = chief
            ? """
            # 詩音

            你是詩音，用户的私人秘书。你带着一组助手：课程、通勤、邮件、资讯和回顾。

            - 把用户交代的事拆开，在看板上交给对应的助手，再在对话里说交给了谁。
            - 说话简短、温和，先说结论。
            - 日期和截止时间先问用户，再写进待办。
            - 自己不做长任务。
            """
            : """
            # \(shown)

            你是詩音手下负责「\(savedDescription)」的助手。詩音在看板上把事交给你，做完写清结果，卡住了说明在等什么。
            """
        soul = savedSoul
        soulLoaded = true
        model = ModelChoice(provider: "nous", model: "Hermes-4-405B")
        providers = [
            ModelProvider(slug: "nous", name: "Nous Portal", models: ["Hermes-4-405B", "Hermes-4-70B"]),
            ModelProvider(slug: "openrouter", name: "OpenRouter",
                          models: ["anthropic/claude-sonnet-4.5", "google/gemini-3-pro", "openai/gpt-5.1"]),
        ]
        servers = [
            McpServer(name: "notion", transport: "http", target: "https://mcp.notion.com/mcp", auth: "oauth"),
            McpServer(name: "apple-calendar", transport: "stdio", target: "npx -y caldav-mcp",
                      envNames: ["CALDAV_PASSWORD", "CALDAV_USERNAME"]),
            McpServer(name: "moodle", transport: "http", target: "https://moodle.example/mcp", auth: "header", enabled: false),
        ]
        probes = ["notion": .works(12)]
        skills = [
            SkillRow(name: "arxiv", description: "搜索和总结论文", enabled: false),
            SkillRow(name: "email-inbox-triage", description: "整理收件箱，挑出要你回的"),
            SkillRow(name: "himalaya", description: "用 IMAP 和 SMTP 收发邮件"),
            SkillRow(name: "meeting-action-items", description: "从会议记录里列出要做的事"),
            SkillRow(name: "obsidian", description: "读写 Obsidian 笔记", locked: true),
            SkillRow(name: "weekly-review-planning", description: "每周回顾和下周计划"),
        ]
        toolsets = [
            ToolsetRow(name: "kanban", label: "看板", description: "建卡、交给助手、跟进进度"),
            ToolsetRow(name: "memory", label: "记忆", description: "记下和想起长期的事"),
            ToolsetRow(name: "web", label: "网页", description: "搜索和阅读网页"),
            ToolsetRow(name: "browser", label: "浏览器", description: "在云桌面上操作网页", enabled: false),
            ToolsetRow(name: "terminal", label: "终端", description: "在服务器上运行命令", enabled: false),
        ]
    }

    private static let demoCatalog = [
        McpCatalogEntry(name: "github", description: "仓库、议题和拉取请求",
                        env: [McpCatalogEntry.Env(name: "GITHUB_TOKEN", prompt: "GitHub 令牌", required: true)]),
        McpCatalogEntry(name: "notion", description: "Notion 的页面和数据库", installed: true),
    ]
}
