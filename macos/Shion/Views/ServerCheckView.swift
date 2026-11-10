import SwiftUI

/// Settings → 服务器体检 (SettingsTabs, AssistantSettings.swift): every check with its state, and how
/// to put it right when it is not.
struct ServerCheckView: View {
    @Environment(AppStore.self) private var store
    @State private var check = ServerCheck()

    var body: some View {
        Form {
            // at the top, so 重新检查 is in view on a small screen too
            Section {
                HStack(spacing: 8) {
                    Text(check.summary)
                        .font(.t13)
                        .accessibilityIdentifier("check-summary")
                    Spacer()
                    if check.running {
                        ProgressView().controlSize(.small)
                    }
                    Button("重新检查") {
                        Task { await check.run(store) }
                    }
                    .disabled(check.running)
                    .accessibilityIdentifier("check-again")
                }
            }
            Section {
                ForEach(check.items) { item in
                    CheckRow(item: item)
                }
            } footer: {
                Text("从这台 Mac 依次查：Cloudflare Access 放不放行（/api/status）；登录凭证有没有效、多久到期（/api/auth/me）；/api/ws 是不是 hermes gateway 的 Canonical 协议，runtime.describe 报了哪些能力；每个助手的 profile 里有没有 shion 插件（plugin.shion.info），服务器有没有时区数据（它报的 tz_database）；看板插件在不在（/api/plugins/kanban/boards）；看板同时进行的上限（/api/config）；这台 Mac 允不允许 Shion 发通知。协议、能力、插件、时区数据和看板上限要先连上服务器。只读，不改服务器上的任何东西，也不会替你申请通知权限。")
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .task {
            await check.run(store)
        }
    }
}

struct CheckRow: View {
    let item: ServerCheck.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CheckMark(level: item.level)
                Text(item.title).font(.t13)
                Spacer(minLength: 12)
                Text(item.status)
                    .font(.t12)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("check-\(item.id)")
            }
            ForEach(item.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CheckMark(level: line.level)
                        .font(.t11)
                    Text(line.title).font(.t12)
                    Spacer(minLength: 12)
                    Text(line.text)
                        .font(.t12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("check-\(item.id)-\(line.id)")
                }
                .padding(.leading, 22)
            }
            if let fix = item.fix {
                Text(fix)
                    .font(.t12)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
            if item.id == "notifications" && (item.level == .warn || item.level == .fail) {
                Button("打开通知设置") {
                    ServerCheck.openNotificationSettings()
                }
                .controlSize(.small)
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }
}

struct CheckMark: View {
    let level: ServerCheck.Level

    var body: some View {
        switch level {
        case .checking:
            ProgressView().controlSize(.mini)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
                .accessibilityLabel("正常")
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warm)
                .accessibilityLabel("要注意")
        case .fail:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Palette.alert)
                .accessibilityLabel("不对")
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("没查")
        }
    }
}

/// Settings: what Shion keeps of the server's data for when it cannot reach it, and where.
struct LastDataSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Section {
            LabeledContent("上次的数据") {
                HStack(spacing: 8) {
                    Text(state)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("last-data-state")
                    if store.lastData.savedAt != nil {
                        Button("清除") { store.clearLastData() }
                    }
                }
            }
        } header: {
            Text("没连上时")
        } footer: {
            Text("连上过一次以后，Shion 把服务器上的数据在这台 Mac 上存一份：助手列表、今天页詩音写的那段话、待办、日报、看板上的卡片，还有每个对话最近的 \(LastData.chatRows) 条。还没连上或者断了线，窗口里显示的就是这一份，侧栏底部写着是什么时候的；这时只能看，勾待办、挪卡片、回答批准等连上再做。在对话里说的话排队，显示在对话下面，连上后按顺序一句一句发出，写下超过 5 分钟才发出的前面带上写下的时间。断了线会自己重连，侧栏写着「重新连接中…」和下次试的时间（隔 1、2、4、8 秒，之后每 15 秒），合上盖子再打开、换了网络就马上试。连上后从断开的地方接着收：没回完的接着流进同一个气泡，断开时已经回完的直接显示整段。断开那一刻发出的话会跟服务器核对：服务器收到了就照常显示，没收到的写着「没发出去」，点「重发」再发一次，同一句话不会出现两次。等你确认的批准和提问不存，只能在连着时回答。存在 ~/Library/Application Support/dev.shion.Shion/last-data.json，只有你能读；不存密钥、令牌和密码，它们只在钥匙串里。只存最后连上的那台服务器的：换了地址，连上之前是示例数据。清除之后，下次连上又会存。")
                .font(.t12)
                .foregroundStyle(.secondary)
        }
    }

    private var state: String {
        guard let at = store.lastData.savedAt else { return "还没有" }
        let when = Fmt.when(at, now: Date())
        return store.lastData.shown ? "\(when)，正在显示" : when
    }
}
