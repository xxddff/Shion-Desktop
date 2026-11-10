import SwiftUI

/// A message of yours the server does not have yet, as a chat shows it: lighter, with a line under
/// it saying where it is. Waiting for a connection (and since when: it goes out saying so when it
/// is late, QuickAskWaiting.swift); sent as the connection went, until the server can say whether
/// it has it; or 没发出去, with 重发 (AppStore+Reconnect.swift).
struct DeliveryMark: ViewModifier {
    @Environment(AppStore.self) private var store
    let item: ChatItem
    let botId: String
    /// A sentence waiting for a connection (QuickAsk.waiting), written then.
    var waiting: Date?

    @ViewBuilder
    func body(content: Content) -> some View {
        let state = item.role == .user ? store.deliveries.state(item.id) : nil
        if waiting != nil || (state != nil && state != .sending) {
            VStack(alignment: .trailing, spacing: 4) {
                content
                    .opacity(0.55)
                note(state)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(waiting == nil ? "delivery-\(item.id)" : "waiting-\(item.id)")
        } else {
            content
        }
    }

    private func note(_ state: Delivery?) -> some View {
        Group {
            if let waiting {
                Label("\(QuickAskWaiting.written(waiting, now: clock)) 写的 · 等连上服务器后发出", systemImage: "clock")
                    .accessibilityIdentifier("waiting")
            } else if case .unsent(let reason)? = state {
                HStack(spacing: 10) {
                    Label {
                        Text(reason.map { "没发出去：\($0)" } ?? "没发出去")
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Palette.alert)
                    }
                    .accessibilityIdentifier("unsent")
                    Button {
                        store.resend(item.id, in: botId)
                    } label: {
                        Label("重发", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canResend(botId))
                    .accessibilityIdentifier("resend")
                }
            } else {
                Label("等连上后确认", systemImage: "clock")
                    .accessibilityIdentifier("unsure")
            }
        }
        .font(.t12)
        .foregroundStyle(.secondary)
    }

    /// The real time with the server's data (live, or the last of it); the demo's day on the demo.
    private var clock: Date { store.live || store.lastData.shown ? Date() : store.demoClock }
}

/// What waits in this chat for a connection, under what has been said, oldest first: it waits
/// with the ⌥Space window's sentences (QuickAsk.swift).
struct WaitingMessages: View {
    let botId: String
    let bot: Bot?

    var body: some View {
        ForEach(QuickAsk.shared.sentences(for: botId)) { sentence in
            let item = ChatItem(id: sentence.id, role: .user, at: sentence.at, text: sentence.text)
            ChatRow(item: item, bot: bot, showHead: false)
                .modifier(DeliveryMark(item: item, botId: botId, waiting: sentence.at))
        }
    }
}
