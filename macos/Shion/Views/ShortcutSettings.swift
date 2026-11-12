import KeyboardShortcuts
import SwiftUI

/// Settings → 快捷键: the global shortcut for the ⌥Space window, whether the system gave it to
/// Shion, and what the keys in the main window do.
struct ShortcutSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var quick = QuickAsk.shared
        Form {
            Section {
                KeyboardShortcuts.Recorder("跟\(store.chiefName)说", shortcut: $quick.shortcut)
                    .accessibilityIdentifier("quick-shortcut")
                if let problem = Self.problem(quick.hotKeyState) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.warm)
                        Text(problem)
                            .font(.t13)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("再试一次") {
                            quick.retryHotKey()
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("quick-shortcut-retry")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("quick-shortcut-problem")
                }
            } header: {
                Text("在任何 App 里")
            } footer: {
                Text(Self.globalNote)
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("⌘1 到 ⌘7", value: "今天、待你处理、待办、日程、日报、看板、云桌面")
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
        .frame(width: 520, height: 520)
        // another app may have let it go since
        .onAppear {
            quick.retryHotKey()
        }
    }

    /// What the system said when Shion asked for the shortcut, when it did not take it.
    private static func problem(_ state: GlobalHotKey.State) -> String? {
        switch state {
        case .taken:
            return "被别的 App 占用了，换一个组合吧。"
        case .failed(let status):
            return "系统没有接受这个组合（\(status)），换一个试试。"
        case .off, .registered:
            return nil
        }
    }

    private static let globalNote = "按下这个快捷键，屏幕上方会出现一个小窗：跟总秘书说一句话，回复也在小窗里一点点显示出来；这一轮里要你批准的、问你的，也在小窗里回答，要打字回答的问题直接在输入框里写。这句话进的是总秘书的 Bot Chat，和在主窗口里说的一样；点输入框右边的按钮（⌘O）打开完整对话，按 Esc 或再按一次快捷键收起。小窗浮在别的 App 上面，不会把 Shion 切到前台。没连上服务器时说的话会留在小窗里，标着什么时候写的、「等连上服务器后发出」，连上后自动发出，退出 Shion 也不会丢；写下超过 5 分钟才发出的，前面会带上写下的时间，免得「5 分钟后提醒我」被照字面晚做。\n\n默认是 ⌥空格，避开了聚焦搜索（⌘空格）和切换输入法（⌃空格、⌃⌥空格）。点一下再按新的组合就能改，和系统或菜单里的快捷键撞上时会提示。别的 App（比如 Raycast、Alfred）独占了同一个组合时，这里会显示「被别的 App 占用了」：换一个组合，或者在那个 App 里去掉它，再点「再试一次」。有两种情况这里看不出来：那个 App 只是普通地注册了同一个组合，按键会归 Shion，它的这个快捷键就不灵了；它抢在系统之前截走按键，Shion 这边就按了没反应。遇到这两种，也换一个组合。"

    private static let windowNote = "⌘K 搜页面、助手和待办的标题，↑↓ 选，回车打开；什么都没搜到时，回车把这句话交给总秘书。这些都列在菜单栏的「前往」里。"
}
