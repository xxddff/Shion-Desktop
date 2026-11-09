import AppKit
import SwiftUI

// MARK: - stop and retry

/// While a turn runs, the composer's send button turns into this one (⌘.).
struct StopButton: View {
    let stopping: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .disabled(stopping)
        .keyboardShortcut(".", modifiers: .command)
        .help("停止")
        .accessibilityLabel("停止")
        .accessibilityIdentifier("stop")
    }
}

/// Under a reply: 已停止 when you stopped it, and 重试 under the chat's last reply. A turn whose
/// tools may run again asks first (AppStore.retryRisk).
struct ReplyFooter: View {
    @Environment(AppStore.self) private var store
    let item: ChatItem
    let botId: String
    @State private var risk: RetryRisk?

    var body: some View {
        let retry = !item.streaming && store.retryTarget(botId) == item.id
        // a line (a stop before any words) says 已停止 itself
        let marked = item.stopped && item.role == .assistant
        if marked || retry {
            HStack(spacing: 12) {
                if marked {
                    Text("已停止")
                        .accessibilityIdentifier("stopped")
                }
                if retry {
                    Button {
                        if let risk = store.retryRisk(botId), risk.asks {
                            self.risk = risk
                        } else {
                            store.retryReply(botId)
                        }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("retry")
                }
            }
            .font(.t12)
            .foregroundStyle(.secondary)
            .alert("重试这一轮？", isPresented: Binding { risk != nil } set: { if !$0 { risk = nil } }, presenting: risk) { _ in
                Button("重试") {
                    store.retryReply(botId)
                }
                .accessibilityIdentifier("retry-confirm")
                Button("取消", role: .cancel) {}
                    .accessibilityIdentifier("retry-cancel")
            } message: { risk in
                Text(risk.message)
            }
        }
    }
}

/// A line in a chat that is no one's message: Shion's note, a stop before any words, or why Hermes
/// ended a turn with an error, set apart: what went wrong, what to do, and Hermes's own words
/// under 详情. 重试 goes under the line that ends the last turn.
struct TurnNote: View {
    let item: ChatItem
    let botId: String
    @State private var details = false

