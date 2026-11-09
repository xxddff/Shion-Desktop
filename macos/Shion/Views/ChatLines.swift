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
