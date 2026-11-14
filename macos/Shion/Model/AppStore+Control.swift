import Foundation
import Observation

/// What stopping and retrying a turn need, and whether they are under way. Hermes fences both:
/// `session.interrupt` names the run it stops (`execution_generation`), and a rewind names the
/// session's revision and run it was decided on (`expected_revision`, `expected_generation`).
/// Shion keeps both per session, from each snapshot, from the stamp on every frame of a turn,
/// and from `session.info`, which ends every turn with them.
@Observable
final class ChatControl {
    /// bot ids whose stop is on its way, until Hermes ends the turn
    var stopping: Set<String> = []
    /// bot ids whose retry is on its way
    var retrying: Set<String> = []
    /// bot id → its latest stop, so an older stop's timer leaves a newer one be
    @ObservationIgnored var stops: [String: UUID] = [:]
    /// session id → the newest run and revision seen
    @ObservationIgnored var fences: [String: Fence] = [:]
    /// A prompt (its `submission_id`: one sent from here is named by its chat item's id) → the
    /// transcript row Hermes stored it as, as its turn's end says (`message.complete.persisted_turn`)
    /// or any page with that row on it, which names the submission (AppStore.transcriptPage).
    /// Also what came live in a turn Hermes started and is known to be a row since that turn's
    /// end: its reply's bubble, the cards its start made (AppStore.noteTurnRows).
    @ObservationIgnored var storedRows: [String: Int] = [:]
    /// session id → the transcript rows known to name a submission (DeliveryCheck.named): each is
    /// that prompt's, so none of them says a message in the same words got there. Numbers are
    /// enough here: Hermes never gives one twice, and a page names a compaction's copy of such a
    /// row under its new number.
    @ObservationIgnored var namedRows: [String: Set<Int>] = [:]
    /// Assistant id → the cards the turn under way began with (a frame said what started it),
    /// until its end names their row.
    @ObservationIgnored var turnCards: [String: [String]] = [:]
    /// session id → the transcript rows that have each confirmed a message put into a running
    /// turn as the connection went (AppStore.settleCorrections). Such a message has no receipt,
    /// so a row of yours in its words is all that says it got there, and a row says so of one
    /// message only: kept for as long as the session is the chat's, so a later look does not
    /// give the same row to another message in the same words. By their time and words
    /// (StoredUserRow.Identity): compacted, the session has such a row under a new number.
    @ObservationIgnored var confirmedRows: [String: Set<StoredUserRow.Identity>] = [:]
    /// session id → the newest run Hermes said had begun, and the admission it runs, by its
    /// submission id (`pending` of a session.info or a snapshot: an entry's `execution_generation`
    /// is that run's once it runs, null while it waits). A message put into that run is stored
    /// after that admission's row (DeliveryCheck.Before.turn). A turn Hermes begins itself is an
    /// admission of its own, named for a background process's completion, which no row names.
    @ObservationIgnored var began: [String: Began] = [:]

    struct Fence {
        var generation: Int?
        var revision: Int?
    }

    struct Began {
        var generation: Int
        var by: String
    }

    /// Never backwards: a frame that comes late cannot undo a newer one. A refusal's fresh fences
    /// (`replacing`) are the server's word.
    func note(_ sessionId: String, generation: Int?, revision: Int?, replacing: Bool = false) {
        var fence = fences[sessionId] ?? Fence()
        if let generation {
            fence.generation = replacing ? generation : max(generation, fence.generation ?? generation)
        }
        if let revision {
            fence.revision = replacing ? revision : max(revision, fence.revision ?? revision)
        }
        fences[sessionId] = fence
    }
}

/// What retrying a turn could do again (AppStore.retryRisk): the tools it called, by the names its
/// folded line shows, and whether Hermes said some of its actions may already have run.
struct RetryRisk: Equatable {
    var tools: [String]
    var actionsMayHaveRun: Bool

    /// 重试 asks first.
    var asks: Bool { !tools.isEmpty || actionsMayHaveRun }

