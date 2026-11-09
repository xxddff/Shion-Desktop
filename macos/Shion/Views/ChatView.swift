import SwiftUI

/// An assistant's Bot Chat. The composer floats over the transcript, so it gets Liquid Glass.
struct ChatView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var draft = ""
    /// The visible height, which the transcript fills even when it is short.
    @State private var viewport: CGFloat = 0
    /// The transcript is too short to scroll, so its top is always in view.
    @State private var short = false
    /// Folded runs of tool calls opened by a click, by line id; not kept once the chat closes.
    @State private var openRuns: Set<String> = []
    /// Whether what comes next is followed down: the reader is at the newest message. Scrolled
    /// up, nothing moves under them until they are back at the end, or send something.
    @State private var follow = Follow()
    /// Where the rows in view are, so the one at the top stays put as older rows come in above.
    @State private var spots = RowSpots()
    /// Bumped as the transcript is made: once its rows are laid out, it goes to the newest one.
    @State private var placing = 0

    var body: some View {
        let bot = store.bot(botId)
        let items = store.chats[botId] ?? []
        let lines = ChatLine.lines(items, replying: store.replying.contains(botId))
        // older rows coming in above: where the row at the top of what shows was, from the layout
        // before they came
        let _ = spots.note(first: items.first?.id)
        Group {
            // the transcript is made once there is something in it: it starts at its newest
            // message with the rows there, and nothing has to be followed down to get there
            if items.isEmpty {
                Color.clear
            } else {
                ScrollViewReader { reader in
                    transcript(lines, bot: bot)
                        // made with its rows: at the newest one, now and once they are laid out;
                        // older pages wait until then
                        .onAppear {
                            follow.placed = false
                            toEnd(lines, with: reader)
                            placing += 1
                        }
                        .onChange(of: placing) {
                            toEnd(lines, with: reader)
                            follow.placed = true
                        }
                        // older rows arrived above: the row that was at the top of what shows goes
                        // back to where it was (a run of tool calls the page boundary cut is one
                        // line with the calls before it, under the same id)
                        .onChange(of: items.first?.id) { previous, _ in
                            guard let previous else { return }
                            if let held = spots.held, lines.contains(where: { $0.id == held.id }),
                               viewport > held.frame.height + 1 {
                                let anchor = UnitPoint(x: 0, y: held.frame.minY / (viewport - held.frame.height))
                                reader.scrollTo(held.id, anchor: anchor)
                            } else if let line = lines.first(where: { line in line.items.contains { $0.id == previous } }) {
                                reader.scrollTo(line.id, anchor: .top)
                            }
                        }
                        // a message came, a reply grew or finished, a call was made: followed down
                        // while the reader is at the end. Opening or closing a run changes none of
                        // this, so the transcript keeps its top and the run's line stays put.
                        .onChange(of: TranscriptEnd(lines)) {
                            guard follow.on, let last = lines.last else { return }
                            follow.until = Date().addingTimeInterval(1)
                            reader.scrollTo(last.id, anchor: .bottom)
                        }
                        // the reader scrolled: to the end, or away from it. When the content's
                        // height changed it was not the reader: the newest rows taking their real
                        // heights, followed for a moment after a message, or a run opening
                        .onScrollGeometryChange(for: EndGap.self) { geometry in
                            EndGap(below: geometry.contentSize.height - geometry.visibleRect.maxY,
                                   height: geometry.contentSize.height)
                        } action: { old, new in
                            if new.height == old.height {
                                follow.on = new.below <= 40
                            } else if follow.on, Date() < follow.until, new.below > 1, let last = lines.last {
                                reader.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                }
            }
        }
        .overlay {
            if let error = store.chatErrors[botId] {
                ContentUnavailableView("打不开这个对话", systemImage: "exclamationmark.bubble", description: Text(error))
            } else if store.openingChats.contains(botId) {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView("还没有对话", systemImage: "bubble.left.and.bubble.right")
            }
        }
        // opens the Bot Chat on the server once connected, and again after reconnecting
        .task(id: "\(botId)|\(store.live)|\(store.gateway.phase == .online)") {
            await store.openChat(botId)
        }
        .safeAreaInset(edge: .bottom) {
            Composer(placeholder: "跟\(bot?.name ?? "")说…", text: $draft) {
                // what one sends, and the reply to it, are followed down from wherever one was
                follow.on = true
                store.send(draft, to: botId)
                draft = ""
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 40)
            .padding(.bottom, 16)
        }
        .navigationTitle(bot?.name ?? "")
        .navigationSubtitle(bot?.title ?? "")
    }

    /// The rows, newest at the bottom. Older pages load as the top comes into view.
    private func transcript(_ lines: [ChatLine], bot: Bot?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if store.olderPages[botId] != nil || store.olderErrors[botId] != nil {
                    OlderMessages(botId: botId)
                }
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    row(line, at: index, of: lines, bot: bot)
                        // the margin below the newest line is part of it, so following it down
                        // shows the margin too
                        .padding(.bottom, index == lines.count - 1 ? 24 : 0)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .scrollView)
                        } action: { frame in
                            spots.frames[line.id] = frame
                        }
                        .onDisappear {
                            spots.frames[line.id] = nil
                        }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)
            .frame(maxWidth: 760)
            // a short chat sits at the bottom of a full-height page, not on a short one
            .frame(maxWidth: .infinity, minHeight: viewport, alignment: .bottom)
        }
        // no anchor: the content's top stays put as it grows or shrinks, and where it shows is
        // only ever set above (to the newest message, after it, back to the row in view); a short
        // chat sits at the bottom of the full-height frame
        .accessibilityIdentifier("transcript")
        // measured from the first layout on (a scroll geometry change only reports changes); the
        // size is already inside the toolbar and the composer
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            if abs(height - viewport) > 1 {
                viewport = max(0, height)
            }
        }
        // the next older page when the top comes into view, once the transcript was put at its end
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top < 400
        } action: { _, nearTop in
            if nearTop, follow.placed {
                Task { await store.loadOlder(botId) }
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height < geometry.containerSize.height + 400
        } action: { _, isShort in
            short = isShort
        }
        // a page too short to scroll leaves the top in view: the next one, once the rows are laid out
        .onChange(of: store.olderPages[botId]) {
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                if short {
                    await store.loadOlder(botId)
                }
            }
        }
    }

    /// To the newest line, and after it for a moment as the rows take their real heights.
    private func toEnd(_ lines: [ChatLine], with reader: ScrollViewProxy) {
        guard let last = lines.last else { return }
        follow.until = Date().addingTimeInterval(1)
        reader.scrollTo(last.id, anchor: .bottom)
    }

    @ViewBuilder
    private func row(_ line: ChatLine, at index: Int, of lines: [ChatLine], bot: Bot?) -> some View {
        switch line {
        case .item(let item):
            ChatRow(item: item, bot: bot, showHead: showsHead(lines, index))
        case .tools(let id, let tools):
            ToolRun(tools: tools, open: openRuns.contains(id)) {
                openRuns.formSymmetricDifference([id])
            }
        }
    }

    /// The assistant's name shows once per run of its messages, again after ten quiet minutes.
    private func showsHead(_ lines: [ChatLine], _ index: Int) -> Bool {
        guard case .item(let item) = lines[index], item.role == .assistant else { return false }
        guard index > 0, case .item(let previous) = lines[index - 1] else { return true }
        return previous.role != .assistant || item.at.timeIntervalSince(previous.at) > 600
    }
}

