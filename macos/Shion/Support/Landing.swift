import Foundation
import Observation
import SwiftUI

/// Where a click on a notification lands: its page, and on it the very thing it was about. Each
/// notification carries what finds that thing again in its userInfo (Notifications.swift):
/// - a reply: the assistant, and the row Hermes stored the reply as (`message.complete`'s
///   `persisted_turn.final_assistant_row_id`, which is the transcript's `row_id`), with the row it
///   streamed in as and its first words and time for when Hermes did not say;
/// - an approval or a question: its prompt id, selected in 等你确认;
/// - a card: its board and id, opened on the board page (AppStore.openCard);
/// - a daily report: its date and kind.
/// Every value is a string, as the test runs' notification log has them.
enum Landing: Equatable {
    case message(botId: String, row: Int?, item: String?, words: String?, at: Date?)
    case ask(botId: String, id: String)
    case card(id: String, board: String?)
    case report(id: String, date: String, kind: ReportKind)

    init?(info: [String: String]) {
        if let id = info["report"], let kind = ReportKind(rawValue: info["kind"] ?? "") {
            self = .report(id: id, date: info["date"] ?? String(id.prefix(10)), kind: kind)
        } else if let card = info["card"] {
            let board = info["board"] ?? ""
            self = .card(id: card, board: board.isEmpty ? nil : board)
        } else if let ask = info["ask"] {
            self = .ask(botId: info["bot"] ?? "", id: ask)
        } else if let bot = info["bot"], !bot.isEmpty {
            self = .message(botId: bot, row: info["row"].flatMap { Int($0) }, item: info["item"],
                            words: info["words"], at: info["at"].flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) })
        } else {
            return nil
        }
    }

    /// A reply's userInfo: what finds it in the chat again, even after the chat was read anew.
    static func replyInfo(botId: String, text: String, row: Int?, item: String?, at: Date) -> [String: String] {
        var info = ["bot": botId, "words": String(text.prefix(40)), "at": String(Int(at.timeIntervalSince1970))]
        info["row"] = row.map { String($0) }
        info["item"] = item
        return info
    }

    static func reportInfo(_ report: Report) -> [String: String] {
        ["report": report.id, "date": report.day, "kind": report.kind.rawValue]
    }

    /// The page it opens on.
    var route: Route {
        switch self {
        case .message(let botId, _, _, _, _): .chat(botId)
        case .ask: .confirm
        case .card: .board
        case .report: .reports
        }
    }
}

extension Report {
    /// The day it is about (`YYYY-MM-DD`, the plugin's `date`): its id begins with it.
    var day: String { String(id.prefix(10)) }
}

/// The landing waiting for its page to take it up: the chat still opening, 等你确认 not holding
/// the approval yet, the board not read yet, the plugin's reports not there yet. A click that
/// started Shion waits like this until it has connected. It goes once taken up, once its page
/// knows the thing is not there, or when you go to another page.
@Observable
final class Landings {
    static let shared = Landings()

    var pending: Landing?

    /// A click on a notification: its page now, the thing on it as soon as it is there.
    func open(_ landing: Landing, in store: AppStore) {
        pending = landing
        switch landing {
        case .card(let id, let board):
            store.openCard(id, board: board)
            // the board page reveals it from here; one not read yet is opened again once it is
            if store.board.loaded {
                pending = nil
            }
        default:
            store.route = landing.route
        }
    }

    /// The pending landing for this page, if any.
    func pending(on route: Route) -> Landing? {
        pending?.route == route ? pending : nil
    }
}

/// On the window's root: a card's landing once the board has been read (a click that started
/// Shion comes before that), and a landing nobody took up goes when you go to another page.
struct LandingRoot: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        let landings = Landings.shared
        content
            .onChange(of: store.board.loaded) { _, loaded in
                guard loaded, case .card(let id, let board)? = landings.pending else { return }
                landings.pending = nil
                store.openCard(id, board: board)
            }
            .onChange(of: store.route) { _, route in
                if let pending = landings.pending, pending.route != route {
                    landings.pending = nil
                }
            }
    }
}

/// A chat's part of a landing: once its rows are there, the message the notification was about
/// comes into view from its top, rather than the chat's newest line. `scroll` brings a line into
/// view (ChatView's ScrollViewReader).
struct LandingScroll: ViewModifier {
    @Environment(AppStore.self) private var store
    let botId: String
    let lines: [ChatLine]
    let scroll: (String) -> Void

    func body(content: Content) -> some View {
        let pending = Landings.shared.pending(on: .chat(botId))
        content.task(id: "\(String(describing: pending))|\(lines.count)|\(loaded)") {
            guard case .message(_, let row, let item, let words, let at)? = pending else { return }
            guard let line = Self.line(in: lines, row: row, item: item, words: words, at: at) else {
                // read and not there (an older page, or gone): the chat stays at its newest line
                if loaded {
                    Landings.shared.pending = nil
                }
                return
            }
            // after the transcript went to its newest line, and once more as the rows above take
            // their real heights
            for delay in [250, 350] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                scroll(line)
            }
            if Landings.shared.pending == pending {
                Landings.shared.pending = nil
            }
        }
    }

    /// The server's rows are in: connected, the chat opened and its newest page read.
    private var loaded: Bool {
        store.live && !store.openingChats.contains(botId) && !(store.chats[botId] ?? []).isEmpty
    }

    /// The line holding the message: by the row Hermes stored it as, by the row it streamed in
    /// as, then by its first words, written no more than ten minutes apart.
    static func line(in lines: [ChatLine], row: Int?, item: String?, words: String?, at: Date?) -> String? {
        let items = lines.flatMap(\.items)
        let found = row.flatMap { row in items.last { $0.id == "row-\(row)" } }
            ?? item.flatMap { item in items.last { $0.id == item } }
            ?? words.flatMap { words in
                items.last { candidate in
                    candidate.role == .assistant && !words.isEmpty && candidate.text.hasPrefix(words)
                        && at.map { abs(candidate.at.timeIntervalSince($0)) < 600 } ?? true
                }
            }
        guard let found else { return nil }
        return lines.first { line in line.items.contains { $0.id == found.id } }?.id
    }
}

extension View {
    /// ChatView: the message a notification was about, brought into view (LandingScroll).
    func landing(_ botId: String, lines: [ChatLine], scroll: @escaping (String) -> Void) -> some View {
        modifier(LandingScroll(botId: botId, lines: lines, scroll: scroll))
    }

    /// An item a notification opened: an outline in the accent colour (purple marks what is
    /// selected), on a `Box`'s corners.
    func landed(_ on: Bool, cornerRadius: CGFloat = 12) -> some View {
        overlay {
            if on {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 2)
            }
        }
    }
}