    var message: String {
        let done = tools.isEmpty ? "Hermes 说这一轮有些操作可能已经执行了。" : "这一轮用过：\(tools.joined(separator: "、"))。"
        return "\(done)\n重试会让助手从头再做一遍，这些可能会再做一次。"
    }
}

/// Why a stop or a retry did not go through, in words.
nonisolated enum ControlError: LocalizedError {
    case unknownRun
    case notStored
    case refused(String, detail: String?)

    var errorDescription: String? {
        switch self {
        case .unknownRun:
            return "还不知道这一轮是服务器上的哪一次运行"
        case .notStored:
            return "找不到这条消息在服务器上存成了哪一行"
        case .refused(let reason, let detail):
            switch reason {
            case "session_busy": return "这一轮还没结束"
            case "invalid_params" where detail?.hasPrefix("compacted:") == true: return "这条消息已经压缩进摘要里了"
            case "invalid_params" where detail != nil: return "这条消息已经不在对话记录里了"
            case "unknown_method": return "服务器没有 session.mutate，重试不了"
            case "permission_denied": return "服务器不让这个连接改这个对话"
            case "revision_conflict", "stale_generation": return "对话刚刚变过，再点一次"
            default: return "服务器拒绝了（\(reason)）"
            }
        }
    }
}

extension AppStore {
    /// A turn is under way in this Bot Chat: from its first event to its end, or while Hermes says
    /// the session runs (a turn waiting for an approval, say).
    func turnRunning(_ botId: String) -> Bool {
        guard live, sessions[botId] != nil else { return false }
        return replying.contains(botId) || bot(botId)?.status == .working
    }

    // MARK: fences

    /// A snapshot (`session.resume`, `session.create`) or an event's params: the session's run and
    /// revision, and, as a turn ends, the row its prompt was stored as.
    func noteFences(_ frame: JSONValue) {
        guard let sessionId = frame["session_id"]?.string, !sessionId.isEmpty else { return }
        let type = frame["type"]?.string
        let payload = frame["payload"] ?? .null
        var generation = frame["execution_generation"]?.int
        var revision = frame["revision"]?.int
        if type == "session.info" || type == "session.updated" {
            generation = payload["execution_generation"]?.int ?? generation
            revision = payload["revision"]?.int ?? revision
        }
        control.note(sessionId, generation: generation, revision: revision)
        // which admission a run is: a snapshot's own `pending`, or a session.info's
        for entry in (type == "session.info" ? payload["pending"] : frame["pending"])?.array ?? [] {
            if let run = entry["execution_generation"]?.int, let id = entry["input_id"]?.string,
               run > control.began[sessionId]?.generation ?? 0 {
                control.began[sessionId] = ChatControl.Began(generation: run, by: id)
            }
        }
        guard type == "message.complete" else { return }
        // `submission_id` is whose turn it was: a prompt sent from here is named by its item's id
        let turn = payload["persisted_turn"]
        if let submission = turn?["submission_id"]?.string, let row = turn?["user_row_id"]?.int {
            control.storedRows[submission] = row
        }
        if let botId = sessionBots[sessionId] {
            control.stopping.remove(botId)
        }
    }

    // MARK: stop

    /// Stops the turn under way: `session.interrupt` for the run its frames carry. What had come
    /// stays, marked 已停止, once Hermes ends the turn (`message.complete`, status interrupted).
    func stopReply(_ botId: String) {
        guard turnRunning(botId), !readOnly, let sessionId = sessions[botId],
              !control.stopping.contains(botId)
        else { return }
        guard let generation = control.fences[sessionId]?.generation else {
            return controlNote("没停下来：\(ControlError.unknownRun.localizedDescription)", in: botId)
        }
        control.stopping.insert(botId)
        let stop = UUID()
        control.stops[botId] = stop
        Task {
            do {
                let handle = try await gateway.call("session.interrupt", [
                    "profile": .string(botId), "session_id": .string(sessionId),
                    "execution_generation": .number(Double(generation)),
                ])
                // nothing runs any more, so no turn end will come to say so
                if ["idle", "terminal"].contains(handle["execution_state"]?.string ?? "") {
                    control.stopping.remove(botId)
                }
            } catch {
                control.stopping.remove(botId)
                controlNote("没停下来：\(error.localizedDescription)", in: botId)
                return
            }
            // the turn's end clears it; if that never comes (the connection went), so does this
            try? await Task.sleep(for: .seconds(20))
            if control.stops[botId] == stop {
                control.stopping.remove(botId)
            }
        }
    }

