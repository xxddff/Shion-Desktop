import SwiftUI

/// A card in a chat for something that happened around its messages (ChatEvent): the board's word
/// on a card, a message from or to another assistant, a background result, what the assistant's
/// review kept, a skill to look at. Each says what it is, in whose words, and when.
struct EventCard: View {
    @Environment(AppStore.self) private var store
    let item: ChatItem
    let event: ChatEvent

    var body: some View {
        switch event {
        case .board:
            BoardNoticeCard(item: item)
        case .received(let from):
            // the name it signed with, or (its answer to a message sent it) its handle: the assistant's name
            NoticeCard(symbol: "bubble.left.and.bubble.right", title: "\(store.bot(from)?.name ?? from) 发来的消息", item: item)
        case .sent(let to):
            NoticeCard(symbol: "paperplane", title: "发给\(store.bot(to)?.name ?? to)的消息", item: item)
        case .background:
            NoticeCard(symbol: "clock.arrow.circlepath", title: "后台任务有结果了", item: item)
        case .learned:
            NoticeCard(symbol: "sparkles", title: "自动沉淀", item: item)
        case .skill(let id):
            if let review = store.skillReview(id) {
                SkillReviewCard(review: review)
            }
        case .compaction(let state, let messages):
            CompactionCard(item: item, state: state, messages: messages)
        case .providerWait:
            WaitCard(item: item)
        case .fallback:
            // Hermes's own sentence says from which model to which, and why
            NoticeCard(symbol: "arrow.triangle.branch", title: "换了备用模型", item: item)
        case .goal:
            NoticeCard(symbol: "scope", title: "目标的进展", item: item)
        case .notice(let level, let key, let cleared):
            NoticeCard(symbol: Self.symbol(level), title: Self.noticeTitle(key), item: item,
                       note: cleared ? "Hermes 已经撤下了这条提醒" : nil, settled: cleared)
        case .aside(let question):
            NoticeCard(symbol: "questionmark.bubble", title: "顺带一问的回答", item: item,
                       lead: question.isEmpty ? nil : "问：\(question)")
        case .sideTask:
            NoticeCard(symbol: "square.stack.3d.up", title: "后台另做的事有结果了", item: item)
        case .resumed:
            NoticeCard(symbol: "arrow.clockwise", title: "接着做被打断的那一轮", item: item)
        }
    }

    /// A notice's title by what it is about: its key, as Hermes names it (`credits.usage`,
    /// `credits.depleted`, `startup-warning.…`); its words are Hermes's own.
    static func noticeTitle(_ key: String?) -> String {
        if key?.hasPrefix("credits.") == true { return "额度提醒" }
        if key?.hasPrefix("startup-warning.") == true { return "Hermes 启动时的提醒" }
        return "Hermes 的提醒"
    }

    static func symbol(_ level: String) -> String {
        switch level {
        case "warn": return "exclamationmark.triangle"
        case "error": return "xmark.octagon"
        case "success": return "checkmark.circle"
        default: return "info.circle"
        }
    }
}

/// What happened, and its words: a few lines, the rest on a click. `lead` goes above the words (a
/// side question's question), `note` under them; a notice Hermes took back is `settled`, its words
/// dimmed.
struct NoticeCard: View {
    let symbol: String
    let title: String
    let item: ChatItem
    var lead: String?
    var note: String?
    var settled = false
    @State private var whole = false

    private static let folded = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).font(.t12.weight(.medium))
                Spacer(minLength: 8)
                Text(Fmt.hm(item.at)).monospacedDigit()
            }
            .font(.t12)
            .foregroundStyle(.secondary)
            if let lead {
                FoundText(lead)
                    .font(.t12)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            // ⌘F marks what it finds in it (ChatControls.swift)
            FoundText(item.text)
                .font(.t13)
                .foregroundStyle(settled ? .secondary : .primary)
                .lineLimit(whole ? nil : Self.folded)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if long {
                Button(whole ? "收起" : "展开") {
                    whole.toggle()
                }
                .buttonStyle(.link)
                .font(.t12)
            }
            if let note {
                Text(note)
                    .font(.t12)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-card")
    }

    /// More than the folded lines can hold, roughly: lines, or a lot of words.
    private var long: Bool {
        item.text.count > 360 || item.text.split(separator: "\n", omittingEmptySubsequences: false).count > Self.folded
    }
}

