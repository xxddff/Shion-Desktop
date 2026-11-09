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
            ForEach(Array(Route.pages.enumerated()), id: \.offset) { index, page in
                Button(page.pageTitle) {
                    go(page)
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
                quick.show(by: "menu")
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

extension Route {
    /// The pages in sidebar order: ⌘1 is the first.
    static let pages: [Route] = [.today, .confirm, .todos, .calendar, .reports, .board, .desktop]

    var pageTitle: String {
        switch self {
        case .today: "今天"
        case .confirm: "等你确认"
        case .todos: "待办"
        case .calendar: "日程"
        case .reports: "日报"
        case .board: "看板"
        case .desktop: "云桌面"
        case .chat: ""
        }
    }

    /// The sidebar's symbol for the page.
    var pageSymbol: String {
        switch self {
        case .today: "sun.max"
        case .confirm: "hand.raised"
        case .todos: "checklist"
        case .calendar: "calendar"
        case .reports: "doc.text"
        case .board: "rectangle.split.3x1"
        case .desktop: "display"
        case .chat: "bubble.left"
        }
    }

    /// The launch argument's name for it (`-ShionRoute today`), which ⌘K also finds it by.
    var pageToken: String {
        switch self {
        case .today: "today"
        case .confirm: "confirm"
        case .todos: "todos"
        case .calendar: "calendar"
        case .reports: "reports"
        case .board: "board"
        case .desktop: "desktop"
        case .chat(let id): "chat-\(id)"
        }
    }
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
