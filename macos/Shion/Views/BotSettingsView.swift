import SwiftUI

/// An assistant's own settings page (the sidebar's right-click menu, or the chat's toolbar): its
/// name, description, model and SOUL, its MCP servers, skills and tools, and a few config values.
/// Each change goes to that one profile on the server; Settings → 助手 says what each one does.
struct BotSettingsView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var editor: BotEditor?

    var body: some View {
        Group {
            if let editor {
                BotSettingsForm(editor: editor)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(store.bot(botId)?.name ?? botId)
        .navigationSubtitle("助手设置")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.route = .chat(botId)
                } label: {
                    Label("对话", systemImage: "bubble.left.and.bubble.right")
                }
                .help("对话")
                .accessibilityIdentifier("assistant-chat")
            }
        }
        // a page of its own for each assistant, read again once connected
        .task(id: "\(botId)|\(store.live)") {
            let editor = store.live ? BotEditor(name: botId, store: store) : BotEditor(demo: store.bot(botId), id: botId)
            self.editor = editor
            editor.load()
        }
    }
}

struct BotSettingsForm: View {
    @Environment(AppStore.self) private var store
    @Bindable var editor: BotEditor
    @State private var confirmSoul = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var addingServer = false
    @State private var browsingCatalog = false
    @State private var removingServer: String?
    @State private var skillFilter = ""

    var body: some View {
        Form {
            basics
            soulSection
            serversSection
            skillsSection
            toolsetsSection
            othersSection
            removalSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addingServer) {
            NewMcpServerSheet(editor: editor)
        }
        .sheet(isPresented: $browsingCatalog) {
            McpCatalogSheet(editor: editor)
        }
    }

    // MARK: name, description, model

