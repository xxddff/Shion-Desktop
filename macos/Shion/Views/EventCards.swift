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
        }
    }
}

/// What happened, and its words: a few lines, the rest on a click.
struct NoticeCard: View {
    let symbol: String
    let title: String
    let item: ChatItem
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
            // ⌘F marks what it finds in it (ChatControls.swift)
            FoundText(item.text)
                .font(.t13)
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
