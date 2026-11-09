import SwiftUI

/// Everything assistants will not do without you.
struct ConfirmView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.asks.isEmpty {
                ContentUnavailableView("都处理完了", systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(store.asks) { ask in
                            AskCard(ask: ask)
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
        .navigationSubtitle(store.asks.isEmpty ? "" : "\(store.asks.count) 件")
    }
}
