import SwiftUI

/// Settings say what each feature sends and what it does not; the window does not.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ServerSettings()

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                TextField("地址", text: $draft.address, prompt: Text("https://hermes.example.dev"))
                SecureField("会话令牌", text: $draft.token)
                TextField("Access Client ID", text: $draft.accessClientId)
                SecureField("Access Client Secret", text: $draft.accessClientSecret)
                HStack(spacing: 8) {
                    ConnectionState(phase: store.gateway.phase, live: store.live, count: store.bots.count)
                    Spacer()
                    if store.gateway.phase != .offline {
                        Button("断开") { store.disconnect() }
                    }
                    Button(store.gateway.phase == .online ? "重新连接" : "连接") {
                        store.serverSettings = draft
                        Task { await store.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isConfigured || store.gateway.phase == .connecting)
                }
            } header: {
                Text("Hermes 服务器")
            } footer: {
                Text("会话令牌是服务器上的 HERMES_DASHBOARD_SESSION_TOKEN。Access 两项填 Cloudflare Access 的 service token，没有就留空。三项都存在钥匙串里，只发给这个地址。连上后，助手列表和各助手的对话来自服务器；今天、待办、日程、日报、看板和云桌面暂时还是示例数据。")
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }

            Section("看板") {
                LabeledContent("同时进行", value: "最多 4 件，每个助手一次一件")
            }

            Section("这台 Mac 发出去的") {
                Toggle(isOn: $store.activityLog) {
                    Text("记录应用使用情况")
                    Text("发给「回顾」：应用名、使用时长。不发：窗口标题、窗口里的内容。")
                }
                Toggle(isOn: $store.focusCheck) {
                    Text("专注检查")
                    Text("发给詩音：此刻的计划、偏离了几分钟、在做哪类事。不发：窗口标题、应用名、本机的窗口记录。在本机读窗口标题，需要辅助功能权限。")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            draft = store.serverSettings
        }
    }
}

/// Where the connection stands, in words.
struct ConnectionState: View {
    let phase: Gateway.Phase
    let live: Bool
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Self.color(phase)).frame(width: 7, height: 7)
            Text(text)
                .font(.t12)
                .foregroundStyle(.secondary)
                .lineLimit(2)
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
        case .online: return live ? "已连接 · \(count) 个助手" : "已连接"
        case .connecting: return "连接中…"
        case .failed(let reason): return reason
        case .offline: return "未连接，现在是示例数据"
        }
    }
}
