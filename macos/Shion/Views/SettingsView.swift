import SwiftUI

/// Settings say what each feature sends and what it does not; the window does not.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ServerSettings()

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                TextField("地址", text: $draft.address, prompt: Text(verbatim: "https://hermes.example.dev"))
                    .accessibilityIdentifier("server-address")
                Picker("登录方式", selection: $draft.login) {
                    Text("浏览器登录").tag(ServerSettings.Login.browser)
                    Text("会话令牌").tag(ServerSettings.Login.sessionToken)
                }
                .pickerStyle(.segmented)
                switch draft.login {
                case .browser:
                    AccountRow(draft: draft)
                case .sessionToken:
                    SecureField("会话令牌", text: $draft.token)
                }
                TextField("Access Client ID", text: $draft.accessClientId)
                    .accessibilityIdentifier("access-id")
                SecureField("Access Client Secret", text: $draft.accessClientSecret)
                    .accessibilityIdentifier("access-secret")
                HStack(spacing: 8) {
                    ConnectionState(phase: store.gateway.phase, live: store.live, count: store.bots.count, canonical: store.gateway.sessionAuthority,
                                    lastDataAt: store.lastData.shown ? store.lastData.savedAt : nil)
                    Spacer()
                    if store.gateway.phase != .offline {
                        Button("断开") { store.disconnect() }
                    }
                    Button(store.gateway.phase == .online ? "重新连接" : "连接") {
                        store.serverSettings = draft
                        Task { await store.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canConnect(draft) || store.gateway.phase == .connecting)
                }
            } header: {
                Text("Hermes 服务器")
            } footer: {
                Text(footer)
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }

            Section {
                if let limits = store.boardLimits {
                    LabeledContent("整台服务器同时进行") {
                        Text(Self.count(limits.effectiveMax, derived: limits.derivedFromMemory))
                            .accessibilityIdentifier("board-limit-total")
                    }
                    LabeledContent("每个助手同时进行") {
                        Text(Self.count(limits.perAssistant, derived: false))
                            .accessibilityIdentifier("board-limit-assistant")
                    }
                } else {
                    LabeledContent("同时进行", value: store.live ? "读不到服务器的设置" : "连上服务器后显示")
                }
                Toggle(isOn: Binding(get: { store.board.notifyDone }, set: { store.board.notifyDone = $0 })) {
                    Text("卡片做完时通知")
                    Text("卡片停下来等你、或交给你检查时总会通知，做完了通不通知看这个开关。停下来等你的卡可以直接在通知里回复：回复署你的登录名留在卡上，它接着做。看板页开在眼前时不发，等你回答的卡在「等你确认」开着时也不发。点通知打开那张卡。詩音会在她的对话里说做完的卡，那条回复也有通知。")
                }
                .accessibilityIdentifier("board-notify-done")
            } header: {
                Text("看板")
            } footer: {
                Text("取自服务器 config.yaml 里的 kanban.max_in_progress 和 kanban.max_in_progress_per_profile，改了要重启 gateway 才生效。整台服务器那项不设时，Linux 上按内存算：每 512 MB 一件，最少 2 件、最多 8 件。每个助手那项在每块看板上分开算。Shion 不手动派发（不调 /dispatch，它会越过这两个上限），就绪的卡等派发器下一轮；看板上排队的卡写明在等什么：前面的卡、这个助手手上那件、整台服务器满了，或者下一轮派发。停下来要你回答的卡（要你给的信息，或它没有的账号、权限）也在「等你确认」里：回复留在卡上，署你的登录名；「让它继续」让它回到就绪，它再跑时先读评论。只是出错停下的（比如网站超时）留在看板上，等詩音或你让它重试。每个助手页的「工作记录」列出它今天在各块看板上跑过的卡，之后归档了的也在。")
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }

            Section("这台 Mac 发出去的") {
                Toggle(isOn: $store.activityLog) {
                    Text("记录应用使用情况")
                    Text("发给「回顾」：应用名、使用时长。不发：窗口标题、窗口里的内容。")
                }
                Toggle(isOn: $store.focusCheck) {
                    Text("专注检查")
                    Text("发给\(store.chiefName)：此刻的计划、偏离了几分钟、在做哪类事。不发：窗口标题、应用名、本机的窗口记录。在本机读窗口标题，需要辅助功能权限。")
                }
            }

            LastDataSection()
        }
        .formStyle(.grouped)
        // tall enough for the server and the board at once
        .frame(width: 520, height: 640)
        .onAppear {
            draft = store.serverSettings
        }
    }

    static func count(_ value: Int?, derived: Bool) -> String {
        guard let value else { return "不限" }
        return derived ? "\(value) 件（按内存推算）" : "\(value) 件"
    }

    private var footer: String {
        let login = switch draft.login {
        case .browser:
            "浏览器登录：登录窗口里先出现 Cloudflare Access 的话，照它的要求登录，再输入 Hermes 的用户名和密码。Shion 只拿到登录凭证，碰不到密码；凭证快到期时自动续上。"
        case .sessionToken:
            "会话令牌是服务器上的 HERMES_DASHBOARD_SESSION_TOKEN。"
        }
        return login + "Access 两项填 Cloudflare Access 的 service token，没有就留空。这些都存在钥匙串里，只发给这个地址。连上后，助手、对话和看板来自服务器；服务器装了 shion 插件时，今天、待办和日报也是。日程和云桌面暂时还是示例数据。"
    }
}

