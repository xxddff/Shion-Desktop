import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar(selection: $store.route)
                .focused($sidebarFocused)
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 280)
        } detail: {
            DetailView(route: store.route ?? .today)
        }
        // keyboard focus starts in the sidebar, not in the first text field of the page; AppKit
        // still hands the new window to that field, so take focus back once it is up
        .defaultFocus($sidebarFocused, true)
        .task {
            try? await Task.sleep(for: .milliseconds(200))
            sidebarFocused = true
        }
        .frame(minWidth: 960, minHeight: 620)
    }
}

struct DetailView: View {
    let route: Route

    var body: some View {
        switch route {
        case .today: TodayView()
        case .confirm: ConfirmView().askToolbar()
        case .todos: TodosView().askToolbar()
        case .calendar: CalendarView().askToolbar()
        case .reports: ReportsView().askToolbar()
        case .board: BoardView().askToolbar()
        case .desktop: DesktopView().askToolbar()
        case .chat(let id): ChatView(botId: id).askToolbar(id != "shion").id(id)
        }
    }
}

struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: Route?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("今天", systemImage: "sun.max").tag(Route.today)
                Label("等你确认", systemImage: "hand.raised")
                    .badge(store.asks.isEmpty ? nil : Text("\(store.asks.count)").foregroundStyle(Palette.warm).fontWeight(.semibold))
                    .tag(Route.confirm)
                Label("待办", systemImage: "checklist").badge(store.todayTodos.count).tag(Route.todos)
                Label("日程", systemImage: "calendar").tag(Route.calendar)
                Label("日报", systemImage: "doc.text").tag(Route.reports)
            }
            Section("工作区") {
                Label("看板", systemImage: "rectangle.split.3x1").tag(Route.board)
                Label("云桌面", systemImage: "display").tag(Route.desktop)
            }
            Section("助手") {
                ForEach(store.bots) { bot in
                    BotRow(bot: bot, waiting: store.asks.contains { $0.botId == bot.id })
                        .tag(Route.chat(bot.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConnectionFooter()
        }
    }
}

struct BotRow: View {
    let bot: Bot
    let waiting: Bool

    var body: some View {
        HStack(spacing: 8) {
            Avatar(bot: bot, size: 20)
            Text(bot.name)
            if bot.chief {
                Text(bot.title).font(.t11).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if bot.status == .working {
                BusyDots()
            } else if waiting {
                Circle().fill(Palette.warm).frame(width: 7, height: 7)
            }
        }
    }
}

struct ConnectionFooter: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text("tokyo-vps").font(.t12)
            Spacer()
            Text("示例数据").font(.t11).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
