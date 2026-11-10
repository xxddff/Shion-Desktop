import KeyboardShortcuts
import SwiftUI

/// Settings → 快捷键: the global shortcut for the ⌥Space window, and what the keys in the main
/// window do.
struct ShortcutSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var quick = QuickAsk.shared
        Form {
            Section {
                KeyboardShortcuts.Recorder("跟\(store.chiefName)说", shortcut: $quick.shortcut)
                    .accessibilityIdentifier("quick-shortcut")
            } header: {
                Text("在任何 App 里")
            } footer: {
                Text(Self.globalNote)
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("⌘1 到 ⌘7", value: "今天、等你确认、待办、日程、日报、看板、云桌面")
                LabeledContent("⌘K", value: "快速跳转")
            } header: {
                Text("在主窗口里")
            } footer: {
                Text(Self.windowNote)
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
    }

    private static let globalNote = "按下这个快捷键，屏幕上方会出现一个小窗：跟总秘书说一句话，回复也在小窗里一点点显示出来。这句话进的是总秘书的 Bot Chat，和在主窗口里说的一样；点输入框右边的按钮（⌘O）打开完整对话，按 Esc 或再按一次快捷键收起。小窗浮在别的 App 上面，不会把 Shion 切到前台。默认是 ⌥空格，避开了聚焦搜索（⌘空格）和切换输入法（⌃空格、⌃⌥空格）。点一下再按新的组合就能改，和系统或菜单里的快捷键撞上时会提示；别的 App（比如 Raycast、Alfred）先占了同一个组合的话，按了没反应，换一个就好。"

    private static let windowNote = "⌘K 搜页面、助手和待办的标题，↑↓ 选，回车打开；什么都没搜到时，回车把这句话交给总秘书。这些都列在菜单栏的「前往」里。"
}
