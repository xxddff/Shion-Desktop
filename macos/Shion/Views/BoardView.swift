import SwiftUI

/// Work handed to assistants on the Hermes kanban board.
struct BoardView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                ForEach(CardStatus.allCases, id: \.self) { status in
                    BoardColumn(status: status, cards: cards(in: status))
                        .frame(minWidth: 160, maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(24)
        }
        .navigationTitle("看板")
        .navigationSubtitle(subtitle)
    }

    private func cards(in status: CardStatus) -> [Card] {
        store.cards.filter { $0.status == status }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var subtitle: String {
        let running = store.cards.filter { $0.status == .running }.count
        let waiting = store.cards.filter { $0.status == .waiting }.count
        return waiting > 0 ? "\(running) 件在做 · \(waiting) 件等你" : "\(running) 件在做"
    }
}

struct BoardColumn: View {
    let status: CardStatus
    let cards: [Card]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(status.label).font(.t13.weight(.semibold))
                Text("\(cards.count)").font(.t12).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            ForEach(cards) { card in
                BoardCard(card: card)
            }
            if cards.isEmpty {
                Text("没有").font(.t12).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
        }
    }
}

struct BoardCard: View {
    @Environment(AppStore.self) private var store
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title)
                .font(.t13.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(card.line)
                .font(.t12)
                .foregroundStyle(card.status == .waiting ? Palette.warm : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Avatar(bot: store.bot(card.assignee), size: 16)
                Text(store.bot(card.assignee)?.name ?? "").font(.t12).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
    }
}