    /// Hermes ended the turn you stopped. The reply keeps what had come, marked; with nothing come
    /// yet (stopped in a tool call, or before the model said anything) a line says so instead:
    /// Hermes's `text` is then only a placeholder.
    func markStopped(_ botId: String, reply id: String?) {
        control.stopping.remove(botId)
        if let id, let index = chats[botId]?.firstIndex(where: { $0.id == id }) {
            chats[botId]?[index].streaming = false
            if chats[botId]?[index].text.isEmpty == false {
                chats[botId]?[index].stopped = true
                return
            }
            chats[botId]?.remove(at: index)
        }
        chats[botId, default: []].append(ChatItem(id: UUID().uuidString, role: .system, at: Date(), text: "已停止",
                                                  stopped: true))
    }

    private func controlNote(_ text: String, in botId: String) {
        chats[botId, default: []].append(ChatItem(id: UUID().uuidString, role: .system, at: Date(), text: text))
    }

    // MARK: a failed turn

    /// Hermes ended the turn with an error (`message.complete`, status error). What had come stays
    /// as it came, and a line says why (TurnFailure); 重试 goes under it when Hermes says trying
    /// again may help (`error_surface.retryable`).
    func failReply(_ botId: String, _ payload: JSONValue, reply id: String?) {
        var streamed = ""
        if let id, let index = chats[botId]?.firstIndex(where: { $0.id == id }) {
            chats[botId]?[index].streaming = false
            streamed = chats[botId]?[index].text ?? ""
            if streamed.isEmpty {
                chats[botId]?.remove(at: index)
            }
        }
        let failure = TurnFailure.live(payload, streamed: streamed)
        chats[botId, default: []].append(ChatItem(id: UUID().uuidString, role: .system, at: Date(),
                                                  text: failure.line, failure: failure))
    }

    /// The line a failed turn gets, for its notification.
    nonisolated static func failureLine(_ payload: JSONValue, streamed: String) -> String {
        TurnFailure.live(payload, streamed: streamed).line
    }

    /// The row Hermes closes a failed turn with in the transcript (`display_kind` failed_turn: its
    /// notice as the text, the error and `error_surface` in `display_metadata`), as the line a
    /// live failure gets.
    static func failedTurn(_ row: JSONValue, id: String, at: Date, body: String) -> ChatItem? {
        guard row["display_kind"]?.string == "failed_turn" else { return nil }
        let failure = TurnFailure.stored(row, body: body)
        return ChatItem(id: id, role: .system, at: at, text: failure.line, failure: failure)
    }

    // MARK: retry

    /// The line 重试 goes under: how the chat's last turn ended, when it did not end well (you
    /// stopped it, or Hermes ended it with an error: a turn that answered has nothing to try
    /// again, and asking again would only run its tools twice), it answers a message you typed
    /// (not a notice Hermes sent in your name), nothing runs, and nothing you said came after it.
    /// Not after an error Hermes says trying again will not mend (`error_surface.retryable`
    /// false), nor for a message that took pictures, which Hermes cannot replay
    /// (AppStore.retryable).
    func retryTarget(_ botId: String) -> String? {
        guard live, !readOnly, sessions[botId] != nil, !turnRunning(botId), !control.retrying.contains(botId),
              let items = chats[botId],
              let end = items.lastIndex(where: { Self.endsTurn($0) }),
              items[end].stopped || items[end].failure != nil,
              items[end].failure?.retryable ?? true,
              let prompt = items[..<end].lastIndex(where: { Self.startsTurn($0) }),
              items[prompt].role == .user, Self.retryable(items[prompt]),
              !items[(end + 1)...].contains(where: { Self.startsTurn($0) })
        else { return nil }
        return items[end].id
    }

