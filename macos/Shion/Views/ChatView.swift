import SwiftUI

/// An assistant's Bot Chat. The composer floats over the transcript, so it gets Liquid Glass.
struct ChatView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var draft = ""

    var body: some View {
        let bot = store.bot(botId)
        let items = store.chats[botId] ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ChatRow(item: item, bot: bot, showHead: showsHead(items, index))
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("还没有对话", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Composer(placeholder: "跟\(bot?.name ?? "")说…", text: $draft) {
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

    /// The assistant's name shows once per run of its messages, again after ten quiet minutes.
    private func showsHead(_ items: [ChatItem], _ index: Int) -> Bool {
        guard items[index].role == .assistant else { return false }
        guard index > 0 else { return true }
        let previous = items[index - 1]
        return previous.role != .assistant || items[index].at.timeIntervalSince(previous.at) > 600
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
            if let id = item.cardId, let card = store.card(id) {
                CardChip(card: card)
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
            Text(item.text)
                .font(.t13)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
