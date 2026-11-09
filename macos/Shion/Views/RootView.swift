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
        // ⌘K (JumpPalette.swift)
        .overlay(alignment: .top) {
            JumpOverlay()
        }
        .frame(minWidth: 960, minHeight: 620)
    }
}

struct DetailView: View {
    @Environment(AppStore.self) private var store
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
        case .chat(let id): AssistantView(botId: id).assistantSettingsButton(id).askToolbar(id != store.chiefId).id(id)
        case .botSettings(let id): BotSettingsView(botId: id).askToolbar().id("assistant-\(id)")
        }
    }
}

struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: Route?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("今天", systemImage: "sun.max").accessibilityIdentifier("nav-today").tag(Route.today)
                Label("等你确认", systemImage: "hand.raised")
                    .accessibilityIdentifier("nav-confirm")
                    .badge(confirmBadge)
                    .tag(Route.confirm)
                Label("待办", systemImage: "checklist").badge(store.todayTodos.count).accessibilityIdentifier("nav-todos").tag(Route.todos)
                Label("日程", systemImage: "calendar").tag(Route.calendar)
                Label("日报", systemImage: "doc.text").accessibilityIdentifier("nav-reports").tag(Route.reports)
            }
            Section("工作区") {
                Label("看板", systemImage: "rectangle.split.3x1").accessibilityIdentifier("nav-board").tag(Route.board)
                Label("云桌面", systemImage: "display").accessibilityIdentifier("nav-desktop").tag(Route.desktop)
            }
            Section("助手") {
                ForEach(store.bots) { bot in
                    BotRow(bot: bot, waiting: store.waitsOnYou(bot.id))
                        .accessibilityIdentifier("bot-\(bot.id)")
                        .contextMenu { AssistantMenu(store: store, botId: bot.id) }
                        .tag(Route.chat(bot.id))
                }
            }
        }
        .listStyle(.sidebar)
        .assistantSheet()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConnectionFooter()
        }
    }

    /// Warm while asks wait on you; the system's own color on the selected row, where warm would
    /// sink into the accent fill.
    private var confirmBadge: Text? {
        let waiting = store.confirmCount
        guard waiting > 0 else { return nil }
        let count = Text("\(waiting)")
        return selection == .confirm ? count : count.foregroundStyle(Palette.warm).fontWeight(.semibold)
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

/// The server this window talks to, and whether the data is real yet. Opens Settings.
struct ConnectionFooter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        SettingsLink {
            HStack(spacing: 6) {
                Circle().fill(ConnectionState.color(store.gateway.phase)).frame(width: 7, height: 7)
                Text(store.serverSettings.host.isEmpty ? "未连接服务器" : store.serverSettings.host)
                    .font(.t12)
                    .lineLimit(1)
                Spacer()
                if !store.live {
                    Text("示例数据").font(.t11).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
