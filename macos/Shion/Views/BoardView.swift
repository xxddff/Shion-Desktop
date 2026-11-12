import SwiftUI

/// Work handed to assistants on the Hermes kanban board. Five columns over Hermes's eight (排队,
/// 在做, 卡住, 待验收, 完成) share the width; never narrower than a card reads well, so with the
/// detail open, or in a narrow window, the board scrolls sideways instead of squeezing. A card
/// says only what tells it from its neighbours, and a click opens the rest beside the board.
/// Drag a card to move it, where the board's workflow allows.
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
                    .disabled(store.readOnly)
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

    /// The narrowest a card reads well at: a title in two or three lines.
    static let narrowest: CGFloat = 184

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

/// A card's detail, beside the board and wide enough to read: where it stands and why (what it
/// waits on, or what it handed in) first, then what was asked, the comments and a way to answer,
/// and, folded until asked for, what comes before and after it and each run. The id and the board
/// go at the bottom, in small type. The card may be on another board than the board page's (an
/// assistant's 工作记录 opens cards from all).
struct BoardInspector: View {
    @Environment(AppStore.self) private var store
    let item: BoardItem
    let open: (String) -> Void
    @State private var draft = ""
    /// A long description shows its start; the whole on a click.
    @State private var wholeBody = false
    @State private var showsRuns = false

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
                            if let stuck = item.stuck {
                                Text(stuck.label).font(.t12).foregroundStyle(stuck.yours ? Palette.warm : Color.secondary)
                            } else if store.boardLabel(item.status) != item.group.label {
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

                // where it stands: what it waits on, or what it handed in
                if item.group == .stuck || (item.group == .queued && !archived) || !live {
                    Callout(text: item.line, warm: item.stuck?.yours == true)
                }
                if live, item.status == "done" || item.status == "review" || archived,
                   let delivered = detail?.summary ?? detail?.result ?? task?.latestSummary ?? task?.result {
                    Callout(text: delivered, warm: false)
                }

                if let text = detail?.body ?? task?.body {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(title: "交代的事")
                        Text(text)
                            .font(.t13)
                            .lineSpacing(2)
                            .lineLimit(wholeBody ? nil : 8)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if text.count > 320 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 8 {
                            Button(wholeBody ? "收起" : "展开全部") { wholeBody.toggle() }
                                .buttonStyle(.link)
                                .font(.t12)
                        }
                    }
                }

                if live {
                    comments(detail, waiting: task.map { $0.status == "blocked" || BoardWork.looped($0) } ?? false, now: now)
                    if let detail, !detail.parents.isEmpty || !detail.children.isEmpty {
                        links(detail)
                    }
                    if let detail, !detail.runs.isEmpty {
                        runsSection(detail.runs)
                    }
                    Text(technical)
                        .font(.t11)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                } else if !store.demoRuns(item.id).isEmpty {
                    runsSection(store.demoRuns(item.id))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
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
            // the last data, or the connection down: a comment waits for the server
            .disabled(store.readOnly)
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

    /// Each time an assistant worked on it: how it ended first, the rest on a click.
    private func runsSection(_ all: [KanbanRun]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsRuns.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("经过").font(.t15)
                    Text("\(all.count) 次").font(.t12).monospacedDigit().foregroundStyle(.secondary)
                    if !showsRuns, let last = all.last {
                        Text("· 最近一次\(last.outcomeText)").font(.t12).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: showsRuns ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("card-runs")
            if showsRuns {
                runs(all)
            }
        }
    }

    private func runs(_ runs: [KanbanRun]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
