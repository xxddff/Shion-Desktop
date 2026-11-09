import SwiftUI

/// Settings say what each local feature sends and what it does not; the window does not.
struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Hermes") {
                LabeledContent("tokyo-vps", value: "Cloudflare Tunnel · Access")
                LabeledContent("看板", value: "同时最多 4 件，每个助手一次一件")
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
        .frame(width: 480)
    }
}
