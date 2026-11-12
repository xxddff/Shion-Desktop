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
            if store.unconnected {
                // nothing to show before the first connection: the way to make it
                ConnectFirst()
            } else {
                DetailView(route: store.route ?? .today)
            }
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
        // a skill being talked over with its assistant (SkillReviewViews.swift)
        .sheet(item: $store.reviewing) { talk in
            SkillReviewSheet(talk: talk)
        }
    }
}

/// The window before Shion has ever connected to this server: what it is for, and where to say
/// which server. Once connected it shows the server's data, and after that the last it had.
struct ConnectFirst: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("先连上你的 Hermes 服务器", systemImage: "server.rack")
        } description: {
            Text(note)
        } actions: {
            SettingsLink {
                Text("连接服务器…")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("connect-first")
        }
        .navigationTitle("Shion")
    }

    private var note: String {
        switch store.gateway.phase {
        case .connecting: return "正在连接…"
        case .failed(let reason): return "没连上：\(reason)\n在设置里检查地址和登录方式，再连一次。"
        default: return "助手、对话、待办和看板都在服务器上。在设置里填上地址、登录，连上后这里就有内容了。"
        }
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
        case .chat(let id): AssistantView(botId: id).assistantSettingsButton(id).askToolbar(id != store.chiefId).testInspector().id(id)
        case .botSettings(let id): BotSettingsView(botId: id).askToolbar().id("assistant-\(id)")
        }
    }
}

extension View {
    /// `-ShionChatInspector` (SignInTests): the page in an inspector, as a page with a detail
    /// column has it. Opening such a page, the window's split view sets it up again after the
    /// chat has gone to its newest message, and the chat shows its top: a known problem, as no
    /// page of the app is in one.
    @ViewBuilder
    func testInspector() -> some View {
        if let shown = LaunchOptions.current.chatInspector {
            modifier(TestInspector(shown: shown))
        } else {
            self
        }
    }
}

private struct TestInspector: ViewModifier {
    @State var shown: Bool

    func body(content: Content) -> some View {
        content.inspector(isPresented: $shown) {
            Color.clear
                .inspectorColumnWidth(min: 200, ideal: 220, max: 260)
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
                Label("待你处理", systemImage: "hand.raised")
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(store.reconnecting ? Palette.warm : ConnectionState.color(store.gateway.phase))
                        .frame(width: 7, height: 7)
                    Text(store.serverSettings.host.isEmpty ? "未连接服务器" : store.serverSettings.host)
                        .font(.t12)
                        .lineLimit(1)
                    Spacer()
                    if store.showsDemo {
                        Text("示例数据").font(.t11).foregroundStyle(.tertiary)
                    }
                }
                // not connected, or not any more: the server's data as it last was, from when; while a
                // connection that had worked is being got back, that, and when it is tried again
                if let note = store.reconnectNote ?? store.lastDataNote {
                    Text(note)
                        .font(.t11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 13)
                        .accessibilityIdentifier("connection-note")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