    /// What starts a turn: a message you typed (not one put into a turn already running), or a
    /// notice Hermes sends in your name (the board's word, another assistant's message).
    private static func startsTurn(_ item: ChatItem) -> Bool {
        (item.role == .user && !item.midTurn) || (item.role == .card && item.event?.startsTurn == true)
    }

    /// What ends one: a reply, or the line a stop before any words, or an error, leaves.
    private static func endsTurn(_ item: ChatItem) -> Bool {
        switch item.role {
        case .assistant: !item.streaming
        case .system: item.stopped || item.failure != nil
        default: false
        }
    }

    /// What 重试 would do again: the turn starts over from your words, and rewinding the chat
    /// does not undo what its tools did (a card made, a todo written, a message sent). So a turn
    /// that called tools, or that Hermes says may have run some actions (its notice for a turn
    /// that called tools), asks first. Nil when there is nothing to retry.
    func retryRisk(_ botId: String) -> RetryRisk? {
        guard let target = retryTarget(botId), let items = chats[botId],
              let end = items.firstIndex(where: { $0.id == target }),
              let prompt = items[..<end].lastIndex(where: { Self.startsTurn($0) })
        else { return nil }
        var tools: [String] = []
        for item in items[(prompt + 1)...] {
            // as the folded line names the calls (ChatLines.swift), and the cards the chat made
            var name = item.role == .tool ? item.toolName
                : item.role == .card && item.text.isEmpty ? item.cardTitle.map { "建卡片「\($0)」" } : nil
            // a message to another assistant went out, and would go out again
            if case .sent(let to)? = item.event {
                name = "给\(bot(to)?.name ?? to)发消息"
            }
            if let name, !tools.contains(name) {
                tools.append(name)
            }
        }
        return RetryRisk(tools: tools, actionsMayHaveRun: items[end].failure?.actionsMayHaveRun ?? false)
    }

    /// Asks the last prompt again, as Hermes's `/retry` does: the prompt's row and everything after
    /// it are taken back (`session.mutate` rewind, fenced by the session's revision and run), then
    /// the same words go in as a new turn. Refused because its row is not one of the session's
    /// (`invalid_params`), the prompt is taken back by the row it has now, if a compaction kept it
    /// (`rowNow`).
    func retryReply(_ botId: String) {
        guard let replyId = retryTarget(botId), let sessionId = sessions[botId],
              let items = chats[botId], let reply = items.firstIndex(where: { $0.id == replyId }),
              let promptIndex = items[..<reply].lastIndex(where: { Self.startsTurn($0) })
        else { return }
        let prompt = items[promptIndex]
        control.retrying.insert(botId)
        Task {
            defer { control.retrying.remove(botId) }
            do {
                let row = try await storedRow(of: prompt, botId: botId, sessionId: sessionId)
                let receipt: JSONValue
                do {
                    receipt = try await rewind(to: row, botId: botId, sessionId: sessionId)
                } catch ControlError.refused(let reason, let detail?) where reason == "invalid_params" {
                    guard let now = try await rowNow(of: prompt, was: row, botId: botId, sessionId: sessionId) else {
                        throw ControlError.refused(reason, detail: detail)
                    }
                    receipt = try await rewind(to: now, botId: botId, sessionId: sessionId)
                }
                guard sessions[botId] == sessionId else { return }
                // the turn is gone on the server: here too, then the same words again
                if let index = chats[botId]?.firstIndex(where: { $0.id == prompt.id }) {
                    chats[botId]?.removeSubrange(index...)
                }
                let typed = receipt["target_message"]?["content"]?.string ?? ""
                send(typed.isEmpty ? prompt.text : typed, to: botId)
            } catch {
                controlNote("没能重试：\(error.localizedDescription)", in: botId)
            }
        }
    }

