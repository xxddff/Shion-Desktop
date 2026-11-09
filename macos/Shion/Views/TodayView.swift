import SwiftUI

struct TodayView: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                hero
                if !store.asks.isEmpty {
                    needsYou
                }
                agenda
                todoSection
                working
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("今天")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(Fmt.monthDay(store.now)) \(Fmt.weekday(store.now))")
                .font(.t30)
            // 詩音's own paragraph when the plugin has one for today, else the line made from the data
            Text(store.todaySummary ?? brief)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Mark(size: 22)
                TextField("跟詩音说：「把实验报告挪到明天」", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit {
                        store.send(draft, to: store.chiefId)
                        draft = ""
                        store.route = .chat(store.chiefId)
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Palette.fill, in: Capsule())
            .padding(.top, 4)
        }
    }

    /// 詩音's line for the moment: what is next and what is due first.
    private var brief: String {
        let now = store.now
        let today = store.events(on: now)
        let nextLesson = today.first { $0.kind == .lesson && $0.start > now }
        let nextEvent = today.first { $0.kind == .event && $0.start > now }
        let open = store.todayTodos
        let due = open.filter { ($0.dueAt ?? .distantPast) > now }.min { ($0.dueAt ?? now) < ($1.dueAt ?? now) }
        let classOver = today.contains(where: { $0.kind == .lesson && $0.end < now })
        var parts: [String] = [classOver ? "上午的课结束了。" : "早上好。"]
        var later: [String] = []
        if let nextLesson {
            later.append("\(nextLesson.title.replacing(#/ 第\d+回/#, with: ""))（\(Fmt.hm(nextLesson.start))）")
        }
        if let nextEvent {
            later.append("\(nextEvent.title)（\(Fmt.hm(nextEvent.start))）")
        }
        if !later.isEmpty {
            parts.append("接下来是\(later.joined(separator: "和"))。")
        }
        if let due, let dueAt = due.dueAt {
            parts.append("还有 \(open.count) 件待办，最先要交的是「\(due.title)」，\(Fmt.hm(dueAt)) 截止。")
        } else {
            parts.append("还有 \(open.count) 件待办。")
        }
        return parts.joined()
    }

    private var needsYou: some View {
        let asks = Array(store.asks.prefix(3))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "需要你", count: store.asks.count)
                Spacer()
                Button("全部") { store.route = .confirm }
                    .buttonStyle(.link)
            }
            Box {
                VStack(spacing: 0) {
                    ForEach(asks) { ask in
                        AskRow(ask: ask)
                        if ask.id != asks.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var agenda: some View {
        let now = store.now
        let events = store.events(on: now)
        let nowIndex = events.firstIndex { $0.start > now } ?? events.count
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "日程")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    if index == nowIndex {
                        NowLine(now: now)
                    }
                    AgendaRow(event: event, past: event.end < now)
                }
                if nowIndex == events.count {
                    NowLine(now: now)
                }
            }
        }
    }

    private var todoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "待办", count: store.todayTodos.count)
                Spacer()
                Button("全部") { store.route = .todos }
                    .buttonStyle(.link)
            }
            VStack(spacing: 0) {
                ForEach(store.todayTodos) { todo in
                    TodoRow(todo: todo)
                }
            }
        }
    }

    private var working: some View {
        let cards = store.workingCards
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "助手在做", count: cards.count)
                Spacer()
                Button("看板") { store.route = .board }
                    .buttonStyle(.link)
            }
            VStack(spacing: 0) {
                ForEach(cards) { card in
                    CardRow(card: card)
                }
            }
        }
    }
}

/// The red "now" line through the agenda.
struct NowLine: View {
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(Fmt.hm(now))
                .font(.t11.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.alert)
                .frame(width: 44, alignment: .leading)
            Rectangle().fill(Palette.alert).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

struct AgendaRow: View {
    let event: CalEvent
    let past: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Fmt.hm(event.start))
                .font(.t12)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(event.area.color)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.t13)
                Text(subtitle).font(.t12).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .opacity(past ? 0.5 : 1)
    }

    private var subtitle: String {
        ["\(Fmt.hm(event.start))–\(Fmt.hm(event.end))", event.place].compactMap { $0 }.joined(separator: " · ")
    }
}