/// Whether a transcript follows its newest message down, and until when a change in its height
/// still comes from the newest message. Read in callbacks only, so nothing redraws for it.
final class Follow {
    var on = true
    var until = Date.distantPast
    /// Put at its newest message since it was made: until then no older page is asked for.
    var placed = false
}

/// Where the rows are in the transcript's visible part, by line id, as last laid out. Not
/// observed, so nothing redraws for it as the rows move.
final class RowSpots {
    var frames: [String: CGRect] = [:]
    /// The topmost row wholly below the top of what showed, and where it was, when the first row
    /// last changed.
    private(set) var held: (id: String, frame: CGRect)?
    private var first: String?

    /// Called as the transcript is made, before its rows are laid out: a new first row means older
    /// rows came in above, and the row at the top of what shows is noted from the layout before.
    func note(first: String?) {
        guard first != self.first else { return }
        self.first = first
        held = frames.filter { $0.value.minY >= 0 }
            .min { $0.value.minY < $1.value.minY }
            .map { (id: $0.key, frame: $0.value) }
    }
}

/// What changes at the end of a transcript as a turn goes on: a line comes, the last one grows
/// (a reply streaming in, its todos) or finishes. Older pages arriving above leave it as it is.
private nonisolated struct TranscriptEnd: Equatable {
    let last: String?
    let length: Int
    let streaming: Bool
    let todos: Int

    @MainActor
    init(_ lines: [ChatLine]) {
        last = lines.last?.id
        let item = lines.last?.items.last
        length = item?.text.utf8.count ?? 0
        streaming = item?.streaming ?? false
        todos = item?.todoIds.count ?? 0
    }
}

