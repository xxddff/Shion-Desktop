import KeyboardShortcuts
import SwiftUI

/// The global shortcut for the ⌥Space window, and what the keys in the main window do.
struct ShortcutSettings: View {
    var body: some View {
        @Bindable var quick = QuickAsk.shared
        Section {
            KeyboardShortcuts.Recorder("跟詩音说", shortcut: $quick.shortcut)
                .accessibilityIdentifier("quick-shortcut")
        } header: {
            Text("快捷键")
        } footer: {
            Text("在任何 App 里按这个快捷键，屏幕上方会出现一个小窗：跟詩音说一句话，她的回复也在小窗里一点点显示出来。这句话进的是詩音的 Bot Chat，和在主窗口里说的一样；点输入框右边的按钮（⌘O）打开完整对话，按 Esc 或再按一次快捷键收起。默认是 ⌥Space，避开了聚焦搜索（⌘Space）和切换输入法（⌃Space、⌃⌥Space）。点一下再按新的组合就能改，和系统或菜单里的快捷键撞上时会提示；别的 App（比如 Raycast、Alfred）先占了同一个组合的话，按了没反应，换一个就好。主窗口里，⌘1 到 ⌘7 依次切到今天、等你确认、待办、日程、日报、看板、云桌面，⌘K 快速跳转到页面、助手和待办（搜的是待办的标题），这些都列在「前往」菜单里。")
                .font(.t12)
                .foregroundStyle(.secondary)
        }
    }
}