    /// The row the prompt was stored as: in its id when it came from the transcript (`row-<id>`),
    /// from its turn's `persisted_turn` when it was sent from here; failing both, the newest page
    /// says: by the submission id Hermes keeps on the row, else by its words.
    private func storedRow(of prompt: ChatItem, botId: String, sessionId: String) async throws -> Int {
        if prompt.id.hasPrefix("row-"), let row = Int(prompt.id.dropFirst(4)) { return row }
        if let row = control.storedRows[prompt.id] { return row }
        let page = try await transcriptPage(botId, sessionId, limit: 20)
        // the page names it where its row is on it (transcriptPage)
        if let row = control.storedRows[prompt.id] { return row }
        let match = (page["rows"]?.array ?? []).last { row in
            row["role"]?.string == "user" && (row["text"]?.string ?? row["content"]?.string) == prompt.text
        }
        guard let row = match?["row_id"]?.int else { throw ControlError.notStored }
        return row
    }

    /// The row a prompt has now that Hermes would not take it back by `was`, its row before a
    /// compaction. A compaction stores the messages it keeps again under new numbers (in place, or
    /// in the session it moves to), and Hermes refuses the old number of one it kept as it refuses
    /// one it summarized (`compacted:`), or, once it compacted the session by itself in place, as
    /// one taken back (no longer in the session's history: the old row is marked so). The newest
    /// page says which: the row that names the prompt's submission (one sent from here: the copy
    /// of the turn's own prompt keeps it, transcriptPage reads it), else, for a prompt read from
    /// the transcript, the row with its time and words (StoredUserRow.Identity). Nil: no other row
    /// is it; it was summarized, or taken back.
    private func rowNow(of prompt: ChatItem, was row: Int, botId: String, sessionId: String) async throws -> Int? {
        // a whole page: the prompt is above every row its turn left, and a turn stopped in its
        // tools leaves many
        let page = try await transcriptPage(botId, sessionId, limit: Self.pageSize)
        if let now = control.storedRows[prompt.id], now != row { return now }
        guard DeliveryCheck.row(of: prompt.id) != nil else { return nil }
        let identity = StoredUserRow(text: prompt.text, at: prompt.at).identity
        return transcriptItems(page).compactMap { item -> Int? in
            guard item.role == .user, StoredUserRow(text: item.text, at: item.at).identity == identity else { return nil }
            return DeliveryCheck.row(of: item.id)
        }.last { $0 != row }
    }

    /// `session.mutate` rewind to `row`. A conflict names the session's fresh revision and run:
    /// once more with them. Any session of the profile `botId`: its Bot Chat's, or the one a
    /// skill is talked over in (SkillReviewTalk.askAgain).
    func rewind(to row: Int, botId: String, sessionId: String) async throws -> JSONValue {
        var attempt = 0
        while true {
            attempt += 1
            let fence = control.fences[sessionId]
            let reply = try await gateway.call("session.mutate", [
                "profile": .string(botId), "session_id": .string(sessionId),
                "request_id": .string(UUID().uuidString),
                "expected_revision": .number(Double(fence?.revision ?? 0)),
                "expected_generation": .number(Double(fence?.generation ?? 0)),
                "operation": "rewind",
                "payload": ["target_message_id": .number(Double(row))],
            ], keepRefusal: true)
            guard let refusal = reply["refusal"] else {
                control.note(sessionId, generation: reply["execution_generation"]?.int, revision: reply["revision"]?.int)
                return reply
            }
            let data = refusal["data"]
            let reason = data?["reason"]?.string ?? refusal["message"]?.string ?? ""
            if attempt == 1, reason == "revision_conflict" || reason == "stale_generation" {
                control.note(sessionId, generation: data?["execution_generation"]?.int,
                             revision: data?["revision"]?.int, replacing: true)
                continue
            }
            throw ControlError.refused(reason, detail: data?["detail"]?.string)
        }
    }

    // MARK: every chat's newest page

    /// Every attached Bot Chat's newest page, once connected: each chat then has its latest rows
    /// for the last data (AppStore+LastData.swift), and opens at once. A Bot Chat is still only
    /// created when you open its chat.
    func loadAttachedChats() async {
        for bot in bots where sessions[bot.id] != nil {
            guard live, gateway.phase == .online else { return }
            await openChat(bot.id)
        }
    }
}