    var body: some View {
        if let failure = item.failure {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    FoundText(item.text)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.alert)
                }
                .font(.t12)
                VStack(alignment: .leading, spacing: 4) {
                    if let advice = failure.advice {
                        Text(advice)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("failure-advice")
                    }
                    if let detail = failure.detail {
                        Button {
                            details.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: details ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .accessibilityHidden(true)
                                Text("详情")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("failure-details")
                        if details {
                            Text(detail)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .accessibilityIdentifier("failure-detail")
                        }
                    }
                    ReplyFooter(item: item, botId: botId)
                }
                .font(.t12)
                .padding(.leading, 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("turn-failed")
        } else {
            VStack(spacing: 4) {
                FoundText(item.text)
                    .font(.t12)
                    .foregroundStyle(.tertiary)
                ReplyFooter(item: item, botId: botId)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - finding in a chat

/// ⌘F in a chat: what is looked for, and which of the lines holding it is in view. The rows already
/// loaded are searched as you type; 上一个 past the oldest hit reads older pages, ten at most at a
/// time, until one turns up or the first message is reached.
@Observable
final class ChatFind {
    var shown = false
    var query = ""
    /// The hit in view, by line id; nil: the newest one.
    var current: String?
    /// Older pages are being read for a hit.
    private(set) var digging = false
    /// Bumped by ⌘F while the bar is up: the field takes the focus again.
    private(set) var asked = 0

    var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func open() {
        shown = true
        asked += 1
    }

    func close() {
        shown = false
        current = nil
    }

    /// The lines holding it, oldest first, and the one in view.
    func found(in lines: [ChatLine]) -> Found {
        let needle = needle
        guard shown, !needle.isEmpty else { return Found() }
        let hits = lines.filter { line in line.items.contains { Self.holds($0, needle) } }.map { $0.id }
        let focus = current.flatMap { hits.contains($0) ? $0 : nil } ?? hits.last
        return Found(needle: needle, hits: hits, focus: focus)
    }

    /// A row holds it in its words, or in the title of the card it stands for.
    static func holds(_ item: ChatItem, _ needle: String) -> Bool {
        item.text.range(of: needle, options: FindMarks.options) != nil
            || (item.cardTitle?.range(of: needle, options: FindMarks.options) != nil)
    }

    /// 下一个: the next newer hit.
    func newer(_ found: Found) {
        guard let focus = found.focus, let index = found.hits.firstIndex(of: focus), index + 1 < found.hits.count else { return }
        current = found.hits[index + 1]
    }

    /// 上一个: the next older hit; past the oldest one, older pages until one turns up.
    func older(_ found: Found, store: AppStore, botId: String) {
        if let focus = found.focus, let index = found.hits.firstIndex(of: focus), index > 0 {
            current = found.hits[index - 1]
            return
        }
        guard !digging, store.olderPages[botId] != nil else { return }
        digging = true
        let known = Set(found.hits)
        Task {
            defer { digging = false }
            var pages = 0
            while pages < 10, shown, store.olderPages[botId] != nil, store.olderErrors[botId] == nil {
                // a page the scrolling asked for is on its way: wait for it, then look
                if store.loadingOlder.contains(botId) {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                await store.loadOlder(botId)
                pages += 1
                let lines = ChatLine.lines(store.chats[botId] ?? [], replying: store.replying.contains(botId))
                let hits = self.found(in: lines).hits
                // the newest of those above the hits there were
                let above = known.isEmpty ? hits : Array(hits.prefix { !known.contains($0) })
                if let newest = above.last {
                    // after the page's own scroll, which keeps the rows that were at the top in place
                    try? await Task.sleep(for: .milliseconds(150))
                    current = newest
                    return
                }
            }
        }
    }
}

/// What the find bar found among the lines: those holding it, oldest first, and the one in view.
struct Found {
    var needle = ""
    var hits: [String] = []
    var focus: String?

    /// How a line marks it: all of its hits, strongly in the line in view; nil when it has none.
    func marks(_ line: ChatLine) -> FindMarks? {
        guard !needle.isEmpty, hits.contains(line.id) else { return nil }
        return FindMarks(needle: needle, strong: line.id == focus)
    }

    var position: Int? { focus.flatMap { hits.firstIndex(of: $0) } }
}

/// Where a text marks what the find bar looks for: the system's find highlight, full in the
/// line in view, faint elsewhere.
nonisolated struct FindMarks: Equatable, Sendable {
    let needle: String
    let strong: Bool

    /// Upper and lower case, accents, and full- and half-width forms all count as the same.
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    func apply(_ text: AttributedString) -> AttributedString {
        guard !needle.isEmpty else { return text }
        var marked = text
        var start = marked.startIndex
        while start < marked.endIndex, let range = marked[start...].range(of: needle, options: Self.options) {
            guard range.upperBound > start else { break }
            marked[range].backgroundColor = strong ? Self.color : Self.color.opacity(0.35)
            if strong {
                // the highlight is light in both appearances
                marked[range].foregroundColor = Color.black
            }
            start = range.upperBound
        }
        return marked
    }

    func apply(_ text: String) -> AttributedString {
        apply(AttributedString(text))
    }

    private static let color = Color(nsColor: .findHighlightColor)
}

extension Optional where Wrapped == FindMarks {
    /// The text with its hits marked, or as it is.
    func mark(_ text: AttributedString) -> AttributedString {
        self?.apply(text) ?? text
    }

    func mark(_ text: String) -> AttributedString {
        self?.apply(text) ?? AttributedString(text)
    }
}

nonisolated private struct FindMarksKey: EnvironmentKey {
    static let defaultValue: FindMarks? = nil
}

nonisolated extension EnvironmentValues {
    /// Set on a transcript line that holds what the find bar looks for (ChatView).
    var findMarks: FindMarks? {
        get { self[FindMarksKey.self] }
        set { self[FindMarksKey.self] = newValue }
    }
}

/// A transcript text, with what the find bar looks for marked.
struct FoundText: View {
    @Environment(\.findMarks) private var marks
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(marks.mark(text))
    }
}

/// The find bar over the top of a chat: the words, which hit of how many, older and newer.
/// Return or ⌘G goes back to the next older hit, ⇧⌘G forward; Esc closes it.
struct ChatFindBar: View {
    @Environment(AppStore.self) private var store
    @Bindable var find: ChatFind
    let found: Found
    let botId: String
    @FocusState private var focused: Bool

    var body: some View {
        if find.shown {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("在对话里查找", text: $find.query)
                    .textFieldStyle(.plain)
                    .font(.t13)
                    .frame(width: 180)
                    .focused($focused)
                    .onSubmit(older)
                    .accessibilityIdentifier("find-field")
                if find.digging {
                    ProgressView().controlSize(.small)
                }
                if !found.needle.isEmpty {
                    Text(count)
                        .font(.t12)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("find-count")
                }
                Button(action: older) {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canGoOlder)
                .keyboardShortcut("g", modifiers: .command)
                .accessibilityLabel("上一个")
                .accessibilityIdentifier("find-older")
                Button {
                    find.newer(found)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled((found.position ?? found.hits.count) + 1 >= found.hits.count)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .accessibilityLabel("下一个")
                .accessibilityIdentifier("find-newer")
                Button {
                    find.close()
                } label: {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭查找")
                .accessibilityIdentifier("find-close")
            }
            .buttonStyle(.borderless)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 10)
            .onAppear { focused = true }
            .onChange(of: find.asked) { focused = true }
            .onChange(of: find.query) { find.current = nil }
        }
    }

    private var count: String {
        guard let position = found.position else { return find.digging ? "" : "没找到" }
        return "\(position + 1)/\(found.hits.count)"
    }

    private var canGoOlder: Bool {
        guard !found.needle.isEmpty, !find.digging else { return false }
        return (found.position ?? 0) > 0 || store.olderPages[botId] != nil
    }

    private func older() {
        find.older(found, store: store, botId: botId)
    }
}

/// The chat toolbar's find button: ⌘F, again to put the focus back in the field.
struct FindButton: View {
    let find: ChatFind

    var body: some View {
        Button {
            find.open()
        } label: {
            Label("在对话里查找", systemImage: "magnifyingglass")
        }
        .keyboardShortcut("f", modifiers: .command)
        .help("在对话里查找")
        .accessibilityIdentifier("find")
    }
}
