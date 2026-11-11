import SwiftUI

/// The deadline in words, with how loudly to show it.
struct DueLabel {
    let text: String
    let color: Color

    init(date: Date, now: Date) {
        let sameDay = Fmt.dayDiff(date, now) == 0
        if date < now {
            text = sameDay ? "\(Fmt.hm(date)) 已截止" : "\(Fmt.dayLabel(date, now: now))截止"
            color = Palette.alert
        } else {
            text = sameDay ? "\(Fmt.hm(date)) 截止" : "\(Fmt.dayLabel(date, now: now))截止"
            color = date.timeIntervalSince(now) < 24 * 3600 ? Palette.warm : Color.secondary
        }
    }
}

struct TodoRow: View {
    @Environment(AppStore.self) private var store
    let todo: Todo
    var showDay = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                store.toggle(todo.id)
            } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(todo.done ? Palette.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(store.readOnly)
            .accessibilityLabel(todo.done ? "标为未完成" : "标为完成")
            .accessibilityIdentifier("todo-toggle-\(todo.id)")

            VStack(alignment: .leading, spacing: 3) {
                Text(todo.title)
                    .font(.t13)
                    .strikethrough(todo.done)
                    .foregroundStyle(todo.done ? Color.secondary : Color.primary)
                HStack(spacing: 4) {
                    AreaDot(area: todo.area)
                    Text(todo.source)
                    if todo.nudges > 0 && !todo.done {
                        Text("· 催过 \(todo.nudges) 次").foregroundStyle(Palette.warm)
                    }
                    if todo.proposed {
                        Text("· 时间是建议的").foregroundStyle(Palette.warm)
                    }
                }
                .font(.t12)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                if let day = todo.doDay, let date = Fmt.day(day) {
                    Text(Fmt.dayLabel(date, now: store.now)).font(.t12).foregroundStyle(.secondary)
                } else if let doAt = todo.doAt {
                    Text(showDay ? Fmt.when(doAt, now: store.now) : Fmt.hm(doAt))
                        .font(.t12)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if todo.dueDay != nil, !todo.done {
                    Text(todo.deadlineLabel(now: store.now)).font(.t12)
                        .foregroundStyle(todo.overdue(at: store.now) ? Palette.alert : Color.secondary)
                } else if let dueAt = todo.dueAt, !todo.done {
                    let due = DueLabel(date: dueAt, now: store.now)
                    Text(due.text)
                        .font(.t12.weight(.semibold))
                        .foregroundStyle(due.color)
                }
            }

            if todo.proposed {
                Button("确认") { store.confirm(todo.id) }
                    .controlSize(.small)
                    .disabled(store.readOnly)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// An ask in the 「需要你」 tray: one line, at most two answers.
struct AskRow: View {
    @Environment(AppStore.self) private var store
    let ask: Ask

    var body: some View {
        // a password or a key is typed on its card, not here (SecretCard.swift)
        if ask.kind == .secret {
            SecretAskRow(ask: ask)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Avatar(bot: store.bot(ask.botId), size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(ask.title).font(.t13.weight(.medium)).lineLimit(1)
                Text("\(store.bot(ask.botId)?.name ?? "") · \(Fmt.hm(ask.at))")
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ForEach(Array(ask.options.prefix(2))) { option in
                if option.primary {
                    Button(option.label) { store.answer(ask, with: option) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button(option.label) { store.answer(ask, with: option) }
                        .controlSize(.small)
                }
            }
        }
        .disabled(store.readOnly)
        .padding(.vertical, 8)
    }
}

/// An ask on the 「等你确认」 page, with what would be sent.
struct AskCard: View {
    @Environment(AppStore.self) private var store
    let ask: Ask

    var body: some View {
        // a password or a key: its own card, with the field (SecretCard.swift)
        if ask.kind == .secret {
            SecretCard(requestId: ask.id)
        } else {
            card
        }
    }

    private var card: some View {
        Box {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Avatar(bot: store.bot(ask.botId), size: 22)
                    Text(store.bot(ask.botId)?.name ?? "").font(.t12.weight(.medium))
                    Spacer()
                    Text(Fmt.hm(ask.at)).font(.t12).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(ask.title).font(.t15)
                if let detail = ask.detail {
                    Text(detail).font(.t13).foregroundStyle(.secondary)
                }
                if let preview = ask.preview {
                    Text(preview)
                        .font(.t13)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                HStack(spacing: 8) {
                    ForEach(ask.options) { option in
                        if option.primary {
                            Button(option.label) { store.answer(ask, with: option) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(option.label) { store.answer(ask, with: option) }
                        }
                    }
                }
                .padding(.top, 2)
                .disabled(store.readOnly)
            }
            .padding(.vertical, 8)
        }
    }
}

struct CardStateTag: View {
    let status: CardStatus

    var body: some View {
        switch status {
        case .running:
            HStack(spacing: 4) {
                BusyDots()
                Text("在做")
            }
            .font(.t12)
            .foregroundStyle(Palette.accent)
        case .waiting:
            Text("等你").font(.t12.weight(.medium)).foregroundStyle(Palette.warm)
        case .done:
            Label("完成", systemImage: "checkmark").font(.t12).foregroundStyle(.secondary)
        case .queued:
            Text("排队").font(.t12).foregroundStyle(.secondary)
        }
    }
}

struct CardRow: View {
    @Environment(AppStore.self) private var store
    let card: Card

    var body: some View {
        HStack(spacing: 10) {
            Avatar(bot: store.bot(card.assignee), size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.t13).lineLimit(1)
                Text(card.line)
                    .font(.t12)
                    .foregroundStyle(card.status == .waiting ? Palette.warm : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            CardStateTag(status: card.status)
        }
        .padding(.vertical, 7)
    }
}

/// A kanban card inside a conversation: what was handed to whom, and how it is going (left out
/// while the board does not know the card yet).
struct CardChip: View {
    @Environment(AppStore.self) private var store
    let card: Card
    var showsStatus = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.t13).lineLimit(1)
                Text(handedTo).font(.t12).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if showsStatus {
                CardStateTag(status: card.status)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-card-\(card.id)")
    }

    private var handedTo: String {
        guard !card.assignee.isEmpty else { return "还没交给助手" }
        return "交给「\(store.bot(card.assignee)?.name ?? card.assignee)」"
    }
}
