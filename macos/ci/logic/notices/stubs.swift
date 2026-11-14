import Foundation

// Stand-ins for what the store's reading of a turn's notice leans on (AppStore.followNotices and
// what it calls in its file, cut out by extract.py), so it compiles and runs away from the app, on
// Linux or a Mac. Only what it touches; NoticeCards.swift, Notices.swift and JSONValue.swift are
// the app's own.

enum ChatRole { case user, assistant, system, card, tool }

/// Only whether a turn failed is looked at here.
struct TurnFailure: Hashable {}

struct ChatItem: Identifiable, Hashable {
    var id: String
    let role: ChatRole
    let at: Date
    var text = ""
    var event: ChatEvent?
    var streaming = false
    var stopped = false
    var failure: TurnFailure?
    var midTurn = false
}

final class ChatControl {
    var storedRows: [String: Int] = [:]
    var namedRows: [String: Set<Int>] = [:]
}

/// Records what every read asks for, and answers as the test scripts it.
final class Gateway {
    var asked: [JSONValue] = []
    var answer: (JSONValue) throws -> JSONValue = { _ in ["rows": [], "next_cursor": nil] }

    @discardableResult
    func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        asked.append(params)
        // the answer comes a moment after the call, as over a socket
        await Task.yield()
        return try answer(params)
    }
}

final class AppStore {
    var pagesTranscripts = true
    var loadedChats: Set<String> = []
    var sessions: [String: String] = [:]
    var chats: [String: [ChatItem]] = [:]
    let control = ChatControl()
    let gateway = Gateway()

    /// A page's rows as AppStore.transcriptItems and chatItems(from:) make them, as far as the rows
    /// read here go: each under its row's id, a tool's row (which has none) under its call's; a row
    /// Hermes gave the assistant in your name is a card for each notice it says, the first under
    /// the row's id; an assistant's row with no words shows nothing.
    func transcriptItems(_ page: JSONValue) -> [ChatItem] {
        (page["rows"]?.array ?? []).flatMap { row -> [ChatItem] in
            let at = row["timestamp"]?.number.map { Date(timeIntervalSince1970: $0) } ?? Date()
            let id = row["row_id"]?.int.map { "row-\($0)" } ?? row["tool_call_id"]?.string.map { "tool-\($0)" }
                ?? UUID().uuidString
            let text = row["text"]?.string ?? ""
            switch row["role"]?.string {
            case "user":
                let notices = Notices.read(text, kind: row["display_kind"]?.string,
                                           display: row["display_metadata"]?["display_text"]?.string)
                guard notices.isEmpty else {
                    return notices.enumerated().map { index, notice in
                        ChatItem(id: index == 0 ? id : "\(id)-card\(index + 1)", role: .card, at: at, text: notice.text,
                                 event: notice.event)
                    }
                }
                return [ChatItem(id: id, role: .user, at: at, text: text)]
            case "assistant":
                return text.isEmpty ? [] : [ChatItem(id: id, role: .assistant, at: at, text: text)]
            case "tool":
                return [ChatItem(id: id, role: .tool, at: at, text: row["name"]?.string ?? "tool")]
            default:
                return []
            }
        }
    }
}
