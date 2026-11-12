import SwiftUI

/// Work handed to assistants on the Hermes kanban board. Five columns over Hermes's eight (排队,
/// 在做, 卡住, 待验收, 完成) share the width; never narrower than a card reads well, so with the
/// detail open, or in a narrow window, the board scrolls sideways instead of squeezing. A card
/// says only what tells it from its neighbours, and a click opens the rest beside the board; from
/// there it opens over the whole page, for a card with much to read, and back (CardDetail.swift).
/// Drag a card to move it, where the board's workflow allows.
struct BoardView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: String?
    @State private var showInspector = false
    /// The open card's detail over the whole page, the board behind it.
    @State private var expanded = false
    @State private var composing = false

    var body: some View {
        let items = store.boardItems
        content(items)
            .navigationTitle("看板")
            .navigationSubtitle(subtitle(items))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.board.active && store.board.boards.count > 1 {
                        BoardPicker()
                    }
                    Button {
                        composing = true
                    } label: {
                        Label("新建卡片", systemImage: "plus")
                    }
                    .help("新建卡片")
                    .disabled(store.readOnly)
                    .accessibilityIdentifier("new-card")
                }
            }
            .inspector(isPresented: beside) {
                if let item = chosen(items) {
                    CardDetail(item: item, resize: { expanded = true }, close: putAway) { open($0) }
                        .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
                }
            }
            .sheet(isPresented: $composing) {
                NewCardSheet { open($0) }
            }
            .alert("没能完成", isPresented: actionFailed) {
                Button("好") {}
            } message: {
                Text(store.board.actionError ?? "")
            }
            .onChange(of: selection) { _, id in
                store.board.select(id)
            }
            .onChange(of: store.board.slug) {
                selection = nil
                showInspector = false
                expanded = false
            }
            // a card asked for from elsewhere (a notification, 待你处理): open it once its board is up
            .task(id: "\(store.board.revealing?.id ?? "")|\(store.board.slug ?? "")|\(items.count)") {
                guard let wanted = store.board.revealing,
                      !store.board.active || wanted.board == nil || wanted.board == store.board.slug,
                      items.contains(where: { $0.id == wanted.id })
                else { return }
                store.board.revealing = nil
                open(wanted.id)
            }
    }

    @ViewBuilder
    private func content(_ items: [BoardItem]) -> some View {
        if store.board.active && !store.board.loaded {
            Group {
                if let error = store.board.loadError {
                    VStack(spacing: 10) {
                        Text("看板没有读到").font(.t15)
                        Text(error)
                            .font(.t12)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                        Button("再试一次") {
                            Task { await store.board.reload() }
                        }
                    }
                    .frame(maxWidth: 420)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if expanded, let item = chosen(items) {
            // back beside the board the card stays open; closed, the board is all there is
            CardDetail(item: item, wide: true, resize: { expanded = false }, close: putAway) { open($0) }
                .background(.background)
        } else {
            GeometryReader { space in
                // the width shared out, down to the narrowest a card reads well at
                let columns = CGFloat(CardStatus.allCases.count)
                let width = max(BoardColumn.narrowest, ((space.size.width - 32 - (columns - 1) * 10) / columns).rounded(.down))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(CardStatus.allCases, id: \.self) { group in
                            BoardColumn(group: group, items: items.filter { $0.group == group }, selection: selection,
                                        width: width) { open($0) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .frame(minHeight: space.size.height, alignment: .topLeading)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private func open(_ id: String) {
        selection = id
        showInspector = true
    }

    /// The detail away, from beside the board or over it; the card stays marked on the board.
    private func putAway() {
        showInspector = false
        expanded = false
    }

    private func chosen(_ items: [BoardItem]) -> BoardItem? {
        selection.flatMap { id in items.first { $0.id == id } }
    }

    /// The detail beside the board: put away while it is over the whole page.
    private var beside: Binding<Bool> {
        Binding(
            get: { showInspector && !expanded },
            set: { shown in
                if !expanded {
                    showInspector = shown
                }
            }
        )
    }

    private var actionFailed: Binding<Bool> {
        Binding(
            get: { store.board.actionError != nil },
            set: { shown in
                if !shown {
                    store.board.actionError = nil
                }
            }
        )
    }

    private func subtitle(_ items: [BoardItem]) -> String {
        let running = items.filter { $0.group == .running }.count
        // of the stuck, the ones only you can clear
        let yours = items.filter { $0.stuck?.yours == true }.count
        return yours > 0 ? "\(running) 件在做 · \(yours) 件等你" : "\(running) 件在做"
    }
}

/// The boards on the server, when there is more than one.
struct BoardPicker: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Menu {
            ForEach(store.board.boards) { board in
                Button {
                    store.board.switchTo(board.slug)
                } label: {
                    if board.slug == store.board.slug {
                        Label(board.name, systemImage: "checkmark")
                    } else {
                        Text(board.name)
                    }
                }
            }
        } label: {
            Label(store.board.currentBoard?.name ?? "看板", systemImage: "rectangle.stack")
                .labelStyle(.titleAndIcon)
        }
        .help("换一块看板")
        .accessibilityIdentifier("board-picker")
    }
}

struct BoardColumn: View {
    @Environment(AppStore.self) private var store
    let group: CardStatus
    let items: [BoardItem]
    let selection: String?
    let width: CGFloat
    let open: (String) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(group.label).font(.t13.weight(.semibold))
                Text("\(items.count)").font(.t12).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        BoardCard(item: item, selected: item.id == selection)
                            .onTapGesture { open(item.id) }
                            .draggable(item.id)
                            .contextMenu { moveMenu(item) }
                    }
                    if items.isEmpty {
                        Text("没有").font(.t12).foregroundStyle(.tertiary).padding(.horizontal, 4)
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
        }
        .padding(6)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            targeted ? Palette.accent.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let item = store.boardItem(id),
                  let key = store.boardTarget(for: item, into: group)
            else { return false }
            store.moveCard(id, to: key)
            return true
        } isTargeted: { hovering in
            targeted = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board-column-\(group.key)")
    }

    /// The narrowest a card still reads at, a title in three lines: five of them fit a window
    /// 1024 wide, so the board scrolls sideways only with the detail open beside it, or in a
    /// window narrower than that.
    static let narrowest: CGFloat = 144

    @ViewBuilder
    private func moveMenu(_ item: BoardItem) -> some View {
        Section("移到") {
            ForEach(store.boardTargets(for: item), id: \.self) { key in
                Button(store.boardLabel(key)) {
                    store.moveCard(item.id, to: key)
                }
            }
        }
    }
}

struct BoardCard: View {
    @Environment(AppStore.self) private var store
    let item: BoardItem
    var selected = false

    var body: some View {
        let bot = item.assignee.flatMap { store.bot($0) }
        VStack(alignment: .leading, spacing: 7) {
            if let stuck = item.stuck {
                // why it is stuck, before anything else: the ones that are yours stand out
                Text(stuck.label)
                    .font(.t11.weight(.medium))
                    .foregroundStyle(stuck.yours ? Palette.warm : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((stuck.yours ? Palette.warm : Color.secondary).opacity(0.12), in: Capsule())
                    .accessibilityIdentifier("card-stuck-\(item.id)")
            }
            Text(item.title)
                .font(.t13.weight(.medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            // one thing about it: how long, waiting on what, what came of it. The rest is a click away
            Text(item.line)
                .font(.t12)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Avatar(bot: bot, size: 16)
                Text(bot?.name ?? item.assignee ?? "未指派").font(.t12).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if let progress = item.progress {
                    Text(progress).font(.t11).monospacedDigit().foregroundStyle(.secondary)
                }
                if item.comments > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "text.bubble")
                        Text("\(item.comments)").monospacedDigit()
                    }
                    .font(.t11)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Palette.accent : Palette.line, lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-\(item.id)")
    }
}

/// A new card: what it is and who does it.
struct NewCardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let created: (String) -> Void
    @State private var title = ""
    @State private var detail = ""
    @State private var assignee = ""
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("标题", text: $title)
                        .accessibilityIdentifier("new-card-title")
                    TextField("内容", text: $detail, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("new-card-body")
                    Picker("交给", selection: $assignee) {
                        ForEach(store.boardAssignees, id: \.self) { id in
                            Text(store.bot(id)?.name ?? id).tag(id)
                        }
                    }
                    .accessibilityIdentifier("new-card-assignee")
                } header: {
                    Text("新建卡片")
                }
            }
            .formStyle(.grouped)
            if let failure {
                Text(failure)
                    .font(.t12)
                    .foregroundStyle(Palette.alert)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("交给助手") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty || sending)
                    .accessibilityIdentifier("new-card-create")
            }
            .padding(20)
        }
        .frame(width: 440)
        .onAppear {
            if assignee.isEmpty {
                assignee = store.bots.first(where: { !$0.chief })?.id ?? store.boardAssignees.first ?? ""
            }
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        let title = trimmedTitle
        let body = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let assignee = self.assignee.isEmpty ? nil : self.assignee
        sending = true
        failure = nil
        Task {
            do {
                let id = try await store.createCard(title: title, body: body, assignee: assignee)
                dismiss()
                if let id {
                    created(id)
                }
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}

/// How long ago, the way the board says it: 刚刚, 5 分钟前, 2 小时前, 昨天 21:06.
enum Ago {
    static func text(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if Fmt.dayDiff(date, now) == 0 { return "\(Int(seconds / 3600)) 小时前" }
        return Fmt.when(date, now: now)
    }
}
