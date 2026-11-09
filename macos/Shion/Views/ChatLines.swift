import Foundation

/// A line of the transcript: an item, or a finished run of tool calls folded into one line.
enum ChatLine: Identifiable {
    case item(ChatItem)
    /// Two or more tool calls in a row, identified by the last of them: older pages arrive above,
    /// so a run cut by a page boundary keeps its id when its first calls come in.
    case tools(id: String, [ChatItem])

    var id: String {
        switch self {
        case .item(let item): item.id
        case .tools(let id, _): id
        }
    }

    /// The items this line stands for.
    var items: [ChatItem] {
        switch self {
        case .item(let item): [item]
        case .tools(_, let tools): tools
        }
    }

    /// The transcript's lines. Tool calls in a row show one by one while their turn runs, and fold
    /// once anything but the reply still arriving comes after them, or once the turn is over
    /// (`replying` false). A single call is a line already. Cards and notes are not tool calls, so
    /// they stay in view and split the runs around them.
    static func lines(_ items: [ChatItem], replying: Bool) -> [ChatLine] {
        // the last item that settles the calls before it: not the reply still streaming
        let lastSettling = items.lastIndex { !($0.role == .assistant && $0.streaming) }
        var lines: [ChatLine] = []
        var index = items.startIndex
        while index < items.endIndex {
            guard items[index].role == .tool else {
                lines.append(.item(items[index]))
                index += 1
                continue
            }
            var end = index
            while end + 1 < items.endIndex, items[end + 1].role == .tool {
                end += 1
            }
            let run = Array(items[index...end])
            let settled = !replying || (lastSettling ?? -1) > end
            if settled, run.count > 1, let last = run.last {
                lines.append(.tools(id: "tools-\(last.id)", run))
            } else {
                lines.append(contentsOf: run.map { ChatLine.item($0) })
            }
            index = end + 1
        }
        return lines
    }
}

/// Keeps the transcript where it is while a run of tool calls opens or closes. The transcript keeps
/// its bottom as its content grows or shrinks (that is how it follows new messages), so a run
/// opening anywhere would push what is above it up, the run's own line too. `top` is how far the
/// content is scrolled; a hold keeps it as it is, and when it moves, a mark laid there is scrolled
/// to the top. How far from the mark a scroll to it leaves the top (the insets, as the scroll view
/// counts them) shows after the first one, and is allowed for from then on.
final class TopKeeper {
    /// How far the content is scrolled, as it last moved to; nil until it has moved.
    private(set) var top: CGFloat?
    private var kept: CGFloat?
    private var until = Date.distantPast
    private var tries = 0
    /// Where the mark was asked for last, and whether the scroll to it is yet to show.
    private var mark: CGFloat = 0
    private var scrolled = false
    /// Where a scroll to the mark leaves the top, from the mark.
    private var landing: CGFloat = 0

    /// A run is about to open or close: the top stays as it is now, for a while. Where to lay the
    /// mark; nil while the top is not known, which the first move then tells.
    func hold(for seconds: TimeInterval = 1, now: Date = Date()) -> CGFloat? {
        until = now.addingTimeInterval(seconds)
        tries = 0
        scrolled = false
        kept = top
        guard let top else { return nil }
        mark = top - landing
        return mark
    }

    /// The content was scrolled from `oldTop` to `newTop`. While held and away from the kept top:
    /// where to lay the mark, which is then scrolled to the top.
    func moved(from oldTop: CGFloat, to newTop: CGFloat, now: Date = Date()) -> CGFloat? {
        top = newTop
        guard now < until, tries < 5 else {
            kept = nil
            until = .distantPast
            return nil
        }
        let held = kept ?? oldTop
        kept = held
        if scrolled {
            landing = newTop - mark
            scrolled = false
        }
        guard abs(newTop - held) > 0.5 else { return nil }
        tries += 1
        mark = held - landing
        scrolled = true
        return mark
    }

    /// Held, and the top still away from the kept one: a scroll to the mark did not take.
    func away(now: Date = Date()) -> Bool {
        guard now < until, let kept, let top else { return false }
        return abs(top - kept) > 0.5
    }
}

extension ChatItem {
    /// A tool call's tool: its line reads "name · context" (AppStore.toolLine).
    var toolName: String {
        guard let separator = text.range(of: " · ") else { return text }
        return String(text[..<separator.lowerBound])
    }
}

extension [ChatItem] {
    /// One line for a run of tool calls: how many, then which tools, each named once.
    var toolSummary: String {
        var names: [String] = []
        for name in map(\.toolName) where !names.contains(name) {
            names.append(name)
        }
        return "用了 \(count) 个工具 · \(names.joined(separator: "、"))"
    }
}
