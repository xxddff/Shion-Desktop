import SwiftUI

/// Work handed to assistants on the Hermes kanban board: the server's once connected, the demo
/// cards until then. Four columns over Hermes's eight; drag a card to move it, where the board's
/// workflow allows; click one for its detail.
struct BoardView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: String?
    @State private var showInspector = false
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
                    .accessibilityIdentifier("new-card")
                }
            }
            .inspector(isPresented: $showInspector) {
                if let id = selection, let item = items.first(where: { $0.id == id }) {
                    BoardInspector(item: item) { open($0) }
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
            }
            // a card asked for from elsewhere (a notification, 等你确认): open it once its board is up
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
        } else {
            HStack(alignment: .top, spacing: 12) {
                ForEach(CardStatus.allCases, id: \.self) { group in
                    BoardColumn(group: group, items: items.filter { $0.group == group }, selection: selection) { open($0) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            // the columns' ideal width would otherwise be their longest title on one line, and the
            // split view sizes the window from it
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func open(_ id: String) {
        selection = id
        showInspector = true
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
        let waiting = items.filter { $0.group == .waiting }.count
        return waiting > 0 ? "\(running) 件在做 · \(waiting) 件等你" : "\(running) 件在做"
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
    let open: (String) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(group.label).font(.t13.weight(.semibold))
                Text("\(items.count)").font(.t12).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
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
        .frame(minWidth: 110, idealWidth: 150, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.t13.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(item.line)
                .font(.t12)
                .foregroundStyle(item.group == .waiting ? Palette.warm : Color.secondary)
                .lineLimit(5)
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
            .padding(.top, 2)
        }
        .padding(12)
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

/// A card's detail: what it is, what it is waiting on or delivered, its comments, what comes before
/// and after it, and each run. The id and the board go at the bottom, in small type. The card may
/// be on another board than the board page's (an assistant's 工作记录 opens cards from all).
struct BoardInspector: View {
    @Environment(AppStore.self) private var store
    let item: BoardItem
    let open: (String) -> Void
    @State private var draft = ""

    var body: some View {
        let live = store.board.active
        let task = store.board.task(item.id, on: item.board)
        let detail = store.board.detail(item.id, on: item.board)
        let bot = item.assignee.flatMap { store.bot($0) }
        let now = live ? store.board.serverNow : store.now
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if archived {
                            // only 工作记录 opens an archived card
                            Text("已归档").font(.t12).foregroundStyle(.secondary)
                        } else {
                            CardStateTag(status: item.group)
                            if store.boardLabel(item.status) != item.group.label {
                                Text(store.boardLabel(item.status)).font(.t12).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(item.title)
                        .font(.t20)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Avatar(bot: bot, size: 16)
                        Text(meta(bot: bot, task: task, now: now)).font(.t12).foregroundStyle(.secondary)
                    }
                }

                if let text = detail?.body ?? task?.body {
                    Text(text)
                        .font(.t13)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if item.group == .waiting || (item.group == .queued && !archived) || !live {
                    Callout(text: item.line, warm: item.group == .waiting)
                }
                if live, item.status == "done" || item.status == "review" || archived,
                   let delivered = detail?.summary ?? detail?.result ?? task?.latestSummary ?? task?.result {
                    Callout(text: delivered, warm: false)
                }

                if live {
                    comments(detail, waiting: task.map { $0.status == "blocked" || BoardWork.looped($0) } ?? false, now: now)
                    if let detail, !detail.parents.isEmpty || !detail.children.isEmpty {
                        links(detail)
                    }
                    if let detail, !detail.runs.isEmpty {
                        runs(detail.runs)
                    }
                    Text(technical)
                        .font(.t11)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                } else if !store.demoRuns(item.id).isEmpty {
                    runs(store.demoRuns(item.id))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        .accessibilityIdentifier("card-inspector")
    }

    private var archived: Bool { item.status == KanbanWorkflow.archived }

    private func meta(bot: Bot?, task: KanbanTask?, now: Date) -> String {
        var parts = ["\(bot?.name ?? item.assignee ?? "还没有人") 负责"]
        if let by = task?.createdBy {
            parts.append("\(store.boardAuthor(by))交代的")
        }
        if let at = task?.createdAt {
            parts.append(Ago.text(at, now: now))
        }
        return parts.joined(separator: " · ")
    }

    private var technical: String {
        var parts = ["编号 \(item.id)"]
        if let board = store.board.boardInfo(item.board) {
            parts.append("看板 \(board.slug)")
        }
        if let assignee = item.assignee {
            parts.append("profile \(assignee)")
        }
        return parts.joined(separator: " · ")
    }

    /// `waiting`: blocked, or moved to triage after it stopped on the same thing again; a comment
    /// then lets it go on.
    @ViewBuilder
    private func comments(_ detail: KanbanDetail?, waiting: Bool, now: Date) -> some View {
        let blocked = waiting
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "评论", count: detail?.comments.count)
            ForEach(detail?.comments ?? []) { comment in
                HStack(alignment: .top, spacing: 8) {
                    Avatar(bot: store.bot(comment.author), size: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(store.boardAuthor(comment.author))
                                .font(.t12.weight(.semibold))
                                .accessibilityIdentifier("comment-author-\(comment.id)")
                            if let at = comment.at {
                                Text(Ago.text(at, now: now)).font(.t11).foregroundStyle(.secondary)
                            }
                        }
                        Text(comment.body)
                            .font(.t13)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField(blocked ? "补充它需要的信息" : "留言", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send(resume: blocked) }
                    .accessibilityIdentifier("card-comment")
                Button(blocked ? "让它继续" : "发送") { send(resume: blocked) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("card-comment-send")
            }
        }
    }

    private func send(resume: Bool) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let id = item.id
        let board = item.board
        Task { await store.board.comment(id, text, resume: resume, on: board) }
    }

    private func links(_ detail: KanbanDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "前后")
            ForEach(detail.parents) { link in
                linkRow(link, side: "先做")
            }
            ForEach(detail.children) { link in
                linkRow(link, side: "接着")
            }
        }
    }

    private func linkRow(_ link: KanbanLink, side: String) -> some View {
        Button {
            open(link.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(side).font(.t12).foregroundStyle(.secondary)
                Text(link.title).font(.t13).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text(store.boardLabel(link.status)).font(.t12).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func runs(_ runs: [KanbanRun]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "经过")
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("第 \(index + 1) 次").font(.t12.weight(.medium))
                        Text(run.spanText).font(.t12).monospacedDigit().foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(run.outcomeText)
                            .font(.t12)
                            .foregroundStyle(run.outcome == "blocked" ? Palette.warm : Color.secondary)
                    }
                    if let note = run.error ?? run.summary {
                        Text(note)
                            .font(.t12)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// A line in a soft box: what the card is waiting on, or what it delivered.
private struct Callout: View {
    let text: String
    let warm: Bool

    var body: some View {
        Text(text)
            .font(.t13)
            .foregroundStyle(warm ? Palette.warm : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(warm ? Palette.warm.opacity(0.1) : Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
