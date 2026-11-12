import SwiftUI

/// A card's detail: where it stands and why (what it waits on, or what it handed in) first, then
/// what was asked, the comments and a way to answer, what comes before and after it and each
/// run; the id and the board last, in small type. Shown two ways, and `resize` goes from one to
/// the other:
/// - beside the board or an assistant's 工作记录, a column: a long description shows its start
///   and the runs are folded;
/// - over the whole page (`wide`), with room to read: what was asked as the Markdown it is
///   written in, every run in full, and, from the width two columns read well at, the runs and
///   the cards around it in a column of their own.
/// The card may be on another board than the board page's (工作记录 opens cards from all).
struct CardDetail: View {
    @Environment(AppStore.self) private var store
    let item: BoardItem
    var wide = false
    /// To the whole page, or back beside it.
    var resize: (() -> Void)?
    /// Puts the detail away, where a button of its own is the way to.
    var close: (() -> Void)?
    let open: (String) -> Void
    @State private var draft = ""
    /// Beside the page a long description shows its start; the whole on a click.
    @State private var wholeBody = false
    @State private var showsRuns = false

    /// The widest a column of text reads well at, and what the column beside it takes.
    private static let reading: CGFloat = 680
    private static let aside: CGFloat = 260
    private static let gap: CGFloat = 32
    /// The width from which the page is two columns: the first no narrower than the detail's
    /// widest beside the board.
    private static let split: CGFloat = 760

    var body: some View {
        GeometryReader { space in
            let split = wide && space.size.width >= Self.split
            ScrollView {
                page(split: split)
                    .frame(maxWidth: wide ? Self.reading + (split ? Self.gap + Self.aside : 0) : .infinity,
                           alignment: .leading)
                    .padding(wide ? 28 : 20)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("card-inspector")
        }
    }

    @ViewBuilder
    private func page(split: Bool) -> some View {
        let live = store.board.active
        let task = store.board.task(item.id, on: item.board)
        let detail = store.board.detail(item.id, on: item.board)
        let now = live ? store.board.serverNow : store.now
        VStack(alignment: .leading, spacing: 18) {
            head(task: task, now: now)
            if split {
                HStack(alignment: .top, spacing: Self.gap) {
                    VStack(alignment: .leading, spacing: 18) {
                        matter(task: task, detail: detail, live: live, now: now)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 18) {
                        around(detail: detail, live: live)
                    }
                    .frame(width: Self.aside, alignment: .leading)
                }
            } else {
                matter(task: task, detail: detail, live: live, now: now)
                around(detail: detail, live: live)
            }
        }
    }

    // MARK: what it is

    private func head(task: KanbanTask?, now: Date) -> some View {
        let bot = item.assignee.flatMap { store.bot($0) }
        return VStack(alignment: .leading, spacing: 8) {
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
                Spacer(minLength: 8)
                controls
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
    }

    /// To the whole page and back (Esc too, from the page), and away.
    @ViewBuilder
    private var controls: some View {
        if let resize {
            Button(action: resize) {
                HStack(spacing: 4) {
                    Image(systemName: wide ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    if wide {
                        Text("收回")
                    }
                }
                .font(.t12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(wide ? KeyboardShortcut.cancelAction : nil)
            .help(wide ? "收回到旁边（Esc）" : "展开到整页")
            .accessibilityLabel(wide ? "收回到旁边" : "展开到整页")
            .accessibilityIdentifier("card-resize")
        }
        if let close {
            Button(action: close) {
                Image(systemName: "xmark").font(.t12).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("关闭")
            .accessibilityLabel("关闭")
            .accessibilityIdentifier("card-close")
        }
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

    // MARK: where it stands, what was asked, what was said

    @ViewBuilder
    private func matter(task: KanbanTask?, detail: KanbanDetail?, live: Bool, now: Date) -> some View {
        // where it stands: what it waits on, or what it handed in
        if item.group == .stuck || (item.group == .queued && !archived) || !live {
            Callout(text: item.line, warm: item.stuck?.yours == true)
        }
        if live, item.status == "done" || item.status == "review" || archived,
           let delivered = detail?.summary ?? detail?.result ?? task?.latestSummary ?? task?.result {
            Callout(text: delivered, warm: false)
        }
        if let text = detail?.body ?? task?.body {
            asked(text)
        }
        if live {
            comments(detail, waiting: task.map { $0.status == "blocked" || BoardWork.looped($0) } ?? false, now: now)
        }
    }

    private func asked(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "交代的事")
            if wide {
                MarkdownView(blocks: MarkdownCache.shared.document("card-\(item.board ?? "")-\(item.id)", text).blocks)
                    .textSelection(.enabled)
            } else {
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

    // MARK: around it: the cards before and after, each run, what it is called

    @ViewBuilder
    private func around(detail: KanbanDetail?, live: Bool) -> some View {
        if live {
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

    /// Each time an assistant worked on it. Beside the page: how the last one ended, the rest on a
    /// click. Over the page: all of them, open.
    private func runsSection(_ all: [KanbanRun]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if wide {
                HStack(spacing: 6) {
                    Text("经过").font(.t15)
                    Text("\(all.count) 次").font(.t12).monospacedDigit().foregroundStyle(.secondary)
                }
                runs(all)
            } else {
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
    }

    private func runs(_ runs: [KanbanRun]) -> some View {
        VStack(alignment: .leading, spacing: wide ? 10 : 6) {
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
                            // the whole of it where there is room to read it
                            .lineLimit(wide ? nil : 3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
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
