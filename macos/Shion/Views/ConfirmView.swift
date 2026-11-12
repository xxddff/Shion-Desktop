import SwiftUI

/// Everything that waits on you, under what it asks of you: 授权操作 (a command to allow, a
/// password or a key, a card that lacks an account), 回答问题 (an assistant's question, a card
/// stopped on something only you know), 确认时间 (a todo whose dates were suggested) and 审核技能
/// (a skill an assistant wrote by itself). The one a notification was about is outlined
/// (Landing.swift).
struct ConfirmView: View {
    @Environment(AppStore.self) private var store
    /// The approval or question a notification opened, until you leave the page.
    @State private var selected: String?
    @State private var scrolls = 0

    var body: some View {
        let waiting = store.waiting
        Group {
            if waiting.count == 0 {
                ContentUnavailableView("都处理完了", systemImage: "checkmark.circle")
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            section("授权操作", count: waiting.grants.count + waiting.grantCards.count) {
                                asks(waiting.grants)
                                cards(waiting.grantCards)
                            }
                            section("回答问题", count: waiting.questions.count + waiting.questionCards.count) {
                                asks(waiting.questions)
                                cards(waiting.questionCards)
                            }
                            section("确认时间", count: waiting.todos.count) {
                                Box {
                                    VStack(spacing: 0) {
                                        ForEach(waiting.todos) { todo in
                                            TodoRow(todo: todo, showDay: true)
                                            if todo.id != waiting.todos.last?.id {
                                                Divider()
                                            }
                                        }
                                    }
                                }
                            }
                            section("审核技能", count: waiting.skills.count) {
                                ForEach(waiting.skills) { review in
                                    SkillReviewCard(review: review)
                                }
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
        .navigationSubtitle(waiting.count == 0 ? "" : "\(waiting.count) 件")
    }

    /// A heading and what is under it; nothing at all when there is nothing under it.
    @ViewBuilder
    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(title).font(.t13.weight(.semibold))
                    Text("\(count)").font(.t12).monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("waiting-\(title)")
                content()
            }
        }
    }

    private func asks(_ asks: [Ask]) -> some View {
        ForEach(asks) { ask in
            if ask.kind == .secret {
                // a password's or a key's card is one element already, named for its request
                // (SecretCard.swift): marked selected as it is, since a container around it
                // would take its name
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
    }

    private func cards(_ cards: [BoardAsk]) -> some View {
        ForEach(cards) { card in
            CardAskView(ask: card)
        }
    }
}