/// The browser sign-in for the address being edited: who is signed in, or the way to sign in.
struct AccountRow: View {
    @Environment(AppStore.self) private var store
    let draft: ServerSettings

    var body: some View {
        LabeledContent("账号") {
            if store.account.state == .signingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("登录中…").foregroundStyle(.secondary)
                    Button("取消") { store.account.cancelSignIn() }
                }
            } else if let tokens = store.account.tokens(for: draft.trimmed) {
                HStack(spacing: 8) {
                    Text(tokens.userId.isEmpty ? "已登录" : tokens.userId)
                        .accessibilityIdentifier("account-name")
                    Button("退出登录") { store.signOut() }
                }
            } else {
                Button("用浏览器登录…") {
                    store.serverSettings = draft
                    Task { await store.signIn() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.trimmed.isConfigured)
                .accessibilityIdentifier("sign-in")
            }
        }
        if case .failed(let reason) = store.account.state {
            Text(reason)
                .font(.t12)
                .foregroundStyle(Palette.alert)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where the connection stands, in words.
struct ConnectionState: View {
    let phase: Gateway.Phase
    let live: Bool
    let count: Int
    var canonical = true
    /// Showing the last data (AppStore+LastData.swift): from when.
    var lastDataAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Self.color(phase)).frame(width: 7, height: 7)
            Text(text)
                .font(.t12)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                // selectable text keeps the accessibility value it was created with: a new
                // line of text gets a new view, so VoiceOver reads what is on screen
                .id(text)
                .accessibilityIdentifier("connection-state")
        }
    }

    static func color(_ phase: Gateway.Phase) -> Color {
        switch phase {
        case .online: return Color.green
        case .connecting: return Palette.warm
        case .failed: return Palette.alert
        case .offline: return Color.secondary
        }
    }

    private var text: String {
        switch phase {
        case .online where !canonical: return "已连接，但服务器说的是旧协议（hermes serve），对话会用不了；要连 hermes gateway 的 /api/ws"
        case .online: return live ? "已连接 · \(count) 个助手" : "已连接"
        case .connecting: return "连接中…"
        case .failed(let reason): return reason
        case .offline:
            guard let lastDataAt else { return "未连接，现在是示例数据" }
            return "未连接，现在是上次的数据（\(Fmt.when(lastDataAt, now: Date()))）"
        }
    }
}