/// How far the content goes on below what shows, and how tall it is.
private nonisolated struct EndGap: Equatable {
    let below: CGFloat
    let height: CGFloat
}

/// The top of a paged transcript: a spinner while the next older page loads, or why it did not.
struct OlderMessages: View {
    @Environment(AppStore.self) private var store
    let botId: String

    var body: some View {
        HStack(spacing: 8) {
            if let error = store.olderErrors[botId] {
                Text("更早的消息没加载出来：\(error)")
                    .font(.t12)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("重试") {
                    Task { await store.retryOlder(botId) }
                }
                .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .opacity(store.loadingOlder.contains(botId) ? 1 : 0.4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

struct ChatRow: View {
    @Environment(AppStore.self) private var store
    let item: ChatItem
    let bot: Bot?
    let showHead: Bool

    var body: some View {
        switch item.role {
        case .system:
            Text(item.text)
                .font(.t12)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        case .card:
            if let found = store.chatCard(item) {
                CardChip(card: found.card, showsStatus: found.known)
            } else if !item.text.isEmpty {
                // the board's notice about a card it no longer lists
                Text(item.text)
                    .font(.t12)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(item.text)
                    .font(.t13)
                    .foregroundStyle(Palette.onAccent)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .assistant:
            AssistantMessage(item: item, bot: bot, showHead: showHead)
        case .tool:
            ToolLine(text: item.text)
        }
    }
}

/// One tool call: the tool, and what it was called on.
struct ToolLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "wrench.adjustable")
            .font(.t12)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// A finished run of tool calls as one line (ChatLines.swift); a click opens it to the calls.
struct ToolRun: View {
    let tools: [ChatItem]
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Label(tools.toolSummary, systemImage: "wrench.adjustable")
                        .lineLimit(1)
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .font(.t12)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tool-run")
            if open {
                ForEach(tools) { tool in
                    ToolLine(text: tool.text)
                        .padding(.leading, 18)
                }
            }
        }
    }
}

struct AssistantMessage: View {
    @Environment(AppStore.self) private var store
    let item: ChatItem
    let bot: Bot?
    let showHead: Bool

    var body: some View {
        let todos = item.todoIds.compactMap { store.todo($0) }
        VStack(alignment: .leading, spacing: 6) {
            if showHead {
                HStack(spacing: 6) {
                    Avatar(bot: bot, size: 18)
                    Text(bot?.name ?? "").font(.t12.weight(.semibold))
                    Text(Fmt.hm(item.at)).font(.t12).foregroundStyle(.secondary)
                }
            }
            if item.text.isEmpty && item.streaming {
                BusyDots()
            } else if item.streaming {
                StreamingReply(id: item.id, text: item.text)
            } else {
                // parsed once per text (MarkdownCache); a block at a time selects
                MarkdownView(blocks: MarkdownCache.shared.document(item.id, item.text).blocks)
                    .textSelection(.enabled)
            }
            if !todos.isEmpty {
                VStack(spacing: 0) {
                    ForEach(todos) { todo in
                        TodoRow(todo: todo)
                    }
                }
                .padding(.horizontal, 12)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
            }
        }
    }
}

struct Composer: View {
    let placeholder: String
    @Binding var text: String
    let send: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .onSubmit(send)
                .padding(.vertical, 7)
                .accessibilityIdentifier("composer")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("发送")
            .accessibilityIdentifier("send")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
