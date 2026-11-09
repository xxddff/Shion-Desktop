import AppKit
import KeyboardShortcuts
import SwiftUI

/// The 前往 menu: the pages on ⌘1…⌘7 in sidebar order, ⌘K, and 跟詩音说 on the global shortcut
/// (shown here; the shortcut itself works in any app).
struct ShionCommands: Commands {
    let store: AppStore
    let jump: JumpState
    let quick: QuickAsk

    var body: some Commands {
        CommandMenu("前往") {
            ForEach(Array(SidebarPage.all.enumerated()), id: \.offset) { index, page in
                Button(page.title) {
                    go(page.route)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button("快速跳转…") {
                guard !Self.quickHasKeyboard else { return }
                MainWindow.show()
                jump.shown.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            Button("跟詩音说…") {
                quick.show()
            }
            .keyboardShortcut(quick.shortcut?.toSwiftUI)
        }
    }

    private func go(_ route: Route) {
        guard !Self.quickHasKeyboard else { return }
        jump.shown = false
        store.route = route
        MainWindow.show()
    }

    /// Typing in the ⌥Space window, which lives over other apps: ⌘1 or ⌘K there is not for the
    /// main window behind them.
    private static var quickHasKeyboard: Bool {
        NSApp.keyWindow is QuickAskWindow
    }
}

/// A page of the sidebar as ⌘1…⌘7 and ⌘K list it. A table rather than a switch over Route, which
/// gains cases for pages that are not on these keys.
struct SidebarPage {
    let route: Route
    let title: String
    /// The sidebar's symbol for it.
    let symbol: String
    /// Its launch argument name (`-ShionRoute today`), which ⌘K also finds it by.
    let token: String

    /// In sidebar order: ⌘1 is the first.
    static let all: [SidebarPage] = [
        SidebarPage(route: .today, title: "今天", symbol: "sun.max", token: "today"),
        SidebarPage(route: .confirm, title: "等你确认", symbol: "hand.raised", token: "confirm"),
        SidebarPage(route: .todos, title: "待办", symbol: "checklist", token: "todos"),
        SidebarPage(route: .calendar, title: "日程", symbol: "calendar", token: "calendar"),
        SidebarPage(route: .reports, title: "日报", symbol: "doc.text", token: "reports"),
        SidebarPage(route: .board, title: "看板", symbol: "rectangle.split.3x1", token: "board"),
        SidebarPage(route: .desktop, title: "云桌面", symbol: "display", token: "desktop"),
    ]
}

enum MainWindow {
    /// Shion in front with its main window, opened again if it was closed.
    static func show() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("AppWindow") == true }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            Notifier.shared.openMainWindow?()
        }
    }
}
