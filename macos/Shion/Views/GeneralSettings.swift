import SwiftUI

/// Settings → 通用: whether Shion starts with the Mac and keeps to the menu bar once its window is
/// closed, where a notification's click lands, and what Shortcuts and Siri can do. How each works
/// is said here, under it, and nowhere else.
struct GeneralSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var dock = DockMode.shared
        let login = LoginItem.shared
        Form {
            Section {
                Toggle("开机启动", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                    .accessibilityIdentifier("login-item")
                // the identifiers go on the parts: one on the row would be the button's too
                LabeledContent("状态") {
                    HStack(spacing: 8) {
                        Text(Self.stateText(login.state))
                            .foregroundStyle(Self.stateStyle(login.state))
                            .accessibilityIdentifier("login-item-state")
                        if login.state == .needsApproval {
                            Button("打开「登录项」…") { login.openLoginItems() }
                                .accessibilityIdentifier("login-items")
                        }
                    }
                }
                if let failure = login.failure {
                    Text(failure)
                        .font(.t12)
                        .foregroundStyle(Palette.alert)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("启动")
            } footer: {
                Text(Self.loginNote)
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("关窗后只留在菜单栏", isOn: $dock.menuBarOnly)
                    .accessibilityIdentifier("menubar-only")
            } footer: {
                Text(Self.menuBarNote)
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("回复", value: "那个对话，停在那条消息")
                LabeledContent("批准、提问", value: "「等你确认」，选中那一件")
                LabeledContent("看板卡片", value: "那块看板上那张卡的详情")
                LabeledContent("日报", value: "那份日报")
            } header: {
                Text("点通知打开")
            } footer: {
                Text(Self.landingNote)
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("跟总秘书说", value: "发给\(store.chiefName)，回复带回来")
                LabeledContent("今天的待办", value: "今天要做和到期的")
                LabeledContent("打开助手", value: "按名字找，打开它的对话")
                LabeledContent("打开等你确认", value: "谁在等你批准、回答")
            } header: {
                Text("快捷指令和 Siri")
            } footer: {
                Text(shortcutsNote)
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }

    private static func stateText(_ state: LoginItem.State) -> String {
        switch state {
        case .on: "登录这台 Mac 时打开"
        case .off: "不随开机打开"
        case .needsApproval: "要在系统设置里允许"
        case .notFound: "系统找不到 Shion 的登录项"
        }
    }

    private static func stateStyle(_ state: LoginItem.State) -> AnyShapeStyle {
        switch state {
        case .on, .off: AnyShapeStyle(.secondary)
        case .needsApproval: AnyShapeStyle(Palette.warm)
        case .notFound: AnyShapeStyle(Palette.alert)
        }
    }

    private static let loginNote = "打开后，登录这台 Mac 时 Shion 自己打开，连上服务器，菜单栏和通知照常。第一次打开时系统可能要你在「系统设置 → 通用 → 登录项」里允许，这里会写「要在系统设置里允许」；在系统设置里关掉的话，这里也跟着变。"

    private static let menuBarNote = "打开后，关掉主窗口时 Dock 里的图标也收起来，Shion 只留在菜单栏，通知、⌥空格、快捷指令照常；等你确认的件数显示在菜单栏图标旁边。从菜单栏面板的「打开 Shion」、点通知或快捷指令再打开窗口时，Dock 图标回来。要退出，在窗口开着时按 ⌘Q。"

    private static let landingNote = "Shion 没开着时，点通知会打开它，连上服务器、读到那条消息（或那一件、那张卡、那份日报）后停在那里；已经处理掉、找不到的，就停在那一页。日报写好时也会通知（日报页开在眼前时不发），一种日报一条，新的替换旧的。"

    private var shortcutsNote: String {
        "在「快捷指令」App 和聚焦搜索里能找到这四个动作，也能对 Siri 说「用 Shion 跟总秘书说」「Shion 今天的待办」「用 Shion 打开助手」（再说是哪一个）、「用 Shion 打开等你确认」（Siri 的语言要是中文）。跟总秘书说：这句话进\(store.chiefName)的 Bot Chat，和在主窗口里说的一样；10 秒内回复了，就把回复带回来，没有就回「已发出」，回复照常在通知和对话里。没登录服务器、没连上时什么都不发，会说明为什么。Shion 没开着时，动作会先打开它、等它连上。"
    }
}
