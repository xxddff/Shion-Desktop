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
/// tabs in the toolbar. The chat stays underneath while the log is up, so a draft and where the
/// chat was scrolled to survive a look at the log. A card of the log opens on the side.
struct AssistantView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var tab = AssistantTab.launch
    /// The log's card open in the inspector.
    @State private var selection: String?
    @State private var showInspector = false

    var body: some View {
        let entries = tab == .work ? store.workLog(for: botId) : []
        ChatView(botId: botId)
            .disabled(tab == .work)
            .accessibilityHidden(tab == .work)
            .overlay {
                if tab == .work {
                    WorkLogView(entries: entries, selection: selection) { open($0) }
                        .background(.background)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("显示", selection: $tab) {
                        Text("Bot Chat").tag(AssistantTab.chat)
                        Text("工作记录").tag(AssistantTab.work)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("assistant-tabs")
                }
            }
            .inspector(isPresented: $showInspector) {
                if let entry = entries.first(where: { $0.id == selection }) {
                    BoardInspector(item: store.workItem(entry)) { id in
                        store.openCard(id, board: entry.board)
                    }
                }
            }
            .alert("没能完成", isPresented: actionFailed) {
                Button("好") {}
            } message: {
                Text(store.board.actionError ?? "")
            }
            .onChange(of: tab) { _, now in
                if now == .chat {
                    showInspector = false
                }
            }
    }

    private func open(_ entry: WorkLogEntry) {
        selection = entry.id
        showInspector = true
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
                        WorkLogRow(entry: entry, selected: entry.id == selection, showsBoard: showsBoard)
                            .onTapGesture { open(entry) }
                        if entry.id != entries.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("今天还没做过卡片", systemImage: "list.bullet.rectangle")
            }
        }
        .accessibilityIdentifier("work-log")
    }
}

/// A card in the log: its title and where it stands now, its board when there are several, and
/// its runs today.
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
                CardStateTag(status: CardStatus(key: entry.status))
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work-\(entry.cardId)")
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
