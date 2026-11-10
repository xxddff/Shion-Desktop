import SwiftUI

/// Everything assistants will not do without you: approvals and questions, then the board cards
/// that stopped on your answer.
struct ConfirmView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let cards = store.cardAsks
        Group {
            if store.asks.isEmpty && cards.isEmpty {
                ContentUnavailableView("都处理完了", systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(store.asks) { ask in
                            AskCard(ask: ask)
                        }
                        ForEach(cards) { card in
                            CardAskView(ask: card)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("等你确认")
        .navigationSubtitle(store.asks.count + cards.count == 0 ? "" : "\(store.asks.count + cards.count) 件")
    }
}
