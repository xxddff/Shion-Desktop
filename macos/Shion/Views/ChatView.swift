import SwiftUI

/// An assistant's Bot Chat. The composer floats over the transcript, so it gets Liquid Glass.
struct ChatView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    /// The visible height, which the transcript fills even when it is short.
    @State private var viewport: CGFloat = 0
    /// The transcript is too short to scroll, so its top is always in view.
    @State private var short = false
    /// Folded runs of tool calls opened by a click, by line id; not kept once the chat closes.
    @State private var openRuns: Set<String> = []
    /// Whether what comes next is followed down: the reader is at the newest message. Scrolled
    /// up, nothing moves under them until they are back at the end, or send something.
    @State private var follow = Follow()
    /// Where the transcript shows between updates: the row at the top put back as older rows
    /// come in above, the find bar's hits gone to, in that order (TranscriptPlace).
    @State private var place = TranscriptPlace()
    /// Bumped as the transcript is made, and as its lines change while its end is followed: once
    /// its rows are laid out, it goes to the newest one.
    @State private var placing = 0
    /// ⌘F (ChatControls.swift)
    @State private var find = ChatFind()
    /// Bumped as the find bar closes: the composer takes the keys back (KeyTarget).
    @State private var composerKeys = 0
    /// Scrolls as little as it takes to show a whole row, for the rows themselves (a failed turn's
    /// 详情 opening).
    @State private var reveal = RowReveal()

    var body: some View {
        let bot = store.bot(botId)
        // and under them, what was said while not connected, waiting (ChatDelivery.swift)
        let items = store.shownChat(botId) + WaitingMessages.items(for: botId)
        let lines = ChatLine.lines(items, replying: store.replying.contains(botId))
        let found = find.found(in: lines)
        // before the rows are laid out: older rows coming in above (the row at the top of what
        // shows is noted, from the layout before them), or a new hit of the find bar
        let _ = place.note(first: items.first?.id, focus: found.focus, following: follow.on)
        Group {
            // the transcript is made once there is something in it: it starts at its newest
            // message with the rows there, and nothing has to be followed down to get there
            if items.isEmpty {
                Color.clear
            } else {
                ScrollViewReader { reader in
                    transcript(lines, bot: bot, found: found)
                        // made with its rows: at the newest one, now and once they are laid out;
                        // older pages wait until then
                        .onAppear {
                            reveal.proxy = reader
                            place.proxy = reader
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
                        .onChange(of: items.first?.id) {
                            settle(lines)
                        }
                        // a message came, a reply grew or finished, a call was made: followed down
                        // while the reader is at the end. Opening or closing a run changes none of
                        // this, so the transcript keeps its top and the run's line stays put.
                        .onChange(of: TranscriptEnd(lines, retry: store.retryTarget(botId))) {
                            guard follow.on, let last = lines.last else { return }
                            follow.until = Date().addingTimeInterval(1)
                            reader.scrollTo(last.id, anchor: .bottom)
                        }
                        // the lines themselves changed while the end is followed: a turn's calls
                        // fold into one line as it ends, a row comes or goes, the last one is there
                        // again under its row's id. The scroll asked for in the update that changed
                        // them lands short of the new end, by the folded line's height (run 181: a
                        // reply's last words under the composer; the 重试 every finished turn used
                        // to have was what hid there). Once more, then, when the rows are laid out
                        .onChange(of: LineShape(lines)) {
                            guard follow.on else { return }
                            Task {
                                try? await Task.sleep(for: .milliseconds(60))
                                if follow.on {
                                    placing += 1
                                }
                            }
                        }
                        // the reader scrolled: to the end, or away from it. When the content's
                        // height changed it was not the reader: the newest rows taking their real
                        // heights, followed for a moment after a message, or a run opening
                        .onScrollGeometryChange(for: EndGap.self) { geometry in
                            EndGap(below: geometry.contentSize.height - geometry.visibleRect.maxY,
                                   height: geometry.contentSize.height,
                                   container: geometry.containerSize.height)
                        } action: { old, new in
                            // not the reader either: the visible part changed height (the window,
                            // the composer, the page's host). Followed, it goes back to the end. A
                            // jump to the top in one go (Home, ⌘↑, the scroll bar) is the reader's
                            // and stays where it went
                            if follow.on, abs(new.container - old.container) > 1 {
                                toEnd(lines, with: reader)
                            } else if new.height == old.height {
                                follow.on = new.below <= 40
                            } else if follow.on, Date() < follow.until, new.below > 1, let last = lines.last {
                                reader.scrollTo(last.id, anchor: .bottom)
                            }
                            place.scrolled()
                        }
                        // the find bar's hit in view
                        .onChange(of: found.focus) {
                            settle(lines)
                        }
                        .environment(\.rowReveal, reveal)
                        // the message a notification was about, from its top (Landing.swift), gone
                        // to as a hit is (TranscriptPlace.land); what comes next is not followed down
                        .landing(botId, lines: lines) { line in
                            follow.on = false
                            place.land(line)
                        }
                }
            }
        }
        .overlay(alignment: .top) {
            ChatFindBar(find: find, found: found, botId: botId) {
                // the keys go back to the composer as the bar goes
                composerKeys += 1
                find.close()
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
            ChatComposer(botId: botId, keys: composerKeys) { send in
                // what one sends, and the reply to it, are followed down from wherever one was;
                // a send that does not go (a picture still going up) leaves following as it was
                let following = follow.on
                follow.on = true
                if !send() {
                    follow.on = following
                }
            }
            // not connected, what is said waits under the chat (AppStore+Reconnect.swift)
            .disabled(store.readOnly && !store.waits(botId))
            .frame(maxWidth: 720)
            .padding(.horizontal, 40)
            .padding(.bottom, 16)
        }
        // a message marked to answer: the composer takes the keys
        .onChange(of: store.replyTarget(for: botId)?.id) { _, marked in
            if marked != nil {
                composerKeys += 1
            }
        }
        // dropped and pasted pictures and files go to the composer
        .chatAttachments(botId)
        .environment(\.chatBotId, botId)
        .navigationTitle(bot?.name ?? "")
        .navigationSubtitle(bot?.title ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                FindButton(find: find)
            }
        }
    }

    /// The rows, newest at the bottom. Older pages load as the top comes into view.
    private func transcript(_ lines: [ChatLine], bot: Bot?, found: Found) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if store.olderPages[botId] != nil || store.olderErrors[botId] != nil {
                    OlderMessages(botId: botId)
                }
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    row(line, at: index, of: lines, bot: bot)
                        .environment(\.findMarks, found.marks(line))
                        // the margin below the newest line is part of it, so following it down
                        // shows the margin too
                        .padding(.bottom, index == lines.count - 1 ? 24 : 0)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .scrollView)
                        } action: { frame in
                            place.laidOut(line.id, at: frame)
                        }
                        .onDisappear {
                            place.gone(line.id)
                        }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)
            .frame(maxWidth: 760)
            // a short chat sits at the bottom of a full-height page, not on a short one
            .frame(maxWidth: .infinity, minHeight: viewport, alignment: .bottom)
        }
        // not anchored, where it starts either: the content's top stays put as it grows or shrinks,
        // and where it shows is only ever set above (to the newest message, after it, back to the
        // row in view, to a hit); a short chat sits at the bottom of the full-height frame.
        // Anchored at its bottom where it started, a transcript made again (the chat read again on
        // reconnecting) with a reply taller than what shows a little above its end came up blank:
        // its content counted about that reply too tall, its end past the rows (runs 146 and 149;
        // main, without the anchor, did not, run 150). Known: put in a split view's inspector (no
        // page is), the transcript opens at its top, the host setting its scroll view up again
        // after it went to its end (runs 152 and 153)
        .accessibilityIdentifier("transcript")
        // measured from the first layout on (a scroll geometry change only reports changes); the
        // size is already inside the toolbar and the composer
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            place.viewport = max(0, height)
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

    /// Older rows arrived above, or the find bar has a new hit: where the transcript shows then
    /// (TranscriptPlace). A hit opens its folded tool calls, and what comes next is not followed
    /// down from it.
    private func settle(_ lines: [ChatLine]) {
        // followed at its end, rows changing at the top (a page read there, the chat read again
        // on reconnecting) leave it at its end, with the follow
        if place.keepsEnd(), let reader = place.proxy {
            toEnd(lines, with: reader)
        }
        guard let hit = place.settle(lines) else { return }
        follow.on = false
        if hit.hasPrefix("tools-") {
            openRuns.insert(hit)
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
                // waiting, unsure or not sent (ChatDelivery.swift)
                .modifier(DeliveryMark(item: item, botId: botId))
                // copy it, answer it (ChatComposer.swift)
                .modifier(MessageActions(item: item, botId: botId))
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

/// Where a transcript shows, between updates, and in what order it is moved there. Older rows
/// coming in above put the row that was at the top of what showed back where it was, unless it
/// was followed at its end, where it stays (the chat read again on reconnecting is such a change
/// at the top, and the end changes with it); a new hit of the find bar is gone to. When both come in one update the hit is gone to and nothing is put
/// back; a hit that comes while a row is on its way back waits until that row is laid out where
/// it was (or the scroll geometry has changed a few times without it). A hit gone to is looked
/// for in the layouts after: not in view (going a long way through rows not laid out yet can land
/// short), it is gone to again, three times at most. A line asked for from outside the transcript
/// (land: a notification's message) is gone to the same way, to the top of what shows rather than
/// its middle, and is in view once its top is. Not observed, so nothing redraws for it.
final class TranscriptPlace {
    var proxy: ScrollViewProxy?
    /// The transcript's visible height.
    var viewport: CGFloat = 0
    /// Each row's frame in the visible part, by line id, as last laid out.
    private var frames: [String: CGRect] = [:]
    private var first: String?
    private var focus: String?
    /// For this update's onChange handlers (settle).
    private var restore: Restore?
    private var hit: String?
    /// Put back, not yet seen where it was: the line, where, and the scroll geometry changes since.
    private var restoring: (id: String, y: CGFloat, changes: Int)?
    /// A hit waiting for that.
    private var queued: String?
    /// Gone to, not yet seen in view: the line, the scroll geometry changes since, and the tries.
    private var going: (id: String, changes: Int, tries: Int)?
    /// The line last asked for from outside (land): gone to the top, in view by its top.
    private var landing: String?

    private enum Restore {
        /// The row at the top of what showed, and its frame then.
        case row(String, CGRect)
        /// No row was laid out: the line holding the old first item goes to the top.
        case line(holding: String)
        /// Followed at its end, it stays there (ChatView's settle).
        case end
    }

    /// Called as the transcript is made, before its rows are laid out.
    func note(first: String?, focus: String?, following: Bool) {
        if focus != self.focus {
            self.focus = focus
            hit = focus
            if focus == nil {
                queued = nil
                going = nil
            }
        }
        guard first != self.first else { return }
        let previous = self.first
        self.first = first
        guard let previous, hit == nil else {
            restore = nil
            return
        }
        restore = following ? .end : topInView().map { .row($0.id, $0.frame) } ?? .line(holding: previous)
    }

    /// Whether the transcript is to stay at its end as rows changed at its top: then that is
    /// taken, and settle puts nothing back.
    func keepsEnd() -> Bool {
        guard case .end? = restore else { return false }
        restore = nil
        return true
    }

    /// From the update's onChange handlers, both: whichever runs first does it. The row put back,
    /// or the hit gone to, or queued behind a row still on its way back. Returns a hit newly asked
    /// for.
    func settle(_ lines: [ChatLine]) -> String? {
        if let restore {
            self.restore = nil
            put(restore, lines)
        }
        guard let hit else { return nil }
        self.hit = nil
        if let back = restoring, let frame = frames[back.id], abs(frame.minY - back.y) <= 1 {
            restoring = nil
        }
        if restoring == nil {
            go(hit)
        } else {
            queued = hit
        }
        return hit
    }

    /// From outside the transcript: a notification's message (Landing.swift), to the top of what
    /// shows. Like a hit: after a row on its way back, and again while its top is not in view.
    func land(_ id: String) {
        landing = id
        if restoring == nil {
            go(id)
        } else {
            queued = id
        }
    }

    /// A row laid out.
    func laidOut(_ id: String, at frame: CGRect) {
        frames[id] = frame
        if let back = restoring, back.id == id, abs(frame.minY - back.y) <= 1 {
            restored()
        }
        if let going, going.id == id, shows(id, frame) {
            self.going = nil
        }
    }

    /// A row no longer laid out.
    func gone(_ id: String) {
        frames[id] = nil
    }

    /// The transcript scrolled, or its content's height changed.
    func scrolled() {
        if var back = restoring {
            back.changes += 1
            if let frame = frames[back.id], abs(frame.minY - back.y) <= 1 {
                restored()
            } else if back.changes >= 3 {
                restored()
            } else {
                restoring = back
            }
        }
        guard var going else { return }
        if let frame = frames[going.id], shows(going.id, frame) {
            self.going = nil
            return
        }
        going.changes += 1
        guard going.changes >= 2 else {
            self.going = going
            return
        }
        guard going.tries < 3 else {
            self.going = nil
            return
        }
        self.going = (going.id, 0, going.tries + 1)
        proxy?.scrollTo(going.id, anchor: anchor(going.id))
    }

    private func put(_ restore: Restore, _ lines: [ChatLine]) {
        switch restore {
        case .row(let id, let frame):
            guard lines.contains(where: { $0.id == id }) else { return }
            // scrollTo puts the row's unit point y on the same point of what shows, so its top goes
            // to y·(viewport − height): back where it was, a row taller than what shows (a long
            // reply) too. One as tall as what shows (within a point) can only go to the top
            let room = viewport - frame.height
            let top = abs(room) > 1 ? frame.minY : 0
            proxy?.scrollTo(id, anchor: UnitPoint(x: 0, y: abs(room) > 1 ? frame.minY / room : 0))
            restoring = (id, top, 0)
        case .line(let item):
            guard let line = lines.first(where: { line in line.items.contains { $0.id == item } }) else { return }
            proxy?.scrollTo(line.id, anchor: .top)
        case .end:
            break
        }
    }

    private func restored() {
        restoring = nil
        if let queued {
            self.queued = nil
            go(queued)
        }
    }

    private func go(_ id: String) {
        if id != landing {
            landing = nil
        }
        going = (id, 0, 1)
        proxy?.scrollTo(id, anchor: anchor(id))
    }

    /// A hit to the middle of what shows; a line asked for from outside to the top.
    private func anchor(_ id: String) -> UnitPoint {
        id == landing ? .top : .center
    }

    /// In view: any of a hit; the top of a line asked for from outside.
    private func shows(_ id: String, _ frame: CGRect) -> Bool {
        id == landing ? frame.minY >= -1 && frame.minY < viewport : frame.maxY > 0 && frame.minY < viewport
    }

    /// The topmost row starting in what shows, and where it is; none starting there (a reply taller
    /// than what shows), the one across its top.
    private func topInView() -> (id: String, frame: CGRect)? {
        let starting = frames.filter { $0.value.minY >= 0 && $0.value.minY < viewport }
            .min { $0.value.minY < $1.value.minY }
        let across = frames.filter { $0.value.minY < 0 && $0.value.maxY > 0 }
            .min { $0.value.minY < $1.value.minY }
        return (starting ?? across).map { (id: $0.key, frame: $0.value) }
    }
}

/// Which lines a transcript has, as far as where its end is goes: how many, and the last one.
private nonisolated struct LineShape: Equatable {
    let count: Int
    let last: String?

    @MainActor
    init(_ lines: [ChatLine]) {
        count = lines.count
        last = lines.last?.id
    }
}

/// What changes at the end of a transcript as a turn goes on: a line comes, the last one grows
/// (a reply streaming in, its todos) or finishes, 已停止 or 重试 comes under it. Older pages
/// arriving above leave it as it is.
private nonisolated struct TranscriptEnd: Equatable {
    let last: String?
    let length: Int
    let streaming: Bool
    let todos: Int
    let stopped: Bool
    /// The line 重试 goes under (AppStore.retryTarget).
    let retry: String?

    @MainActor
    init(_ lines: [ChatLine], retry: String?) {
        last = lines.last?.id
        let item = lines.last?.items.last
        length = item?.text.utf8.count ?? 0
        streaming = item?.streaming ?? false
        todos = item?.todoIds.count ?? 0
        stopped = item?.stopped ?? false
        self.retry = retry
    }
}

/// Scrolls a chat as little as it takes to show a whole row. ChatView hands it to its rows;
/// elsewhere, as in the ⌥Space window, there is none. Not observed.
final class RowReveal {
    var proxy: ScrollViewProxy?

    /// After the update that changed the row, so the whole of it is laid out.
    func show(_ id: String) {
        Task {
            self.proxy?.scrollTo(id)
        }
    }
}

nonisolated private struct RowRevealKey: EnvironmentKey {
    static let defaultValue: RowReveal? = nil
}

nonisolated extension EnvironmentValues {
    /// Set on a chat's transcript (ChatView).
    var rowReveal: RowReveal? {
        get { self[RowRevealKey.self] }
        set { self[RowRevealKey.self] = newValue }
    }
}

/// How far the content goes on below what shows, how tall it is, and how tall what shows is.
private nonisolated struct EndGap: Equatable {
    let below: CGFloat
    let height: CGFloat
    let container: CGFloat
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
            TurnNote(item: item, botId: bot?.id ?? "")
        case .card:
            if let event = item.event {
                // something that happened: the board's word, another assistant's message… (EventCards.swift)
                EventCard(item: item, event: event)
            } else if let askId = item.askId {
                // a password or a key the assistant asked for, or what became of an ask (SecretCard.swift)
                AskTrailCard(askId: askId)
            } else if let found = store.chatCard(item) {
                CardChip(card: found.card, showsStatus: found.known)
            } else if !item.text.isEmpty {
                // the board's notice about a card it no longer lists
                FoundText(item.text)
                    .font(.t12)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        case .user:
            // with the pictures and files you sent (ChatMediaViews.swift)
            UserMessage(item: item)
        case .assistant:
            AssistantMessage(item: item, bot: bot, showHead: showHead)
        case .tool:
            ToolCall(item: item)
        }
    }
}

/// One tool call: the tool, and what it was called on.
struct ToolLine: View {
    let text: String

    var body: some View {
        Label {
            FoundText(text)
        } icon: {
            Image(systemName: "wrench.adjustable")
        }
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
                    ToolCall(item: tool)
                        .padding(.leading, 18)
                }
            } else {
                // the run's screenshots, small
                RunShots(tools: tools)
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
            if item.streaming && (item.text.isEmpty || Silence.mayBecomeMarker(item.text)) {
                // nothing yet, or what may still turn out to be the marker for nothing to say
                BusyDots()
            } else if item.streaming {
                StreamingReply(id: item.id, text: ReplyMedia.streamingText(item.text))
            } else {
                // parsed once per text (MarkdownCache); a block at a time selects. What the reply
                // hands over (MEDIA:, server paths, its pictures) is laid out under it
                let reply = ReplyMediaCache.shared.parsed(item.id, item.text)
                MarkdownView(blocks: MarkdownCache.shared.document(item.id, reply.text).blocks)
                    .textSelection(.enabled)
                if !reply.media.isEmpty {
                    DeliveredMedia(media: reply.media)
                }
            }
            ReplyFooter(item: item, botId: bot?.id ?? "")
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
    /// Whether it can send now; nil: once there are words.
    var canSend: Bool?
    let send: () -> Void
    /// While a turn runs: the stop button (⌘.), before send.
    var stop: (() -> Void)?
    var stopping = false
    /// While a turn runs: how what is sent now reaches the assistant (BusyModeMenu).
    var busy: Binding<BusyMode>?
    /// Bumped to give it the keys: the chat does as its find bar closes.
    var keys = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .onSubmit(send)
                .padding(.vertical, 7)
                .accessibilityIdentifier("composer")
                // the keys, when the chat gives them back
                .background(KeyTarget(request: keys))
                // Return sends; ⇧Return breaks the line (KeyField.swift)
                .background(LineBreakKey())
            if let busy {
                BusyModeMenu(mode: busy)
            }
            if let stop {
                StopButton(stopping: stopping, action: stop)
            }
            // there during a turn too: what is sent then waits, or goes into the turn (BusyMode)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!(canSend ?? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            .accessibilityLabel("发送")
            .accessibilityIdentifier("send")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
