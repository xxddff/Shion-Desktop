import SwiftUI

/// The two tabs of an assistant's page.
enum AssistantTab: Hashable {
    case chat, work

    /// What a page opens on; screenshot runs can ask for the log (`-ShionTab work`).
    static var launch: AssistantTab {
        LaunchOptions.current.snapshot && UserDefaults.standard.string(forKey: "ShionTab") == "work" ? .work : .chat
    }
}

/// An assistant's page: its Bot Chat, and 工作记录, the cards it ran today on every board, as two
/// tabs at the top of the page; the toolbar keeps its buttons (跟詩音说, 助手设置) to itself. The
/// chat stays underneath while the log is up, so a draft and where the chat was scrolled to
/// survive a look at the log. A card of the log opens on its right.
struct AssistantView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var tab = AssistantTab.launch
    /// The log's card open on its right.
    @State private var selection: String?
    @State private var showDetail = false

    var body: some View {
        let entries = tab == .work ? store.workLog(for: botId) : []
        ChatView(botId: botId)
            .disabled(tab == .work)
            .allowsHitTesting(tab == .chat)
            .opacity(tab == .chat ? 1 : 0)
            .accessibilityHidden(tab == .work)
            .overlay {
                if tab == .work {
                    workLog(entries)
                }
            }
            // over the top of the page, which runs under them as it runs under the toolbar: the
            // chat keeps the geometry its paging was made for (a VStack cut it off below the tabs,
            // and older pages stopped coming after the second)
            .safeAreaInset(edge: .top, spacing: 0) {
                tabs
            }
            // archived cards that ran today are read only while the log is up
            .task(id: tab == .work && store.board.active) {
                guard tab == .work, store.board.active else { return }
                await store.board.followArchived()
            }
            .alert("没能完成", isPresented: actionFailed) {
                Button("好") {}
            } message: {
                Text(store.board.actionError ?? "")
            }
            .onChange(of: tab) { _, now in
                if now == .chat {
                    showDetail = false
                }
            }
    }

    /// The log, and the card open from it on its right: a panel of the page, not the window's
    /// inspector. With an inspector on it, the page was taken in again by the window's split view
    /// when you went to it, after the chat had put its new transcript at the newest message, and
    /// the chat showed its top instead.
    private func workLog(_ entries: [WorkLogEntry]) -> some View {
        HStack(spacing: 0) {
            WorkLogView(entries: entries, selection: selection) { open($0) }
            if showDetail, let entry = entries.first(where: { $0.id == selection }) {
                Divider()
                BoardInspector(item: store.workItem(entry)) { id in
                    store.openCard(id, board: entry.board)
                }
                .frame(width: 280)
                .overlay(alignment: .topTrailing) {
                    Button {
                        showDetail = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("关闭")
                    .padding(12)
                    .accessibilityIdentifier("work-detail-close")
                }
            }
        }
        .background(.background)
    }

    private var tabs: some View {
        Picker("显示", selection: $tab) {
            Text("Bot Chat").tag(AssistantTab.chat)
            Text("工作记录").tag(AssistantTab.work)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("assistant-tabs")
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 6)
        // what scrolls under it does not show through
        .background(.background)
    }

    private func open(_ entry: WorkLogEntry) {
        selection = entry.id
        showDetail = true
        store.board.select(entry.cardId, on: entry.board)
    }

    private var actionFailed: Binding<Bool> {
        Binding(
            get: { tab == .work && store.board.actionError != nil },
            set: { shown in
                if !shown {
                    store.board.actionError = nil
                }
            }
        )
    }
}

/// 工作记录: the cards an assistant ran today, on every board, the latest first; under each, its
/// runs today: when, how each ended, and its handoff or error.
struct WorkLogView: View {
    @Environment(AppStore.self) private var store
    let entries: [WorkLogEntry]
    let selection: String?
    let open: (WorkLogEntry) -> Void

    var body: some View {
        let showsBoard = store.board.active && store.board.boards.count > 1
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "今天", count: entries.count)
                // a day's cards are few: laid out at once
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        Button { open(entry) } label: {
                            WorkLogRow(entry: entry, selected: entry.id == selection, showsBoard: showsBoard)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("work-\(entry.cardId)")
                        if entry.id != entries.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if entries.isEmpty {
                // the last data keeps the board's cards, not their runs
                let title: String = store.board.active || store.showsDemo ? "今天还没做过卡片" : "连上服务器后显示"
                ContentUnavailableView(title, systemImage: "list.bullet.rectangle")
            }
        }
        .accessibilityIdentifier("work-log")
    }
}

/// A card in the log: its title and where it stands now (archived since, too), its board when there
/// are several, and its runs today.
struct WorkLogRow: View {
    let entry: WorkLogEntry
    let selected: Bool
    let showsBoard: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.title)
                    .font(.t13.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if entry.status == KanbanWorkflow.archived {
                    Text("已归档").font(.t12).foregroundStyle(.secondary)
                } else {
                    CardStateTag(status: CardStatus(key: entry.status))
                }
            }
            if showsBoard, let name = entry.boardName {
                Text(name).font(.t12).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entry.runs) { run in
                    RunLine(run: run)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One run: its start and end, how it ended, and the handoff it left (or its error).
struct RunLine: View {
    let run: KanbanRun

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(run.spanText)
                    .font(.t12)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(run.outcomeText)
                    .font(.t12)
                    .foregroundStyle(run.outcome == "blocked" ? Palette.warm : Color.secondary)
            }
            if let note = run.summary ?? run.error {
                Text(note)
                    .font(.t12)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
