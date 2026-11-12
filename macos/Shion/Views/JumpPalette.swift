import SwiftUI

/// What the main window shows over itself for ⌘K, and the todo it is opening.
@Observable
final class JumpState {
    var shown = false
    /// A todo picked in the palette: 待办 opens it in the inspector, then clears this.
    var todo: String?
}

/// ⌘K over the main window; a click outside it or Esc puts it away.
struct JumpOverlay: View {
    @Environment(JumpState.self) private var jump: JumpState?

    var body: some View {
        if let jump, jump.shown {
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        jump.shown = false
                    }
                JumpPalette()
                    .padding(.top, 64)
            }
        }
    }
}

/// Somewhere ⌘K can go, as the palette lists it.
struct JumpHit: Identifiable {
    enum Icon {
        case symbol(String)
        case bot(Bot)
        case area(Area)
        case mark
    }

    enum Target {
        case route(Route)
        case todo(String)
        /// The words, as a sentence for 詩音.
        case ask(String)
    }

    let id: String
    let group: JumpCandidate.Group
    let title: String
    var subtitle = ""
    /// The page's ⌘ number, a todo's day.
    var trailing = ""
    let icon: Icon
    let target: Target
}

/// Pages, assistants and open todos, found by what you type; ↑↓ choose, Return goes. Words that
/// match nothing can go to 詩音 instead, as the last line.
struct JumpPalette: View {
    @Environment(AppStore.self) private var store
    @Environment(JumpState.self) private var jump
    @State private var query = ""
    @State private var selected = 0
    @State private var listHeight: CGFloat = 0

    private static let width: CGFloat = 560
    /// Tall enough for the seven pages and six assistants without scrolling.
    private static let listMax: CGFloat = 480

    var body: some View {
        let hits = self.hits
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                KeyField(
                    text: $query,
                    placeholder: "跳转到页面、助手或待办",
                    size: 15,
                    identifier: "jump-field",
                    onSubmit: { open(hits, at: selected) },
                    onCancel: { jump.shown = false },
                    onMove: { step in move(by: step, in: hits.count) }
                )
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            if !hits.isEmpty {
                Divider()
                list(hits)
            }
        }
        .frame(width: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onChange(of: query) {
            selected = 0
        }
        .onChange(of: store.route) {
            jump.shown = false
        }
        .onExitCommand {
            jump.shown = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("jump-palette")
    }

    private func list(_ hits: [JumpHit]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        if let header = header(for: hit.group), index == 0 || hits[index - 1].group != hit.group {
                            Text(header)
                                .font(.t11.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 4 : 10)
                                .padding(.bottom, 4)
                        }
                        JumpRow(hit: hit, selected: index == selected)
                            .id(hit.id)
                            .onTapGesture {
                                open(hits, at: index)
                            }
                            .onHover { inside in
                                if inside {
                                    selected = index
                                }
                            }
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    listHeight = height
                }
            }
            .frame(height: min(max(listHeight, 1), Self.listMax))
            .onChange(of: selected) { _, index in
                guard hits.indices.contains(index) else { return }
                proxy.scrollTo(hits[index].id)
            }
        }
    }

    private func header(for group: JumpCandidate.Group) -> String? {
        switch group {
        case .page: "页面"
        case .assistant: "助手"
        case .todo: "待办"
        case .ask: nil
        }
    }

    /// Everything the palette can go to, narrowed by the words (JumpSearch.swift).
    private var hits: [JumpHit] {
        var all: [String: JumpHit] = [:]
        var candidates: [JumpCandidate] = []
        func add(_ hit: JumpHit, keywords: [String]) {
            all[hit.id] = hit
            candidates.append(JumpCandidate(id: hit.id, group: hit.group, title: hit.title, keywords: keywords))
        }
        for (index, page) in SidebarPage.all.enumerated() {
            add(JumpHit(id: "jump-page-\(page.token)", group: .page, title: page.title, trailing: "⌘\(index + 1)",
                        icon: .symbol(page.symbol), target: .route(page.route)),
                keywords: [page.token])
        }
        for bot in store.bots {
            add(JumpHit(id: "jump-bot-\(bot.id)", group: .assistant, title: bot.name, subtitle: bot.title,
                        icon: .bot(bot), target: .route(.chat(bot.id))),
                keywords: [bot.id, bot.title])
        }
        for todo in store.todos where !todo.done {
            add(JumpHit(id: "jump-todo-\(todo.id)", group: .todo, title: todo.title,
                        trailing: todo.doLabel(now: store.now, showDay: true) ?? todo.dueWords(now: store.now) ?? "",
                        icon: .area(todo.area), target: .todo(todo.id)),
                keywords: [])
        }
        var found = JumpSearch.results(candidates, query: query).compactMap { all[$0.id] }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty {
            let chief = store.chiefName
            found.append(JumpHit(id: "jump-ask", group: .ask, title: "跟\(chief)说「\(words)」", icon: .mark, target: .ask(words)))
        }
        return found
    }

    private func move(by step: Int, in count: Int) {
        guard count > 0 else { return }
        selected = min(max(selected + step, 0), count - 1)
    }

    private func open(_ hits: [JumpHit], at index: Int) {
        guard hits.indices.contains(index) else { return }
        jump.shown = false
        switch hits[index].target {
        case .route(let route):
            store.route = route
        case .todo(let id):
            jump.todo = id
            store.route = .todos
        case .ask(let words):
            store.route = .chat(store.chiefId)
            store.tellChief(words)
        }
    }
}

/// One line of the palette; the chosen one is tinted.
struct JumpRow: View {
    let hit: JumpHit
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20, height: 20)
            Text(hit.title)
                .font(.t13)
                .lineLimit(1)
            if !hit.subtitle.isEmpty {
                Text(hit.subtitle)
                    .font(.t12)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !hit.trailing.isEmpty {
                Text(hit.trailing)
                    .font(.t12)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(selected ? Palette.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(hit.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        switch hit.icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case .bot(let bot):
            Avatar(bot: bot, size: 20)
        case .area(let area):
            AreaDot(area: area)
        case .mark:
            Mark(size: 20)
        }
    }
}