/// The board's word on a card this chat made: the card as it is now (its chip follows the board),
/// and under it what happened then, in plain words, with what was handed in or why it stopped.
/// Once the board no longer lists the card (archived), the chip still says which it was, without
/// a status: by the title the notice gives, or the card's id (AppStore.chatCard).
struct BoardNoticeCard: View {
    @Environment(AppStore.self) private var store
    let item: ChatItem

    var body: some View {
        let outcome = Notices.kanbanOutcome(item.text)
        VStack(alignment: .leading, spacing: 6) {
            if let found = store.chatCard(item) {
                CardChip(card: found.card, showsStatus: found.known)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: outcome.stopped ? "pause.circle" : "arrow.turn.down.right")
                    .foregroundStyle(outcome.stopped ? Palette.warm : Color.secondary)
                FoundText(outcome.detail.map { "\(outcome.words)：\($0)" } ?? outcome.words)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(Fmt.hm(item.at)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.t12)
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board-notice")
    }
}

/// A compaction of the session (StatusCards.swift), one card from its first line to its end: under
/// way, with Hermes's line for it now; done, and once the transcript has its row, how many messages
/// it folded and the summary as Hermes gives it for reading, a few lines of it, the rest on a click;
/// or over without Hermes saying it is done.
struct CompactionCard: View {
    let item: ChatItem
    let state: ChatEvent.Compacting
    let messages: Int?
    @State private var whole = false

    private static let folded = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if state == .running {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: state == .done ? "archivebox" : "exclamationmark.circle")
                }
                Text(title).font(.t12.weight(.medium))
                Spacer(minLength: 8)
                Text(Fmt.hm(item.at)).monospacedDigit()
            }
            .font(.t12)
            .foregroundStyle(.secondary)
            Text(line)
                .font(.t13)
                .fixedSize(horizontal: false, vertical: true)
            if fromRow {
                // the summary, for reading; ⌘F marks what it finds in it (ChatControls.swift)
                if !item.text.isEmpty {
                    FoundText(item.text)
                        .font(.t12)
                        .foregroundStyle(.secondary)
                        .lineLimit(whole ? nil : Self.folded)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if long {
                        Button(whole ? "收起" : "展开摘要") {
                            whole.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.t12)
                    }
                }
            } else if state != .done, !item.text.isEmpty {
                // Hermes's own line for it now
                Text(item.text)
                    .font(.t12)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compaction-card")
        .accessibilityValue(state.rawValue)
    }

    /// The transcript's row, not the card that showed the compaction live: its words are the summary.
    private var fromRow: Bool { !item.id.hasPrefix(ChatStatus.compactionPrefix) }

    private var title: String {
        switch state {
        case .running: return "正在压缩对话"
        case .done: return "压缩了对话"
        case .ended: return "压缩没有完成"
        }
    }

    private var line: String {
        switch state {
        case .running: return "Hermes 正把更早的对话压缩成摘要，这时发的话可以排队或引导"
        case .done: return "更早的对话压缩成了摘要" + (messages.map { "（\($0) 条消息）" } ?? "")
        case .ended: return "Hermes 没说压缩好了，这次可能什么也没压缩"
        }
    }

    private var long: Bool {
        item.text.count > 240 || item.text.split(separator: "\n", omittingEmptySubsequences: false).count > Self.folded
    }
}

/// A wait for the model provider (StatusCards.swift), in Hermes's words, for as long as it lasts.
struct WaitCard: View {
    let item: ChatItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            VStack(alignment: .leading, spacing: 2) {
                Text("在等模型回话")
                    .font(.t12.weight(.medium))
                    .foregroundStyle(.secondary)
                FoundText(item.text)
                    .font(.t12)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(Fmt.hm(item.at)).monospacedDigit().font(.t12).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-wait")
    }
}
