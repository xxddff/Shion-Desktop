import Foundation

/// What Hermes gives an assistant as a turn in your name without your having written it, read
/// for what it is, so a chat can show a card for it instead of a message of yours:
/// - the board's word on cards the chat made ("✔ [study] @study Kanban t_ab12 done — …":
///   tui_gateway/session_notifications.py, the wording Telegram gets);
/// - another assistant's message ("Message from 🤖 Name (@handle): …": tools/bot_mode_dm.py);
/// - the end of something that ran in the background (a row of kind `process_complete`,
///   `async_delegation_complete` or `internal_notification`: gateway/response_filters.py).
/// Foundation only, so it can be checked away from a Mac.
nonisolated enum Notices {
    /// One notice read from a turn's text.
    struct Notice: Equatable {
        var event: ChatEvent
        var text: String
        /// The board card it is about.
        var cardId: String?
        var assignee: String?
    }

    /// The row kinds Hermes gives turns it started itself.
    static let machineKinds: Set<String> = ["internal_notification", "process_complete", "async_delegation_complete"]

    /// The notices in a turn's text, in order; empty when it is a message someone typed.
    /// `display` is the short form Hermes's own clients show for a background result
    /// (`display_metadata.display_text`), used in place of the text written for the model.
    static func read(_ text: String, kind: String?, display: String?) -> [Notice] {
        let body = withoutProvenance(text)
        let cards = kanban(body)
        if !cards.isEmpty {
            return cards.map { Notice(event: .board, text: $0.line, cardId: $0.taskId, assignee: $0.assignee) }
        }
        if let message = peerMessage(body) {
            return [Notice(event: .received(from: message.from), text: message.words)]
        }
        if let kind, machineKinds.contains(kind) {
            let shown = (display ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return [Notice(event: .background, text: shown.isEmpty ? body : shown)]
        }
        return []
    }

    // MARK: the board

    /// The board's notices in a text, one per line; a line after a notice that is not one (the
    /// first line of what was handed in, a give-up's error) belongs to it. Empty when the text
    /// does not start with a notice.
    static func kanban(_ text: String) -> [(line: String, taskId: String, assignee: String?)] {
        var notices: [(line: String, taskId: String, assignee: String?)] = []
        for line in text.split(separator: "\n").map(String.init) {
            guard let notice = kanbanLine(line) else {
                if notices.isEmpty { return [] }
                notices[notices.count - 1].line += "\n" + line
                continue
            }
            notices.append((line, notice.taskId, notice.assignee))
        }
        return notices
    }

    /// One notice line: a mark, the board in brackets, @ the assignee, "Kanban" and the card's id.
    private static func kanbanLine(_ line: String) -> (taskId: String, assignee: String?)? {
        var words = line.split(separator: " ", omittingEmptySubsequences: false)[...]
        // the mark is a sign (✔ ⏸ ✖ ⏱ 🔄), never a word
        guard let mark = words.first, (1...2).contains(mark.count), !mark.contains(where: { $0.isLetter || $0.isNumber })
        else { return nil }
        words = words.dropFirst()
        if let board = words.first, board.hasPrefix("["), board.hasSuffix("]") {
            words = words.dropFirst()
        }
        var assignee: String?
        if let who = words.first, who.hasPrefix("@"), who.count > 1 {
            assignee = String(who.dropFirst())
            words = words.dropFirst()
        }
        guard words.first == "Kanban", let id = words.dropFirst().first, !id.isEmpty else { return nil }
        return (String(id), assignee)
    }

    /// What a notice line says happened, in Chinese, and whether the card stopped for it.
    /// Hermes's wording after "Kanban <id>": " done — title", " blocked: reason", " gave up after
    /// repeated spawn failures", " worker crashed (pid gone); dispatcher will retry", " timed out
    /// (max_runtime=…s); will retry", " → status".
    static func kanbanOutcome(_ line: String) -> (words: String, detail: String?, stopped: Bool) {
        let lines = line.split(separator: "\n", maxSplits: 1).map(String.init)
        let extra = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        guard let range = lines.first?.range(of: " Kanban "), let head = lines.first else { return (line, nil, false) }
        // after the card's id
        let rest = head[range.upperBound...].drop { $0 != " " }.dropFirst()
        if rest.hasPrefix("done") {
            return ("做完了", extra, false)
        }
        if rest.hasPrefix("blocked") {
            let reason = rest.dropFirst("blocked".count).drop { $0 == ":" || $0 == " " }
            return ("停下了", reason.isEmpty ? extra : String(reason), true)
        }
        if rest.hasPrefix("gave up") {
            return ("试了几次都没能开始，放弃了", extra, true)
        }
        if rest.hasPrefix("worker crashed") {
            return ("中途出错，会再试一次", extra, false)
        }
        if rest.hasPrefix("timed out") {
            return ("超时了，会再试一次", extra, false)
        }
        if rest.hasPrefix("→") {
            return ("状态变了：\(rest.dropFirst().trimmingCharacters(in: .whitespaces))", extra, false)
        }
        return (String(rest), extra, false)
    }

    // MARK: another assistant

    private static let peerOpening = "Message from 🤖 "

    /// Another assistant's message: who signed it, and its words.
    static func peerMessage(_ text: String) -> (from: String, words: String)? {
        guard text.hasPrefix(peerOpening) else { return nil }
        let rest = text.dropFirst(peerOpening.count)
        // "Name (@handle): words"; the name may itself hold brackets
        guard let match = rest.firstMatch(of: #/^(.+?) \(@[A-Za-z0-9_-]+\): /#) else { return nil }
        return (String(match.1), String(rest[match.range.upperBound...]))
    }

    // MARK: what Hermes adds for the model

    private static let footerOpening = "[INTERNAL NOTIFICATION — "

    /// A notice without what Hermes wraps it in for the model: the footer saying no person wrote
    /// it (gateway/run_notifications.py), and the header of a batch that arrived while the
    /// session was busy (gateway/session_automation.py).
    static func withoutProvenance(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let footer = body.range(of: footerOpening, options: .backwards), body.hasSuffix("]"),
           !body[footer.upperBound...].dropLast().contains("]") {
            body = body[..<footer.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let header = body.prefixMatch(of: #/\[IMPORTANT: \d+ background process results arrived while this session was busy\.[^\]]*\]\s*/#) {
            body = String(body[header.range.upperBound...])
        }
        return body
    }
}
