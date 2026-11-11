import SwiftUI

/// Everything assistants will not do without you: approvals and questions, then the board cards
/// that stopped on your answer. The one a notification was about is outlined (Landing.swift).
struct ConfirmView: View {
    @Environment(AppStore.self) private var store
    /// The approval or question a notification opened, until you leave the page.
    @State private var selected: String?
    @State private var scrolls = 0

    var body: some View {
        let cards = store.cardAsks
        Group {
            if store.confirmCount == 0 {
                ContentUnavailableView("都处理完了", systemImage: "checkmark.circle")
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(store.todos.filter { $0.proposed && !$0.done }) { todo in
                            Box { TodoRow(todo: todo, showDay: true) }
                        }
                        ForEach(store.skillReviews.filter { $0.status == "pending" }) { review in
                            SkillReviewCard(review: review)
                        }
                        ForEach(store.asks) { ask in
                                if ask.kind == .secret {
                                    // a password's or a key's card is one element already, named for
                                    // its request (SecretCard.swift): marked selected as it is, since
                                    // a container around it would take its name
                                    AskCard(ask: ask)
                                        .landed(selected == ask.id)
                                        .accessibilityAddTraits(selected == ask.id ? .isSelected : [])
                                        .accessibilityValue(selected == ask.id ? "已选中" : "")
                                        .id(ask.id)
                                } else {
                                    AskCard(ask: ask)
                                        .landed(selected == ask.id)
                                        .accessibilityElement(children: .contain)
                                        .accessibilityAddTraits(selected == ask.id ? .isSelected : [])
                                        .accessibilityValue(selected == ask.id ? "已选中" : "")
                                        .accessibilityIdentifier("ask-\(ask.id)")
                                        .id(ask.id)
                                }
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
                    // a notification's approval or question, once it is here (after a click that
                    // started Shion, once connected), in view once the cards are laid out
                    .task(id: "\(String(describing: Landings.shared.pending(on: .confirm)))|\(store.asks.map(\.id))") {
                        guard case .ask(_, let id)? = Landings.shared.pending(on: .confirm),
                              store.asks.contains(where: { $0.id == id })
                        else { return }
                        selected = id
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        scrolls += 1
                        // last: clearing it starts this task anew
                        Landings.shared.pending = nil
                    }
                    .onChange(of: scrolls) {
                        if let selected {
                            reader.scrollTo(selected, anchor: .center)
                        }
                    }
                }
            }
        }
        .navigationTitle("待你处理")
        .navigationSubtitle(store.confirmCount == 0 ? "" : "\(store.confirmCount) 件")
    }
}