    private var basics: some View {
        Section {
            HStack(spacing: 12) {
                Avatar(bot: store.bot(editor.name), size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.bot(editor.name)?.name ?? editor.name).font(.t15)
                    if store.chiefId == editor.name {
                        Text("总秘书").font(.t12).foregroundStyle(.secondary)
                    }
                }
            }
            TextField("显示名", text: $editor.title, prompt: Text(verbatim: editor.name))
                .onSubmit { editor.saveBasics() }
                .accessibilityIdentifier("assistant-title")
            TextField("简介", text: $editor.description, axis: .vertical)
                .lineLimit(1...4)
                .onSubmit { editor.saveBasics() }
                .accessibilityIdentifier("assistant-description")
            if editor.basicsChanged {
                HStack(spacing: 8) {
                    Spacer()
                    Button("还原") { editor.revertBasics() }
                    Button("保存") { editor.saveBasics() }
                        .buttonStyle(.borderedProminent)
                        .disabled(editor.busy.contains("basics"))
                        .accessibilityIdentifier("assistant-basics-save")
                }
            }
            LabeledContent("模型") {
                ModelMenu(providers: editor.providers, current: editor.model, loading: editor.loading.contains(.model)) { choice in
                    if let choice {
                        editor.chooseModel(choice)
                    }
                }
                .disabled(editor.busy.contains("model"))
            }
            .alert("这个模型要你确认", isPresented: modelWarned, presenting: editor.modelWarning) { warning in
                Button("换成它") { editor.chooseModel(warning.choice, confirmed: true) }
                Button("取消", role: .cancel) {}
            } message: { warning in
                Text(warning.message)
            }
            Problem(editor.errors[.basics])
            Problem(editor.errors[.model])
        } header: {
            Text("基本")
        }
    }

    private var modelWarned: Binding<Bool> {
        Binding(
            get: { editor.modelWarning != nil },
            set: { shown in
                if !shown {
                    editor.modelWarning = nil
                }
            }
        )
    }

    // MARK: SOUL

    private var soulSection: some View {
        Section {
            TextEditor(text: $editor.soul)
                .font(.t13)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(minHeight: 160, idealHeight: 220, maxHeight: 360)
                .disabled(!editor.soulLoaded)
                .accessibilityIdentifier("assistant-soul")
            HStack(spacing: 8) {
                Problem(editor.errors[.soul])
                Spacer()
                if editor.loading.contains(.soul) || editor.busy.contains("soul") {
                    ProgressView().controlSize(.small)
                }
                Button("还原") { editor.revertSoul() }
                    .disabled(!editor.soulEdited)
                Button("保存…") { confirmSoul = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.soulEdited || editor.busy.contains("soul"))
                    .accessibilityIdentifier("assistant-soul-save")
            }
            .confirmationDialog("用改过的 SOUL 替换服务器上的？", isPresented: $confirmSoul) {
                Button("替换") { editor.saveSoul() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("服务器上原来的 SOUL 会被这一版换掉。")
            }
            .alert("服务器上的 SOUL 改过了", isPresented: $editor.soulChanged) {
                Button("覆盖", role: .destructive) { editor.saveSoul(force: true) }
                Button("用服务器上的") { editor.reloadSoul() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这一页打开以后，有人改过服务器上的 SOUL。覆盖会丢掉那一版。")
            }
        } header: {
            Text("性格（SOUL）")
        }
    }

    // MARK: MCP servers

    private var serversSection: some View {
        Section {
            ForEach(editor.servers) { server in
                McpServerRow(editor: editor, server: server) {
                    removingServer = server.name
                }
            }
            if editor.servers.isEmpty && !editor.loading.contains(.mcp) {
                Text("还没有 MCP 服务器").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Problem(editor.errors[.mcp])
                Spacer()
                Button("从目录安装…") { browsingCatalog = true }
                    .accessibilityIdentifier("mcp-catalog")
                Button("添加…") { addingServer = true }
                    .accessibilityIdentifier("mcp-add")
            }
            .confirmationDialog("删除 MCP 服务器「\(removingServer ?? "")」？", isPresented: removing) {
                Button("删除", role: .destructive) {
                    if let server = removingServer {
                        editor.removeServer(server)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这个助手的配置里不再有它。")
            }
        } header: {
            Text("MCP 服务器")
        }
    }

    private var removing: Binding<Bool> {
        Binding(
            get: { removingServer != nil },
            set: { shown in
                if !shown {
                    removingServer = nil
                }
            }
        )
    }

    // MARK: skills and tools

    private var skillsSection: some View {
        Section {
            if editor.skills.count > 8 {
                TextField("搜索技能", text: $skillFilter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("skill-filter")
            }
            ForEach(shownSkills) { skill in
                Toggle(isOn: Binding(get: { skill.enabled }, set: { editor.setSkill(skill.name, enabled: $0) })) {
                    HStack(spacing: 4) {
                        Text(skill.name)
                        if skill.locked {
                            Image(systemName: "lock.fill")
                                .font(.t11)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("已锁定")
                        }
                    }
                    if !skill.description.isEmpty {
                        Text(skill.description)
                    }
                }
                .disabled(editor.busy.contains("skill-\(skill.name)"))
                .accessibilityIdentifier("skill-\(skill.name)")
            }
            if editor.skills.isEmpty && editor.loading.contains(.skills) {
                ProgressView().controlSize(.small)
            }
            Problem(editor.errors[.skills])
        } header: {
            Text("技能")
        }
    }

    private var shownSkills: [SkillRow] {
        let filter = skillFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return editor.skills }
        return editor.skills.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.description.localizedCaseInsensitiveContains(filter)
        }
    }

    private var toolsetsSection: some View {
        Section {
            ForEach(editor.toolsets) { toolset in
                Toggle(isOn: Binding(get: { toolset.enabled }, set: { editor.setToolset(toolset.name, enabled: $0) })) {
                    HStack(spacing: 6) {
                        Text(toolset.label)
                        if toolset.enabled && !toolset.configured {
                            Text("缺少密钥").font(.t11).foregroundStyle(Palette.warm)
                        }
                    }
                    if !toolset.description.isEmpty {
                        Text(toolset.description)
                    }
                }
                .disabled(editor.busy.contains("toolset-\(toolset.name)"))
                .accessibilityIdentifier("toolset-\(toolset.name)")
            }
            if editor.toolsets.isEmpty && editor.loading.contains(.toolsets) {
                ProgressView().controlSize(.small)
            }
            Problem(editor.errors[.toolsets])
        } header: {
            Text("工具")
        }
    }

    // MARK: config

    private var othersSection: some View {
        Section {
            Picker("危险命令", selection: Binding(get: { editor.settings.approvals }, set: { editor.setApprovals($0) })) {
                Text("每次问你").tag("manual")
                Text("Hermes 先判断").tag("smart")
                Text("不问").tag("off")
            }
            .accessibilityIdentifier("assistant-approvals")
            Toggle("记忆", isOn: Binding(get: { editor.settings.memory }, set: { editor.setMemory($0) }))
                .accessibilityIdentifier("assistant-memory")
            Toggle("记住关于你的事", isOn: Binding(get: { editor.settings.userProfile }, set: { editor.setUserProfile($0) }))
                .accessibilityIdentifier("assistant-user-profile")
            Picker("每轮最多", selection: Binding(get: { editor.settings.maxTurns }, set: { editor.setMaxTurns($0) })) {
                Text("不限步数").tag(Int?.none)
                ForEach(turnChoices, id: \.self) { count in
                    Text("\(count) 步").tag(Int?.some(count))
                }
            }
            .accessibilityIdentifier("assistant-max-turns")
            Problem(editor.errors[.settings])
        } header: {
            Text("其他")
        }
        .disabled(editor.loading.contains(.settings))
    }

    /// The usual limits, and the one set now if it is another.
    private var turnChoices: [Int] {
        var counts = [30, 60, 90, 150]
        if let current = editor.settings.maxTurns, !counts.contains(current) {
            counts.append(current)
        }
        return counts.sorted()
    }

    // MARK: deleting

    private var removalSection: some View {
        Section {
            LabeledContent("profile 名", value: editor.name)
            HStack(spacing: 8) {
                Button("删除这个助手…", role: .destructive) { confirmDelete = true }
                    .disabled(!canDelete || deleting)
                    .accessibilityIdentifier("assistant-delete")
                if deleting {
                    ProgressView().controlSize(.small)
                }
            }
            .confirmationDialog("删除「\(store.bot(editor.name)?.name ?? editor.name)」？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) { delete() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("服务器上这个助手的设置、技能、记忆和对话都会删掉，不能恢复。")
            }
            Problem(deleteError)
        }
    }

    /// Not the default profile (Hermes keeps it), not 总秘书 (choose another first), not the demo.
    private var canDelete: Bool {
        guard store.live, let profile = store.roster.profile(editor.name) else { return false }
        return !profile.isDefault && editor.name != store.chiefId
    }

    private func delete() {
        deleting = true
        deleteError = nil
        let name = editor.name
        Task {
            do {
                try await store.deleteAssistant(name)
            } catch {
                deleteError = error.localizedDescription
            }
            deleting = false
        }
    }
}

/// Why part of the page did not load or save, in the alert colour; nothing when all is well.
struct Problem: View {
    let text: String?

    init(_ text: String?) {
        self.text = text
    }

    var body: some View {
        if let text {
            Text(text)
                .font(.t12)
                .foregroundStyle(Palette.alert)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The models to choose from, one submenu per provider.
struct ModelMenu: View {
    let providers: [ModelProvider]
    let current: ModelChoice?
    var loading = false
    /// The choice that leaves the model to the server or to the copied profile, where there is one.
    var noneLabel: String?
    let choose: (ModelChoice?) -> Void

    var body: some View {
        Menu {
            if let noneLabel {
                Button(noneLabel) { choose(nil) }
                Divider()
            }
            if providers.isEmpty {
                Text(loading ? "读取中…" : "没有能选的模型")
            }
            ForEach(providers) { provider in
                Menu(provider.name) {
                    ForEach(provider.models, id: \.self) { model in
                        let choice = ModelChoice(provider: provider.slug, model: model)
                        Button {
                            choose(choice)
                        } label: {
                            if choice == current {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                }
            }
        } label: {
            Text(current?.model ?? noneLabel ?? "—")
        }
        .fixedSize()
        .accessibilityIdentifier("assistant-model")
    }
}

/// One MCP server: what it connects to, whether it is on, and its test and sign-in.
struct McpServerRow: View {
    let editor: BotEditor
    let server: McpServer
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.t13)
                    Text(server.target)
                        .font(.t12)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !server.envNames.isEmpty {
                        Text("环境变量 " + server.envNames.joined(separator: "、"))
                            .font(.t11)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Toggle("启用", isOn: Binding(get: { server.enabled }, set: { editor.setServer(server.name, enabled: $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(server.fromPlugin || editor.busy.contains("mcp-\(server.name)"))
                    .accessibilityIdentifier("mcp-enabled-\(server.name)")
            }
            HStack(spacing: 8) {
                Button("测试") { editor.testServer(server.name) }
                    .disabled(editor.probes[server.name] == .running)
                    .accessibilityIdentifier("mcp-test-\(server.name)")
                if server.auth == "oauth" {
                    Button("登录…") { editor.signIn(server.name) }
                        .disabled(editor.signIns[server.name] == .waiting)
                        .accessibilityIdentifier("mcp-signin-\(server.name)")
                }
                if !server.fromPlugin {
                    Button("删除…", role: .destructive, action: remove)
                        .accessibilityIdentifier("mcp-remove-\(server.name)")
                }
                status
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mcp-\(server.name)")
    }

    @ViewBuilder
    private var status: some View {
        switch editor.signIns[server.name] {
        case .waiting?:
            Text("在浏览器里登录…").font(.t12).foregroundStyle(.secondary)
        case .done?:
            Text("登录好了").font(.t12).foregroundStyle(.secondary)
        case .failed(let reason)?:
            Text(reason).font(.t12).foregroundStyle(Palette.alert).lineLimit(2)
        case nil:
            switch editor.probes[server.name] {
            case .running?:
                ProgressView().controlSize(.small)
            case .works(let tools)?:
                Text("能用 · \(tools) 个工具").font(.t12).foregroundStyle(.secondary)
            case .failed(let reason)?:
                Text(reason).font(.t12).foregroundStyle(Palette.alert).lineLimit(2)
            case nil:
                EmptyView()
            }
        }
    }
}

/// 添加 MCP 服务器: a URL (no sign-in, OAuth, or a bearer token), or a command with its env. The
/// token and the values are typed into secure fields and sent once.
struct NewMcpServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: BotEditor
    @State private var draft = NewMcpServer()
    @State private var kind = "http"
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("名字", text: $draft.name)
                        .accessibilityIdentifier("mcp-new-name")
                    Picker("连接", selection: $kind) {
                        Text("网址").tag("http")
                        Text("命令").tag("stdio")
                    }
                    .pickerStyle(.segmented)
                    if kind == "http" {
                        TextField("网址", text: $draft.url, prompt: Text(verbatim: "https://example.dev/mcp"))
                            .accessibilityIdentifier("mcp-new-url")
                        Picker("登录", selection: $draft.auth) {
                            Text("不用").tag("none")
                            Text("OAuth").tag("oauth")
                            Text("令牌").tag("header")
                        }
                        .accessibilityIdentifier("mcp-new-auth")
                        if draft.auth == "header" {
                            SecureField("令牌", text: $draft.token)
                                .accessibilityIdentifier("mcp-new-token")
                        }
                    } else {
                        TextField("命令", text: $draft.command, prompt: Text(verbatim: "npx -y @modelcontextprotocol/server-filesystem /data"))
                            .accessibilityIdentifier("mcp-new-command")
                        ForEach($draft.env) { $pair in
                            HStack(spacing: 8) {
                                TextField("变量名", text: $pair.key)
                                SecureField("值", text: $pair.value)
                            }
                        }
                        Button("加一个环境变量") { draft.env.append(EnvPair()) }
                    }
                } header: {
                    Text("添加 MCP 服务器")
                }
            }
            .formStyle(.grouped)
            Problem(failure)
                .padding(.horizontal, 20)
            HStack {
                if sending {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || sending)
                    .accessibilityIdentifier("mcp-new-create")
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    private var ready: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if kind == "stdio" {
            return !BotEditor.words(draft.command).isEmpty
        }
        let url = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        return !url.isEmpty && (draft.auth != "header" || !draft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func add() {
        var server = draft
        if kind == "stdio" {
            server.url = ""
            server.auth = "none"
            server.token = ""
        } else {
            server.command = ""
            server.env = []
        }
        sending = true
        failure = nil
        Task {
            do {
                try await editor.addServer(server)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}

/// Hermes's MCP catalog: pick an entry, fill in the values it asks for, install it.
struct McpCatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: BotEditor
    @State private var picked: String?
    @State private var values: [String: String] = [:]
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    if editor.catalog.isEmpty {
                        Text(editor.loading.contains(.catalog) ? "读取中…" : "目录里没有东西")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(editor.catalog) { entry in
                        Button {
                            picked = entry.name
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.t13)
                                    if !entry.description.isEmpty {
                                        Text(entry.description).font(.t12).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer()
                                if entry.installed {
                                    Text("已装").font(.t12).foregroundStyle(.secondary)
                                } else if picked == entry.name {
                                    Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(entry.installed)
                        .accessibilityIdentifier("mcp-catalog-\(entry.name)")
                    }
                    Problem(editor.errors[.catalog])
                } header: {
                    Text("MCP 目录")
                }
                if let entry = pickedEntry, !entry.env.isEmpty {
                    Section {
                        ForEach(entry.env, id: \.name) { item in
                            SecureField(item.prompt.isEmpty ? item.name : item.prompt, text: value(item.name))
                        }
                    } header: {
                        Text(entry.name)
                    }
                }
            }
            .formStyle(.grouped)
            Problem(failure)
                .padding(.horizontal, 20)
            HStack {
                if sending {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("安装") { install() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pickedEntry == nil || missing || sending)
                    .accessibilityIdentifier("mcp-catalog-install")
            }
            .padding(20)
        }
        .frame(width: 480, height: 520)
        .task {
            await editor.loadCatalog()
        }
    }

    private var pickedEntry: McpCatalogEntry? {
        editor.catalog.first { $0.name == picked && !$0.installed }
    }

    /// A required value is still empty.
    private var missing: Bool {
        guard let entry = pickedEntry else { return true }
        return entry.env.contains { $0.required && (values[$0.name] ?? "").isEmpty }
    }

    private func value(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func install() {
        guard let entry = pickedEntry else { return }
        let env = values.filter { pair in entry.env.contains { $0.name == pair.key } }
        sending = true
        failure = nil
        Task {
            do {
                try await editor.install(entry, env: env)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}
