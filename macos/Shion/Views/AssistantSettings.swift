import SwiftUI

/// The Settings window: the server, the assistants on it, and the keys (ShortcutSettings.swift).
struct SettingsTabs: View {
    var body: some View {
        TabView {
            Tab("服务器", systemImage: "network") {
                SettingsView()
            }
            Tab("助手", systemImage: "person.2") {
                AssistantSettings()
            }
            Tab("快捷键", systemImage: "keyboard") {
                ShortcutSettings()
            }
        }
    }
}

/// Settings → 助手: who leads, who Shion shows, new assistants, and what each assistant's own
/// page changes. The choices are kept on this Mac, per server.
struct AssistantSettings: View {
    @Environment(AppStore.self) private var store
    @State private var composing = false

    var body: some View {
        let listed = store.live && !store.roster.profiles.isEmpty
        Form {
            Section {
                if listed {
                    Picker("总秘书", selection: Binding(get: { store.chiefId }, set: { store.chooseChief($0) })) {
                        ForEach(store.roster.profiles) { profile in
                            Text(profile.shownName).tag(profile.name)
                        }
                    }
                    .accessibilityIdentifier("chief-picker")
                } else {
                    LabeledContent("总秘书", value: store.live ? "服务器没有列出助手" : "连上服务器后可以选")
                }
            } header: {
                Text("总秘书")
            } footer: {
                Text(Self.chiefNote)
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }

            if listed {
                Section {
                    ForEach(store.roster.profiles) { profile in
                        Toggle(isOn: Binding(get: { !store.roster.isHidden(profile.name) },
                                             set: { store.setShown(profile.name, $0) })) {
                            Text(profile.shownName)
                            Text(profile.isDefault ? "\(profile.name) · Hermes 的默认 profile" : profile.name)
                        }
                        .disabled(profile.name == store.chiefId)
                        .accessibilityIdentifier("show-\(profile.name)")
                    }
                    HStack {
                        Spacer()
                        Button("新建助手…") { composing = true }
                            .accessibilityIdentifier("new-assistant")
                    }
                } header: {
                    Text("在 Shion 里显示")
                } footer: {
                    Text(Self.showNote)
                        .font(.t12)
                        .foregroundStyle(.secondary)
                }
            }

            if listed && !store.roster.cleaning.isEmpty {
                Section {
                    ForEach(store.roster.cleaning.keys.sorted(), id: \.self) { name in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                Text(store.roster.cleaning[name] ?? "")
                                    .font(.t12)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("已经清理好了") { store.cleaned(name) }
                                .accessibilityIdentifier("cleaned-\(name)")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("cleaning-\(name)")
                    }
                } header: {
                    Text("还在清理")
                } footer: {
                    Text(Self.cleaningNote)
                        .font(.t12)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("打开", value: "侧栏里右键一个助手，或对话页顶部的按钮")
            } header: {
                Text("每个助手的设置")
            } footer: {
                Text(Self.pageNote)
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .sheet(isPresented: $composing) {
            NewAssistantSheet()
        }
    }

    static let chiefNote = "总秘书写今天页顶部那段话；「跟…说」的按钮、今天页的输入框、⌥Space 的小窗、⌘K 和菜单栏找的都是总秘书，用这个助手的名字和头像；专注检查也发给总秘书，shion 插件在总秘书的 profile 里调用。换成没装 shion 插件的助手，今天、待办和日报会回到示例数据。没选过时，名叫 shion 的 profile 当总秘书，没有就是 Hermes 的默认 profile。"

    static let showNote = "不显示的助手不在侧栏里，Shion 也不接它的对话，所以它的批准和提问不会到「等你确认」；它在服务器上照常运行，看板上派给它的卡照样显示。总秘书总是显示。Hermes 的默认 profile 删不掉，不用的话可以不显示。这台 Mac 第一次见到一个助手时，照官方桌面端 Bot Mode 的设置（ui_meta 里的 hidden）决定显示不显示；之后以这里的选择为准，Bot Mode 那边再改也不跟着变。这些选择按服务器地址存在这台 Mac 上。新建助手：名字是 profile 的 id，只能用小写字母、数字、- 和 _；显示名随便取。不复制的话，新助手带着 Hermes 自带的技能，用服务器上的密钥和模型；复制的话，带上那个助手的模型、密钥、技能、插件、MCP 服务器和记忆，不带它的消息渠道。新助手的 Bot Chat 在第一次打开对话时才建。"

    static let cleaningNote = "删掉的助手，服务器没能当场清掉这个名字的会话和路由记录（Hermes 回了 settlement_pending）。这时候用同一个名字新建，新助手会接上旧的记录，所以清理完之前同名的新建先拦住。Shion 连着服务器时会替你重试 Hermes 给的那条命令（经 cli.exec 在服务器上运行，先 5 秒一次，越往后越慢），成功了就自动放行；一直不成功的话（比如 gateway 是旧版本），在服务器上重启 gateway 后运行上面的命令，再点「已经清理好了」。"

    static let pageNote = "那一页只改这一个 profile，每一项都直接写到服务器上。显示名、头像的形状和颜色写进 profile 的 ui_meta（和官方桌面端的 Bot Mode 同一处，写之前比对版本号，别处先改了就重读再写），头像图片存成那个 profile 的 avatar（PNG，最长边 512 像素）；Bot Mode 的表情和花纹形状在这里画成圆形。简介写进 profile.yaml。SOUL 保存时整篇替换，保存前会问你；这一页打开后服务器上的 SOUL 被改过的话，先问要不要覆盖。换模型时，服务器认为太贵或者数据政策有问题的，先问你。模型和工具在 Bot Chat 的下一轮就用上；SOUL、MCP 服务器和技能，等 Hermes 重新载入这个助手（比如 gateway 重启）后生效。MCP 服务器的令牌和环境变量只在输入时发给服务器一次（Hermes 存进那个 profile 的 .env，config.yaml 里只留引用），Shion 不显示、不保存，也不从服务器取回，列表里只有变量名。编辑一个已有的服务器：改网址、命令和参数时只改这几项，原来的令牌和环境变量不动；令牌和变量的值不填就保留原来的；换登录方式（比如从令牌换成 OAuth）时，这一项会按新的方式重写，开关和工具选择照旧，其他自定义的项（比如超时）不保留；环境变量只能加和改，删要到服务器上。目录里要先下载的条目在后台安装，装完这一页自己刷新出来。用 OAuth 的服务器点「登录…」在浏览器里授权，授权完浏览器回到服务器的地址，要先在这个浏览器里登录过 Cloudflare Access；这一步要开浏览器，CI 上没测。技能左边的锁：锁住的技能，助手自己不能改（Hermes 的 curator 也不动它），你照样能开关和编辑。删除一个助手会把服务器上它的设置、技能、记忆和对话都删掉；默认 profile 和总秘书删不了，要删总秘书先换一个。Shion 从不切换服务器的当前 profile，别的客户端不受影响。"
}

/// 新建助手: the profile's id, Bot Mode's title, its description and SOUL, a model, and the
/// profile to copy, if any.
struct NewAssistantSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Called with the new profile's id once it is there.
    var created: (String) -> Void = { _ in }
    @State private var draft = NewAssistant()
    @State private var providers: [ModelProvider] = []
    @State private var loadingModels = false
    @State private var sending = false
    @State private var failure: String?
    /// Made, though not all of it went in: what is left is done on its page.
    @State private var made: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("名字", text: $draft.name, prompt: Text(verbatim: "mail"))
                        .accessibilityIdentifier("new-assistant-name")
                    TextField("显示名", text: $draft.title, prompt: Text("邮件"))
                        .accessibilityIdentifier("new-assistant-title")
                    TextField("简介", text: $draft.description, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("new-assistant-description")
                    Picker("复制", selection: $draft.cloneFrom) {
                        Text("不复制").tag(String?.none)
                        ForEach(store.roster.profiles) { profile in
                            Text(profile.shownName).tag(String?.some(profile.name))
                        }
                    }
                    .accessibilityIdentifier("new-assistant-clone")
                    LabeledContent("模型") {
                        ModelMenu(providers: providers, current: draft.model, loading: loadingModels,
                                  noneLabel: draft.cloneFrom == nil ? "服务器默认" : "跟复制的一样") { choice in
                            draft.model = choice
                        }
                    }
                } header: {
                    Text("新建助手")
                }
                Section {
                    TextEditor(text: $draft.soul)
                        .font(.t13)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(minHeight: 110, idealHeight: 140)
                        .accessibilityIdentifier("new-assistant-soul")
                } header: {
                    Text("性格（SOUL）")
                }
            }
            .formStyle(.grouped)
            if let problem = nameProblem {
                Text(problem)
                    .font(.t12)
                    .foregroundStyle(Palette.alert)
                    .padding(.horizontal, 20)
            }
            Problem(failure)
                .padding(.horizontal, 20)
            HStack {
                if sending {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let made {
                    Button("好") {
                        dismiss()
                        created(made)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("取消", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("新建") { create() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ProfileName.isValid(name) || nameTaken || nameCleaning || sending || !store.live)
                        .accessibilityIdentifier("new-assistant-create")
                }
            }
            .padding(20)
        }
        .frame(width: 480)
        // the models of the profile being copied, or the server's own
        .task(id: draft.cloneFrom) {
            loadingModels = true
            providers = await store.modelOptions(copying: draft.cloneFrom)
            loadingModels = false
            if let model = draft.model,
               !providers.contains(where: { $0.slug == model.provider && $0.models.contains(model.model) }) {
                draft.model = nil
            }
        }
    }

    private var name: String { ProfileName.normalized(draft.name) }

    private var nameTaken: Bool { store.roster.profile(name) != nil }

    /// Deleted a moment ago, and the server has not cleaned up after it yet (Settings → 助手).
    private var nameCleaning: Bool { store.roster.cleaning[name] != nil }

    private var nameProblem: String? {
        guard !name.isEmpty, made == nil else { return nil }
        if nameTaken { return "已经有叫这个名字的助手了" }
        if nameCleaning { return "「\(name)」刚删掉，服务器还在清理它的会话记录，清理完才能再用这个名字" }
        return ProfileName.isValid(name) ? nil : "名字只能用小写字母、数字、- 和 _，以字母或数字开头"
    }

    private func create() {
        var new = draft
        new.name = name
        sending = true
        failure = nil
        Task {
            do {
                try await store.createAssistant(new)
                dismiss()
                created(new.name)
            } catch AssistantError.titleNotSet(let reason) {
                failure = AssistantError.titleNotSet(reason).localizedDescription
                made = new.name
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}

/// An assistant's row in the sidebar, right-clicked. The store is handed over rather than read
/// from the environment, which a context menu's content is not sure to get.
struct AssistantMenu: View {
    let store: AppStore
    let botId: String

    var body: some View {
        Button("打开对话") { store.route = .chat(botId) }
        Button("助手设置…") { store.route = .botSettings(botId) }
        Divider()
        Button("新建助手…") { store.roster.composing = true }
            .disabled(!store.live)
    }
}

/// The main window's 新建助手 sheet, which the sidebar's menu opens; the new assistant's page
/// follows.
struct AssistantSheet: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var roster = store.roster
        content.sheet(isPresented: $roster.composing) {
            NewAssistantSheet { name in
                store.route = .botSettings(name)
            }
        }
    }
}

/// The chat page's way to its assistant's settings.
struct AssistantSettingsButton: ViewModifier {
    @Environment(AppStore.self) private var store
    let botId: String

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.route = .botSettings(botId)
                } label: {
                    Label("助手设置", systemImage: "slider.horizontal.3")
                }
                .help("助手设置")
                .accessibilityIdentifier("assistant-settings")
            }
        }
    }
}

extension View {
    func assistantSheet() -> some View {
        modifier(AssistantSheet())
    }

    func assistantSettingsButton(_ botId: String) -> some View {
        modifier(AssistantSettingsButton(botId: botId))
    }
}
