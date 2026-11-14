import Foundation

/// What Hermes gives an assistant as a turn in your name without your having written it, read
/// for what it is, so a chat can show a card for it instead of a message of yours:
/// - the board's word on cards the chat made, in the two wordings Hermes has for it: what the
///   gateway wakes a session with ("[kanban] Task t_ab12 completed. …", `kanbanWake`: what a Bot
///   Chat on `hermes gateway` gets, as tried against Hermes itself), and the line its own
///   terminal client and the messaging platforms get ("✔ [study] @study Kanban t_ab12 done — …":
///   tui_gateway/session_notifications.py);
/// - another assistant's message ("Message from 🤖 Name (@handle): …": tools/bot_mode_dm.py), and
///   its answer to a message this assistant sent it, which Hermes hands back as the end of a
///   background process (`peerAnswers`);
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
        /// That card's title, when the notice says it (only a card done does): what is left to
        /// tell which card it was once the board no longer lists it.
        var cardTitle: String?
    }

    /// The row kinds Hermes gives turns it started itself.
    static let machineKinds: Set<String> = ["internal_notification", "process_complete", "async_delegation_complete"]

    /// The notices in a turn's text, in order; empty when it is a message someone typed.
    /// `display` is the short form Hermes's own clients show for a background result
    /// (`display_metadata.display_text`), used in place of the text written for the model.
    static func read(_ text: String, kind: String?, display: String?) -> [Notice] {
        let body = withoutProvenance(text)
        // only a row Hermes marks as its own notification: a message you typed that starts the
        // same way is yours
        if kind == "internal_notification", let wake = kanbanWake(body) {
            return [Notice(event: .board, text: wake.text, cardId: wake.taskId, assignee: wake.assignee,
                           cardTitle: wake.title)]
        }
        let cards = kanban(body)
        if !cards.isEmpty {
            return cards.map {
                Notice(event: .board, text: $0.line, cardId: $0.taskId, assignee: $0.assignee,
                       cardTitle: kanbanTitle($0.line, taskId: $0.taskId))
            }
        }
        if let message = peerMessage(body) {
            return [Notice(event: .received(from: message.from), text: peerWords(message.words))]
        }
        if let kind, machineKinds.contains(kind) {
            // a teammate's answer, not the command line of the process that waited for it. Several
            // results can come as one turn (`results`): each is read for what it is, so an answer
            // among them hides neither another answer nor a command that failed, and several
            // commands are not just a count (Hermes's short form for them is "2 Background
            // Processes Finished")
            let all = results(body)
            if all.count > 1 || all.contains(where: { peerAnswers($0) != nil }) {
                return all.flatMap { peerAnswers($0) ?? [Notice(event: .background, text: unwrapped($0))] }
            }
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

    /// The card's title, as a notice that it is done says it: "… Kanban <id> done — title", the
    /// title cut at 120 characters. Hermes puts the card's id there when the card has no title,
    /// which names nothing; no other notice says the title (tui_gateway/session_notifications.py,
    /// `_format_kanban_event_text`).
    static func kanbanTitle(_ line: String, taskId: String) -> String? {
        let head = line.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? line
        guard let said = head.range(of: " Kanban \(taskId) done — ") else { return nil }
        let title = head[said.upperBound...].trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title == taskId ? nil : title
    }

    /// What a notice line says happened, in Chinese, and whether the card stopped for it.
    /// Hermes's wording after "Kanban <id>": " done — title", " blocked: reason", " gave up after
    /// repeated spawn failures", " worker crashed (pid gone); dispatcher will retry", " timed out
    /// (max_runtime=…s); will retry", " → status".
    static func kanbanOutcome(_ line: String) -> (words: String, detail: String?, stopped: Bool) {
        if let wake = kanbanWake(line) {
            return wake.outcome
        }
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

    // MARK: the board, as the gateway wakes a session with it

    /// What `hermes gateway` gives the session that subscribed to a card when the card is done,
    /// stops or is handed over (gateway/kanban_watchers_notifier.py, `build_wake_text`), stored as
    /// a row of kind `internal_notification`; the turn's start frame says nothing of it. Captured
    /// from Hermes 611bf53:
    ///
    ///     [kanban] Task t_3beef09c completed.
    ///     Title: 归档旧发票
    ///     Assignee: @study
    ///     Board: default
    ///
    ///     Check the result or decide the next step.
    ///     Result: 发票都归好了。
    ///
    ///     This is an automatic task-status notification, not a request to …
    ///
    /// The last paragraph is for the model. The wording is Hermes's `gateway.kanban.wake.*`:
    /// English in nearly every language it has, Chinese in `zh` (任务 … 已完成。标题: … 结果：…).
    struct Wake: Equatable {
        var taskId: String
        var title: String?
        var assignee: String?
        var board: String?
        /// What happened, in Hermes's words ("completed", "blocked; needs attention", 已完成).
        var status: String
        /// The first line of what was handed in, or of the review's reason.
        var summary: String?
        /// The notice without the paragraph for the model: what a card keeps of it.
        var text: String

        /// In Chinese, and whether the card stopped for it. Hermes's words stand where they are
        /// not among the ones known (a language that has its own, a status added since).
        var outcome: (words: String, detail: String?, stopped: Bool) {
            for (signs, words, stopped) in Notices.wakeOutcomes where signs.contains(where: { status.contains($0) }) {
                return (words, summary, stopped)
            }
            return (status, summary, false)
        }
    }

    /// Hermes's statuses by what marks them, the more particular first (a review's own words say
    /// "done" and "BLOCK" too), and what a card says for each.
    private static let wakeOutcomes: [(signs: [String], words: String, stopped: Bool)] = [
        (["review requested changes", "评审要求修改"], "检查没通过，要改", false),
        (["handed off for review", "已交付评审"], "做完了，交来检查", false),
        (["routed to triage", "转入待分诊"], "反复卡住，等人来处理", true),
        (["gave up", "已放弃"], "试了几次都没能开始，放弃了", true),
        (["crashed", "崩溃"], "中途出错，会再试一次", false),
        (["timed out", "超时"], "超时了，会再试一次", false),
        (["blocked", "被阻塞"], "停下了", true),
        (["completed", "已完成"], "做完了", false),
    ]

    private static let wakeOpening = "[kanban] "

    /// A wake's notice read from a turn's text; nil for anything else. Read by its shape, which
    /// is the same in every language: the opening, the card's id on the first line, then the
    /// title, the assignee and the board a line each, and in the next paragraph a fixed sentence
    /// with what was handed in under it.
    static func kanbanWake(_ text: String) -> Wake? {
        guard text.hasPrefix(wakeOpening) else { return nil }
        let paragraphs = text.components(separatedBy: "\n\n")
        let head = paragraphs[0].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let first = head[0].dropFirst(wakeOpening.count)
        guard let id = first.firstMatch(of: #/\bt_[A-Za-z0-9_]+/#) else { return nil }
        let status = first[id.range.upperBound...].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
        let assignee = head.count > 2 ? head[2].split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init) : nil
        var summary: String?
        var kept = paragraphs[0]
        if paragraphs.count > 1 {
            kept += "\n\n" + paragraphs[1]
            // under the fixed sentence: "Result: …", or a review's "Review feedback: …"
            let under = paragraphs[1].split(separator: "\n").dropFirst().first.map(String.init)
            summary = under.flatMap { said($0) }
        }
        return Wake(taskId: String(id.output), title: head.count > 1 ? said(head[1]) : nil,
                    assignee: assignee.flatMap { ["", "None"].contains($0.trimmingCharacters(in: .whitespaces)) ? nil : $0 },
                    board: head.count > 3 ? said(head[3]) : nil,
                    status: status.isEmpty ? String(first) : status, summary: summary, text: kept)
    }

    /// What a line says after its label ("Title: …", 结果：…); nil when nothing does.
    private static func said(_ line: String) -> String? {
        guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
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

    private static let noReply = "[no reply needed] "
    private static let envelope = [("Constraints: ", "限制："), ("Reply needed: ", "要回：")]

    /// A message's words without Hermes's own marks on them (tools/bot_mode_dm.py): the marker of
    /// one that wants no answer, and the labelled lines under it for what the answer must keep to
    /// and what is wanted back (`_envelope`), said in the chat's words.
    static func peerWords(_ words: String) -> String {
        var body = words
        let wantsNone = body.hasPrefix(noReply)
        if wantsNone { body.removeFirst(noReply.count) }
        var parts = body.components(separatedBy: "\n\n")
        if parts.count > 1 {
            let lines = parts[parts.count - 1].split(separator: "\n").map(String.init)
            let said = lines.compactMap { line in
                envelope.first { line.hasPrefix($0.0) }.map { $0.1 + line.dropFirst($0.0.count) }
            }
            // only a paragraph that is nothing else: the sender's own words can start the same way
            if !said.isEmpty, said.count == lines.count { parts[parts.count - 1] = said.joined(separator: "\n") }
        }
        if wantsNone { parts.append("不用回复") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: results that came together

    private static let resultOpening = "[IMPORTANT: "

    /// The background results in one turn's text, each as Hermes wrote it. Results that arrive
    /// while the session is busy are folded into one turn (gateway/session_automation.py
    /// `_fold_completion`): under one header (`withoutProvenance` takes it off), each result's own
    /// block, opening with `[IMPORTANT: ` on a line of its own start. One result, or a text that
    /// is not such a block, is itself.
    static func results(_ body: String) -> [String] {
        guard body.hasPrefix(resultOpening) else { return [body] }
        var blocks: [[String]] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix(resultOpening) || blocks.isEmpty {
                blocks.append([line])
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks.map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// One result without the brackets Hermes puts around it for the model: what ended and how,
    /// its command and what it put out, in Hermes's words.
    static func unwrapped(_ result: String) -> String {
        var words = result
        if words.hasPrefix(resultOpening) { words.removeFirst(resultOpening.count) }
        if words.hasSuffix("]") { words.removeLast() }
        return words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: another assistant's answer

    /// What came of a message this assistant sent another (message_agent). Hermes waits for the
    /// answer in a background process (`tools/bot_mode_dm.py --run-delivery`) and gives the sender
    /// that process's end like any other, under a short form that is its command line. Its output
    /// is one JSON line: `outcome` says who answered or why not (tools/bot_mode_dm_outcome.py),
    /// `reply` is the answer; several asked at once come back together (`replies`, each with whom
    /// it was `to`). As captured from Hermes itself.
    ///
    /// An answer is a message from that teammate, `from` its handle (the card shows the
    /// assistant's name for it); no answer is said in Hermes's own sentence. Nil when the text is
    /// not the end of such a process. One result at a time (`results`).
    static func peerAnswers(_ text: String) -> [Notice]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let command = lines.firstIndex(where: { $0.hasPrefix("Command: ") && $0.contains("bot_mode_dm") }),
              let output = lines[command...].firstIndex(where: { $0.hasPrefix("Output") && $0.hasSuffix(":") }),
              let found = lines[(output + 1)...].lazy.compactMap({ outcome(in: $0) }).first,
              let sentence = found["outcome"] as? String
        else { return nil }
        if let several = found["replies"] as? [[String: Any]] {
            var notices = several.compactMap { entry -> Notice? in
                guard let reply = (entry["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !reply.isEmpty else { return nil }
                return Notice(event: .received(from: handle(entry["to"] as? String ?? "")), text: reply)
            }
            // someone did not answer: the sentence names each
            if notices.count < several.count { notices.append(Notice(event: .background, text: sentence)) }
            return notices
        }
        // "@study answered.", or "Your teammate answered." of Hermes's default profile: then the
        // command names it, last ("… hermes -p default")
        let who = sentence.firstMatch(of: #/^@([A-Za-z0-9_-]+) /#).map { String($0.1) }
            ?? lines[command].firstMatch(of: #/ -p ([A-Za-z0-9_-]+)\s*$/#).map { String($0.1) }
        if let reply = (found["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
            return [Notice(event: .received(from: who ?? "另一位助手"), text: reply)]
        }
        // its turn over and nothing said back (it may have had nothing to say); any other end
        // (never answered, and why) in Hermes's own sentence
        if sentence.hasSuffix(" finished its turn without replying.") {
            return [Notice(event: .background, text: "\(who.map { "@" + $0 } ?? "对方") 这一轮没有回话")]
        }
        return [Notice(event: .background, text: sentence)]
    }

    private static func handle(_ label: String) -> String {
        label.hasPrefix("@") ? String(label.dropFirst()) : label
    }

    /// The runner's JSON line, which Hermes closes its own bracket after.
    private static func outcome(in line: String) -> [String: Any]? {
        guard line.hasPrefix("{") else { return nil }
        for candidate in [line, String(line.dropLast())] where candidate.hasSuffix("}") {
            if let object = (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) as? [String: Any] {
                return object
            }
        }
        return nil
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
