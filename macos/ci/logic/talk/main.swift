import Foundation

// SkillReviewTalk (the app's own file) against a review session's server as far as the talk can
// tell: issue #2's R11 (a message whose receipt is lost or refused), R12 (再试一次) and R13 (a
// subscription ended on a live socket).

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok {
        print("  ok  \(what)")
    } else {
        failures += 1
        print("FAIL  \(what)")
    }
}

final class Server {
    enum Outcome {
        case refuse(String)
        case lostAfterAdmitting
        case lostBefore
    }

    var rows: [JSONValue] = []
    var nextRow = 9000
    /// submission id → its words: Hermes admits an id once
    var admitted: [String: String] = [:]
    /// every prompt.submit's submission id, in order
    var submissions: [String] = []
    var running = false
    var pending: [String] = []
    var next: Outcome?
    /// Run while a prompt.submit is on its way: what you do meanwhile.
    var meanwhile: (() -> Void)?
    var resumeFails = false
    var createFails = false
    /// The session's stream: its frames are numbered (`seq`, in `epoch`) and a snapshot says where
    /// it was read, as Hermes does. Off: a server that numbers nothing.
    var numbered = false
    var epoch = "epoch-1"
    var seq = 0
    var resumes = 0
    /// What happens between a snapshot being read and its answer going out, one per resume.
    var beforeResumeAnswers: [() -> Void] = []
    /// Hermes stores a prompt's row as its turn begins, a moment after it is admitted. Set: an
    /// admitted prompt is listed as pending and its row waits here until `begin`.
    var storesAtStart = false
    var queued: [(id: String, text: String)] = []

    /// The next admitted prompt's turn begins: its row is stored now.
    @discardableResult
    func begin() -> Int? {
        guard !queued.isEmpty else { return nil }
        return add("user", queued.removeFirst().text)
    }

    /// The newest row of a role in these words.
    func row(_ role: String, _ text: String) -> Int? {
        rows.last { $0["role"]?.string == role && $0["text"]?.string == text }?["row_id"]?.int
    }

    func add(_ role: String, _ text: String, kind: String? = nil) -> Int {
        nextRow += 1
        var row: [String: JSONValue] = ["row_id": .number(Double(nextRow)), "role": .string(role), "text": .string(text)]
        if let kind {
            row["display_kind"] = .string(kind)
        }
        rows.append(.object(row))
        return nextRow
    }

    func users(_ text: String) -> Int {
        rows.filter { $0["role"]?.string == "user" && $0["text"]?.string == text }.count
    }

    func handle(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "session.create":
            if createFails { throw GatewayError.timeout(method) }
            return ["session_id": "review-sr1"]
        case "session.resume":
            if resumeFails { throw GatewayError.timeout(method) }
            resumes += 1
            // the session as it is read now; its answer goes out a moment later
            var snapshot: [String: JSONValue] = [
                "session_id": "review-sr1", "running": .bool(running), "display_messages": .array(rows),
                "pending": .array(pending.map { ["input_id": .string($0)] }),
                "execution_generation": 1, "revision": 1]
            if numbered {
                snapshot["replay_epoch"] = .string(epoch)
                snapshot["last_sequence"] = .number(Double(seq))
            }
            // what the session publishes in that moment is on the socket before the answer
            let meanwhile = beforeResumeAnswers.isEmpty ? nil : beforeResumeAnswers.removeFirst()
            meanwhile?()
            return .object(snapshot)
        case "prompt.submit":
            let id = params["submission_id"]?.string ?? ""
            let text = params["text"]?.string ?? ""
            submissions.append(id)
            meanwhile?()
            meanwhile = nil
            if admitted[id] != nil {
                // an exact retry: the same admission, no second turn
                return ["status": "terminal"]
            }
            let outcome = next
            next = nil
            switch outcome {
            case .refuse(let reason)?:
                throw GatewayError.rpc(code: 4001, message: reason, reason: reason)
            case .lostBefore?:
                throw GatewayError.timeout(method)
            case .lostAfterAdmitting?:
                admitted[id] = text
                _ = add("user", text)
                throw GatewayError.timeout(method)
            case nil:
                admitted[id] = text
                if storesAtStart {
                    queued.append((id, text))
                    pending.append(id)
                } else {
                    _ = add("user", text)
                }
                return ["status": "queued"]
            }
        default:
            return .null
        }
    }
}

func review() -> SkillReview {
    SkillReview(["id": "sr1", "profile": "shion", "skill": "ci-notes", "kind": "updated", "entries": ["e1"],
                 "status": "pending", "at": "2026-11-13T10:00:00+09:00"])!
}

func texts(_ talk: SkillReviewTalk, _ role: ChatRole) -> [String] {
    talk.items.filter { $0.role == role }.map(\.text)
}

/// The assistant answers the turn under way: its frames, and its row.
func answer(_ talk: SkillReviewTalk, _ server: Server, _ words: String, for submission: String? = nil) {
    _ = talk.take("message.start", sessionId: "review-sr1", [:])
    _ = talk.take("message.delta", sessionId: "review-sr1", ["text": .string(String(words.prefix(2)))])
    _ = talk.take("message.delta", sessionId: "review-sr1", ["text": .string(String(words.dropFirst(2)))])
    _ = server.add("assistant", words)
    var payload: [String: JSONValue] = ["text": .string(words), "status": "complete"]
    if let submission {
        payload["persisted_turn"] = ["submission_id": .string(submission)]
    }
    _ = talk.take("message.complete", sessionId: "review-sr1", .object(payload))
}

/// The turn under way ends with an error: Hermes closes it with a failed_turn row.
let surface: JSONValue = ["layer": "provider", "code": "rate_limit", "retryable": true, "provider_label": "OpenRouter"]
let notice = "Your request was not processed. Send it again if you still want me to carry it out."

func fail(_ talk: SkillReviewTalk, _ server: Server) {
    _ = talk.take("message.start", sessionId: "review-sr1", [:])
    let row = server.add("assistant", notice, kind: "failed_turn")
    server.rows[server.rows.count - 1] = ["row_id": .number(Double(row)), "role": "assistant", "text": .string(notice),
                                          "display_kind": "failed_turn",
                                          "display_metadata": ["error": "429 Too Many Requests", "error_surface": surface]]
    _ = talk.take("message.complete", sessionId: "review-sr1",
                  ["text": .string("OpenRouter rate-limited every one of 3 attempts.\n\n" + notice), "status": "error",
                   "error_surface": surface])
}

func opened() async -> (SkillReviewTalk, AppStore, Server) {
    let store = AppStore()
    let server = Server()
    store.gateway.answer = { try await server.handle($0, $1) }
    let talk = SkillReviewTalk(review: review())
    await talk.open(in: store)
    answer(talk, server, "审核意见：建议批准。")
    return (talk, store, server)
}

// ---- opening ----------------------------------------------------------------------------------
do {
    print("opening")
    let (talk, store, server) = await opened()
    check(talk.failure == nil && !talk.opening && !talk.busy, "opened, the opinion given")
    check(store.bound == ["review-sr1"], "the session was bound to the card")
    check(server.submissions == ["shion-review-sr1-material"], "the material went under the card's own id")
    check(talk.items.count == 2 && talk.isMaterial(talk.items[0]) && texts(talk, .assistant) == ["审核意见：建议批准。"],
          "the material folded, then the opinion")
    check(talk.sent.isEmpty, "nothing waits for a receipt")
}

// ---- R11: refused, with a draft typed meanwhile ---------------------------------------------------
do {
    print("R11 refused")
    let (talk, store, server) = await opened()
    talk.draft = "第一句"
    server.next = .refuse("queue_full")
    server.meanwhile = { talk.draft = "等的时候新打的" }
    await talk.send(in: store)
    let id = server.submissions.last!
    check(texts(talk, .user).last == "第一句", "the message stays where it was said")
    check(talk.sent[id] == .unsent("排队的消息太多了"), "it says it did not go, in Hermes's reason: \(String(describing: talk.sent[id]))")
    check(talk.draft == "等的时候新打的", "what was typed meanwhile is still in the composer: \(talk.draft)")
    check(!talk.busy && talk.failure == nil, "not answering, and nothing wrong with the session")
    await talk.resend(id, in: store)
    check(server.submissions.suffix(2) == [id, id], "重发 went under the same submission id")
    check(talk.sent[id] == nil && server.users("第一句") == 1, "Hermes has it, once")
    check(talk.draft == "等的时候新打的", "the composer was not touched by 重发")
    check(talk.busy, "answering now")
}

// ---- R11: the receipt lost, Hermes has it ------------------------------------------------------
do {
    print("R11 the receipt lost, the message there")
    let (talk, store, server) = await opened()
    talk.draft = "第二句"
    server.next = .lostAfterAdmitting
    server.running = true
    await talk.send(in: store)
    let id = server.submissions.last!
    check(talk.sent[id] == nil, "the session was asked, and has it: \(String(describing: talk.sent[id]))")
    check(texts(talk, .user).filter { $0 == "第二句" }.count == 1, "one bubble, the stored row's")
    check(server.submissions.filter { $0 == id }.count == 1 && server.users("第二句") == 1, "not sent a second time")
    check(talk.busy, "the turn runs: the session says so")
    check(talk.draft.isEmpty, "the composer was not given the words back")
    answer(talk, server, "收到第二句。")
    check(!talk.busy && texts(talk, .assistant).last == "收到第二句。", "answered")
}

// ---- R11: no answer, and Hermes does not have it ---------------------------------------------------
do {
    print("R11 no answer, the message not there")
    let (talk, store, server) = await opened()
    talk.draft = "第三句"
    server.next = .lostBefore
    await talk.send(in: store)
    let id = server.submissions.last!
    check(talk.sent[id] == .unsent(nil), "the session does not have it: 没发出去 \(String(describing: talk.sent[id]))")
    check(texts(talk, .user).last == "第三句" && talk.draft.isEmpty, "the bubble stays, the composer is left alone")
    await talk.retry(in: store)
    check(server.submissions.suffix(2) == [id, id] && server.users("第三句") == 1, "再试一次 sent that message again, under its id")
}

// ---- R11: the same words said before do not stand for a message that did not get there ------------
do {
    print("R11 the same words twice")
    let (talk, store, server) = await opened()
    talk.draft = "继续"
    await talk.send(in: store)
    answer(talk, server, "好的。")
    talk.draft = "继续"
    server.next = .lostBefore
    await talk.send(in: store)
    let id = server.submissions.last!
    check(talk.sent[id] == .unsent(nil), "the earlier 继续 is not taken for this one")
    check(texts(talk, .user).filter { $0 == "继续" }.count == 2, "both are shown")
}

// ---- R11: no answer while not connected: settled when the session can be read again -----------------
do {
    print("R11 no answer, and no connection to ask on")
    let (talk, store, server) = await opened()
    talk.draft = "第四句"
    server.next = .lostAfterAdmitting
    server.resumeFails = true
    await talk.send(in: store)
    let id = server.submissions.last!
    check(talk.sent[id] == .unsure && !talk.busy, "unsure, until the session can be read")
    check(texts(talk, .user).last == "第四句", "the bubble stays meanwhile")
    server.resumeFails = false
    try? await talk.read(in: store)
    check(talk.sent[id] == nil && texts(talk, .user).filter { $0 == "第四句" }.count == 1, "the connection back: it is there, once")
}

// ---- R11: admitted, its turn not begun (no row yet) --------------------------------------------------
do {
    print("R11 admitted, no row yet")
    let (talk, store, server) = await opened()
    talk.draft = "第五句"
    server.next = .lostBefore
    server.meanwhile = { server.pending = [server.submissions.last!] }
    await talk.send(in: store)
    let id = server.submissions.last!
    check(talk.sent[id] == nil && texts(talk, .user).last == "第五句", "Hermes lists it as pending: there, and still shown")
}

// ---- R12: a failed turn is asked again ------------------------------------------------------------
do {
    print("R12 a failed turn")
    let (talk, store, server) = await opened()
    talk.draft = "这个技能安全吗"
    await talk.send(in: store)
    let first = server.submissions.last!
    fail(talk, server)
    check(talk.failure?.hasPrefix("这一轮出错了：") == true && !talk.busy, "the failure is said: \(String(describing: talk.failure))")
    check(texts(talk, .assistant).count == 1, "Hermes's words about the failure are not shown as a reply")
    let live = talk.failure
    let row = server.rows.last { $0["role"]?.string == "user" }!["row_id"]!.int!
    var rewound = false
    store.rewindAnswer = { target in
        // what went wrong is still said while the turn is being taken back
        check(talk.failure == live, "the failure stays until the new try begins")
        server.rows.removeAll { ($0["row_id"]?.int ?? 0) >= target }
        rewound = true
        return ["target_message": ["content": "这个技能安全吗"]]
    }
    let before = server.submissions.count
    await talk.retry(in: store)
    check(store.rewinds == [row] && rewound, "the failed turn was taken back from its message's row: \(store.rewinds) vs \(row)")
    check(server.submissions.count == before + 1 && server.submissions.last != first, "asked again, a new submission")
    check(server.users("这个技能安全吗") == 1 && texts(talk, .user).filter { $0 == "这个技能安全吗" }.count == 1, "the question is there once")
    check(talk.failure == nil && talk.busy && !talk.retrying, "a new try is under way, nothing said wrong any more")
    answer(talk, server, "安全。")
    check(texts(talk, .assistant).last == "安全。" && talk.failure == nil, "answered this time")
}

// ---- R12: the material's turn failed --------------------------------------------------------------
do {
    print("R12 the first turn failed")
    let store = AppStore()
    let server = Server()
    store.gateway.answer = { try await server.handle($0, $1) }
    let talk = SkillReviewTalk(review: review())
    await talk.open(in: store)
    fail(talk, server)
    check(talk.failure != nil, "the failure is said")
    store.rewindAnswer = { target in
        server.rows.removeAll { ($0["row_id"]?.int ?? 0) >= target }
        return ["target_message": ["content": .string(store.material)]]
    }
    await talk.retry(in: store)
    check(store.rewinds.count == 1 && server.submissions.count == 2 && server.submissions[1] != server.submissions[0],
          "the material was asked again under a new id (the first is admitted and done)")
    check(talk.items.filter { talk.isMaterial($0) }.count == 1 && talk.items.count == 1, "still folded as the material, once")
    answer(talk, server, "审核意见。")
    // the sheet opened again: a new talk reads the session
    let again = SkillReviewTalk(review: review())
    await again.open(in: store)
    check(again.failure == nil && again.items.count == 2 && again.isMaterial(again.items[0]), "read again: the material, the opinion, no failure")
}

// ---- R12: read again after a failure, the failure is still said ----------------------------------------
do {
    print("R12 a failed turn, the sheet opened again")
    let (talk, store, server) = await opened()
    talk.draft = "再问一句"
    await talk.send(in: store)
    fail(talk, server)
    let again = SkillReviewTalk(review: SkillReview(["id": "sr1", "profile": "shion", "skill": "ci-notes", "kind": "updated",
                                                     "entries": ["e1"], "status": "pending", "review_session": "review-sr1",
                                                     "at": "2026-11-13T10:00:00+09:00"])!)
    await again.open(in: store)
    check(again.failure == talk.failure && again.failure != nil, "the stored failure is said again, in the same words: \(String(describing: again.failure))")
    check(server.submissions.count == 2, "opening sent nothing")
    store.rewindAnswer = { target in
        server.rows.removeAll { ($0["row_id"]?.int ?? 0) >= target }
        return ["target_message": ["content": "再问一句"]]
    }
    await again.retry(in: store)
    check(store.rewinds.count == 1 && server.submissions.count == 3 && again.failure == nil && again.busy, "再试一次 asked it again")
    _ = talk
}

// ---- R12: Hermes will not take the turn back ------------------------------------------------------
do {
    print("R12 no rewind in this session")
    let (talk, store, server) = await opened()
    talk.draft = "再问一句"
    await talk.send(in: store)
    fail(talk, server)
    store.rewindAnswer = { _ in throw ControlError.refused("no method session.mutate", detail: nil) }
    await talk.retry(in: store)
    check(server.users("再问一句") == 2 && talk.failure == nil && talk.busy, "asked again after the failed turn")
}

// ---- R12: the session moved under the rewind -----------------------------------------------------
do {
    print("R12 a rewind refused for now")
    let (talk, store, server) = await opened()
    talk.draft = "再问一句"
    await talk.send(in: store)
    fail(talk, server)
    let before = server.submissions.count
    store.rewindAnswer = { _ in throw ControlError.refused("session_busy", detail: nil) }
    await talk.retry(in: store)
    check(server.submissions.count == before, "nothing was sent")
    check(talk.failure == "没能重试：这一轮还没结束" && !talk.retrying, "why it was not tried is said: \(String(describing: talk.failure))")
    store.rewindAnswer = { target in
        server.rows.removeAll { ($0["row_id"]?.int ?? 0) >= target }
        return .null
    }
    await talk.retry(in: store)
    check(server.submissions.count == before + 1 && talk.failure == nil, "再试一次 again goes through")
}

// ---- R12: a session that would not open -----------------------------------------------------------
do {
    print("R12 the session not made")
    let store = AppStore()
    let server = Server()
    store.gateway.answer = { try await server.handle($0, $1) }
    let talk = SkillReviewTalk(review: review())
    server.createFails = true
    await talk.open(in: store)
    check(talk.failure != nil && talk.session == nil, "it says it did not open")
    server.createFails = false
    await talk.retry(in: store)
    check(talk.failure == nil && talk.session == "review-sr1" && server.submissions.count == 1, "再试一次 opened it and gave the material")
}

// ---- R13: the subscription ended on a live socket ----------------------------------------------------
do {
    print("R13 session.replay_gap")
    let (talk, store, server) = await opened()
    talk.draft = "讲长一点"
    await talk.send(in: store)
    _ = talk.take("message.start", sessionId: "review-sr1", [:])
    _ = talk.take("message.delta", sessionId: "review-sr1", ["text": "第一段。"])
    check(talk.busy, "answering")
    // the subscription is retired; the turn ends meanwhile, unseen
    _ = server.add("assistant", "第一段。第二段。第三段。")
    let resumes = store.gateway.calls.filter { $0.method == "session.resume" }.count
    check(talk.take("session.replay_gap", sessionId: "review-sr1", ["latest_seq": 40]), "the gap is this talk's")
    store.gateway.replayAnswer = false
    await talk.rejoin(in: store)
    check(store.gateway.replays == ["review-sr1"], "what it missed was asked for")
    check(store.gateway.calls.filter { $0.method == "session.resume" }.count == resumes + 1
          && store.gateway.attached.contains("review-sr1"), "read and attached again")
    check(!talk.busy && texts(talk, .assistant).last == "第一段。第二段。第三段。", "no longer answering, the whole reply shown")
    talk.draft = "谢谢"
    await talk.send(in: store)
    check(server.users("谢谢") == 1, "it can be written to again")
}

do {
    print("R13 the gap while the turn still runs")
    let (talk, store, server) = await opened()
    talk.draft = "讲长一点"
    await talk.send(in: store)
    _ = talk.take("message.start", sessionId: "review-sr1", [:])
    _ = talk.take("message.delta", sessionId: "review-sr1", ["text": "第一段。"])
    server.running = true
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = false
    await talk.rejoin(in: store)
    check(talk.busy && talk.items.last?.streaming == true && talk.items.last?.text == "第一段。\n\n…\n\n",
          "still answering in its bubble, an ellipsis where the lost part was: \(String(describing: talk.items.last?.text))")
    _ = talk.take("message.delta", sessionId: "review-sr1", ["text": "第三段。"])
    _ = server.add("assistant", "第一段。第二段。第三段。")
    _ = talk.take("message.complete", sessionId: "review-sr1", ["text": "第一段。第二段。第三段。", "status": "complete"])
    check(!talk.busy && texts(talk, .assistant).last == "第一段。第二段。第三段。" && talk.items.last?.streaming == false,
          "the end has the whole reply")
}

do {
    print("R13 the session could not be read again")
    let (talk, store, server) = await opened()
    talk.draft = "讲长一点"
    await talk.send(in: store)
    _ = talk.take("message.start", sessionId: "review-sr1", [:])
    server.resumeFails = true
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    await talk.rejoin(in: store)
    check(!talk.busy && talk.failure != nil, "not left answering: it says so, with 再试一次")
    server.resumeFails = false
    _ = server.add("assistant", "讲完了。")
    await talk.retry(in: store)
    check(talk.failure == nil && texts(talk, .assistant).last == "讲完了。" && server.users("讲长一点") == 1, "再试一次 read it again, and sent nothing")
}

// ---- RR06: nothing is said before there is a session -----------------------------------------------
for failing in ["session.create", "the bind"] {
    print("RR06 \(failing) failed, something typed and sent")
    let store = AppStore()
    let server = Server()
    store.gateway.answer = { try await server.handle($0, $1) }
    let talk = SkillReviewTalk(review: review())
    server.createFails = failing == "session.create"
    store.bindFails = failing == "the bind"
    await talk.open(in: store)
    check(talk.failure != nil && talk.session == nil, "it says it did not open")
    talk.draft = "这个技能什么时候会用到？"
    await talk.send(in: store)
    check(talk.draft == "这个技能什么时候会用到？", "what was typed is still in the composer: '\(talk.draft)'")
    check(talk.items.isEmpty && talk.sent.isEmpty && !talk.busy, "nothing shown as said, nothing on its way: \(talk.items.count) item(s)")
    check(server.submissions.isEmpty, "nothing was sent")
    server.createFails = false
    store.bindFails = false
    await talk.retry(in: store)
    check(talk.failure == nil && talk.session == "review-sr1" && server.submissions == ["shion-review-sr1-material"],
          "再试一次 opened it, and the material went first: \(server.submissions)")
    check(talk.draft == "这个技能什么时候会用到？", "the words are still there after 再试一次: '\(talk.draft)'")
    answer(talk, server, "审核意见：建议批准。")
    await talk.send(in: store)
    check(server.users("这个技能什么时候会用到？") == 1 && talk.draft.isEmpty && texts(talk, .user).last == "这个技能什么时候会用到？",
          "now they go, once: \(server.users("这个技能什么时候会用到？")) row(s)")
}

// ---- RR07: a snapshot older than frames already taken -----------------------------------------------
/// A frame of the session's stream as the gateway hands it on (Gateway.deliver): the store's note
/// of it, then the talk. Numbered where the server numbers.
func frame(_ talk: SkillReviewTalk, _ store: AppStore, _ server: Server, _ type: String, _ payload: JSONValue) {
    var params: [String: JSONValue] = ["type": .string(type), "session_id": "review-sr1", "payload": payload]
    if server.numbered {
        server.seq += 1
        params["seq"] = .number(Double(server.seq))
        params["replay_epoch"] = .string(server.epoch)
    }
    store.words.note(.object(params))
    _ = talk.take(type, sessionId: "review-sr1", payload)
}

/// A talk on a server that numbers its stream, the opinion given, then "讲长一点" asked and its
/// reply begun: answering, one part of the reply here.
func answering(numbered: Bool = true) async -> (SkillReviewTalk, AppStore, Server, String) {
    let store = AppStore()
    let server = Server()
    server.numbered = numbered
    store.gateway.answer = { try await server.handle($0, $1) }
    let talk = SkillReviewTalk(review: review())
    await talk.open(in: store)
    frame(talk, store, server, "message.start", [:])
    frame(talk, store, server, "message.delta", ["text": "审核意见：建议批准。"])
    _ = server.add("assistant", "审核意见：建议批准。")
    frame(talk, store, server, "message.complete", ["text": "审核意见：建议批准。", "status": "complete"])
    frame(talk, store, server, "session.info", ["running": false])
    talk.draft = "讲长一点"
    await talk.send(in: store)
    let id = server.submissions.last!
    server.running = true
    frame(talk, store, server, "session.info", ["running": true])
    frame(talk, store, server, "message.start", [:])
    frame(talk, store, server, "message.delta", ["text": "第一段。"])
    return (talk, store, server, id)
}

/// The turn ends on the server: its row, and its frames on the socket. The end names the rows the
/// turn was stored as, as Hermes does (`persisted_turn`); `named` false leaves them out.
func ends(_ talk: SkillReviewTalk, _ store: AppStore, _ server: Server, _ id: String, named: Bool = true) {
    let reply = server.add("assistant", "第一段。第二段。")
    server.running = false
    var turn: [String: JSONValue] = ["submission_id": .string(id)]
    if named {
        turn["final_assistant_row_id"] = .number(Double(reply))
        if let asked = server.row("user", server.admitted[id] ?? "") {
            turn["user_row_id"] = .number(Double(asked))
        }
    }
    frame(talk, store, server, "message.delta", ["text": "第二段。"])
    frame(talk, store, server, "message.complete", ["text": "第一段。第二段。", "status": "complete", "persisted_turn": .object(turn)])
    frame(talk, store, server, "session.info", ["running": false])
}

for caughtUp in [true, false] {
    print("RR07 the turn's end overtakes the snapshot (the frames missed \(caughtUp ? "replayed" : "not to be had"))")
    let (talk, store, server, id) = await answering()
    check(talk.busy && talk.items.last?.streaming == true, "answering")
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", ["latest_seq": .number(Double(server.seq))])
    store.gateway.replayAnswer = caughtUp
    let resumes = server.resumes
    // read while the turn still runs; the turn ends before the answer goes out
    server.beforeResumeAnswers = [{ ends(talk, store, server, id) }]
    await talk.rejoin(in: store)
    check(!talk.busy, "not left answering")
    check(texts(talk, .assistant).filter { $0 == "第一段。第二段。" }.count == 1 && talk.items.last?.text == "第一段。第二段。",
          "the reply is shown, whole and once: \(texts(talk, .assistant))")
    check(talk.items.allSatisfy { !$0.streaming }, "no bubble still arriving")
    check(server.resumes == resumes + 2, "the snapshot older than the turn's end was asked for again: \(server.resumes - resumes) resume(s)")
    talk.draft = "谢谢"
    await talk.send(in: store)
    check(server.users("谢谢") == 1, "it can be written to again")
}

do {
    print("RR07 control: an ordinary gap, nothing overtakes the snapshot")
    let (talk, store, server, _) = await answering()
    // the turn ends unseen: this socket's subscription is over
    _ = server.add("assistant", "第一段。第二段。")
    server.running = false
    server.seq += 30
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", ["latest_seq": .number(Double(server.seq))])
    store.gateway.replayAnswer = false
    let resumes = server.resumes
    await talk.rejoin(in: store)
    check(server.resumes == resumes + 1, "read once: \(server.resumes - resumes)")
    check(!talk.busy && texts(talk, .assistant).last == "第一段。第二段。" && talk.items.allSatisfy { !$0.streaming },
          "no longer answering, the whole reply shown")
}

do {
    print("RR07 control: the turn really still runs, only its words overtake the snapshot")
    let (talk, store, server, id) = await answering()
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = true
    let resumes = server.resumes
    server.beforeResumeAnswers = [{ frame(talk, store, server, "message.delta", ["text": "第二段。"]) }]
    await talk.rejoin(in: store)
    check(server.resumes == resumes + 1, "a reply's words are no reason to read again: \(server.resumes - resumes) resume(s)")
    check(talk.busy && talk.items.last?.streaming == true && talk.items.last?.text == "第一段。第二段。",
          "still answering in its bubble: \(String(describing: talk.items.last?.text))")
    _ = server.add("assistant", "第一段。第二段。第三段。")
    server.running = false
    frame(talk, store, server, "message.complete", ["text": "第一段。第二段。第三段。", "status": "complete",
                                                    "persisted_turn": ["submission_id": .string(id)]])
    check(!talk.busy && texts(talk, .assistant).last == "第一段。第二段。第三段。", "and it ends as it should")
}

do {
    print("RR07 a turn begins between the snapshot and its answer")
    let (talk, store, server, id) = await answering()
    ends(talk, store, server, id)
    check(!talk.busy, "the turn over")
    // a question admitted and waiting; the socket's subscription ends, and the turn starts as the session is read again
    talk.draft = "再讲一段"
    await talk.send(in: store)
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = true
    let resumes = server.resumes
    server.beforeResumeAnswers = [{
        server.running = true
        frame(talk, store, server, "session.info", ["running": true])
        frame(talk, store, server, "message.start", [:])
        frame(talk, store, server, "message.delta", ["text": "好，"])
    }]
    await talk.rejoin(in: store)
    check(talk.busy && talk.items.last?.streaming == true && talk.items.last?.text == "好，",
          "answering, in the bubble the frames began: \(String(describing: talk.items.last?.text))")
    check(server.resumes == resumes + 2, "read again: \(server.resumes - resumes)")
    frame(talk, store, server, "message.delta", ["text": "再讲一段。"])
    check(talk.items.last?.text == "好，再讲一段。", "and the reply goes on in it")
}

do {
    print("RR07 every snapshot is overtaken: asked a few times, then the frames' word stands")
    let (talk, store, server, _) = await answering()
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = true
    let resumes = server.resumes
    // the snapshots all say the turn runs; each time a frame says it does not before the answer
    server.beforeResumeAnswers = Array(repeating: { frame(talk, store, server, "session.info", ["running": false]) }, count: 12)
    await talk.rejoin(in: store)
    check(server.resumes == resumes + 1 + SessionWords.rereads, "bounded: \(server.resumes - resumes) resume(s)")
    check(!talk.busy, "what the newest frame said of the turn stands over the snapshot's word")
}

do {
    print("RR07 a server that numbers nothing: as before")
    let (talk, store, server, id) = await answering(numbered: false)
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = false
    let resumes = server.resumes
    server.beforeResumeAnswers = [{ ends(talk, store, server, id) }]
    await talk.rejoin(in: store)
    check(server.resumes == resumes + 1, "nothing tells the snapshot older: read once")
}

do {
    print("RR07 a snapshot of another epoch is not older than the last one's frames")
    let (talk, store, server, _) = await answering()
    // the server started again: a new epoch, numbered from the start
    _ = server.add("assistant", "第一段。第二段。")
    server.running = false
    server.epoch = "epoch-2"
    server.seq = 2
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = false
    let resumes = server.resumes
    await talk.rejoin(in: store)
    check(server.resumes == resumes + 1 && !talk.busy && texts(talk, .assistant).last == "第一段。第二段。",
          "read once, and taken as it is")
}

// ---- RR07, however often the snapshot comes back older than the frames -----------------------------
/// A frame that says something a snapshot says too, and changes nothing in the talk: every
/// snapshot it comes after is older than it.
func word(_ talk: SkillReviewTalk, _ store: AppStore, _ server: Server) -> () -> Void {
    { frame(talk, store, server, "session.info", ["running": .bool(server.running)]) }
}

for named in [true, false] {
    print("RR07 every snapshot is overtaken, the last by the turn's end (the end \(named ? "names" : "does not name") its rows)")
    let (talk, store, server, id) = await answering()
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = true
    let resumes = server.resumes
    let again = word(talk, store, server)
    // the last snapshot is read while the turn still runs and has no row of its reply
    server.beforeResumeAnswers = [again, again, again, { ends(talk, store, server, id, named: named) }]
    await talk.rejoin(in: store)
    check(server.resumes == resumes + 1 + SessionWords.rereads, "asked for a few times, no more: \(server.resumes - resumes) resume(s)")
    check(!talk.busy && talk.items.allSatisfy { !$0.streaming }, "not left answering")
    check(texts(talk, .assistant) == ["审核意见：建议批准。", "第一段。第二段。"],
          "the reply the frames brought is shown, whole and once, though no snapshot has its row: \(texts(talk, .assistant))")
    check(texts(talk, .user).filter { $0 == "讲长一点" }.count == 1 && talk.items.last?.text == "第一段。第二段。", "under your message, which is there once")
    // read again with nothing in the way: the rows are the same things, once
    await talk.open(in: store)
    check(texts(talk, .assistant) == ["审核意见：建议批准。", "第一段。第二段。"] && texts(talk, .user).filter { $0 == "讲长一点" }.count == 1,
          "read again with nothing overtaking: each still once")
    talk.draft = "谢谢"
    await talk.send(in: store)
    check(server.users("谢谢") == 1, "it can be written to again")
}

for named in [true, false] {
    print("RR07 the turn's end is overtaken in its turn: a snapshot older than the frames that has the reply's row (the end \(named ? "names" : "does not name") its rows)")
    let (talk, store, server, id) = await answering()
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = true
    let again = word(talk, store, server)
    server.beforeResumeAnswers = [{ ends(talk, store, server, id, named: named) }, again, again, again]
    await talk.rejoin(in: store)
    check(!talk.busy && texts(talk, .assistant) == ["审核意见：建议批准。", "第一段。第二段。"],
          "the reply is its row, not shown a second time: \(texts(talk, .assistant))")
    check(texts(talk, .user).filter { $0 == "讲长一点" }.count == 1, "nor your message")
}

/// The turn under way fails on the server: Hermes closes it with a failed_turn row and says so on
/// the stream.
func fails(_ talk: SkillReviewTalk, _ store: AppStore, _ server: Server) {
    let row = server.add("assistant", notice, kind: "failed_turn")
    server.rows[server.rows.count - 1] = ["row_id": .number(Double(row)), "role": "assistant", "text": .string(notice),
                                          "display_kind": "failed_turn",
                                          "display_metadata": ["error": "429 Too Many Requests", "error_surface": surface]]
    server.running = false
    frame(talk, store, server, "message.complete",
          ["text": .string("OpenRouter rate-limited every one of 3 attempts.\n\n" + notice), "status": "error", "error_surface": surface])
    frame(talk, store, server, "session.info", ["running": false])
}

do {
    print("RR07 every snapshot is overtaken, the last by a whole turn that failed")
    let (talk, store, server, id) = await answering()
    ends(talk, store, server, id)
    server.storesAtStart = true
    talk.draft = "再讲一段"
    await talk.send(in: store)
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = true
    let again = word(talk, store, server)
    // the last snapshot ends with the reply before: it has neither the message's row nor the failure's
    server.beforeResumeAnswers = [again, again, again, {
        server.pending = []
        server.begin()
        server.running = true
        frame(talk, store, server, "message.start", [:])
        fails(talk, store, server)
    }]
    await talk.rejoin(in: store)
    check(!talk.busy && talk.failure?.contains("OpenRouter") == true,
          "what the frame said went wrong is not taken back by a snapshot that ends with the reply before: \(String(describing: talk.failure))")
    check(texts(talk, .user).last == "再讲一段", "and the message it was for is still there")
}

do {
    print("RR07 every snapshot is overtaken, the last by a turn that failed")
    let (talk, store, server, _) = await answering()
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = true
    let again = word(talk, store, server)
    server.beforeResumeAnswers = [again, again, again, { fails(talk, store, server) }]
    await talk.rejoin(in: store)
    check(!talk.busy, "not left answering")
    check(talk.failure?.contains("OpenRouter") == true, "what the frame said went wrong is still said: \(String(describing: talk.failure))")
    check(texts(talk, .assistant).last == "第一段。", "and what had come of the reply stays as it came: \(texts(talk, .assistant))")
    let before = server.submissions.count
    await talk.retry(in: store)
    check(server.submissions.count == before + 1 && server.rows.last?["text"]?.string == "讲长一点", "再试一次 asks the same message again")
}

do {
    print("RR07 every snapshot is overtaken, the last by the start of your message's turn")
    let (talk, store, server, id) = await answering()
    ends(talk, store, server, id)
    server.storesAtStart = true
    talk.draft = "再讲一段"
    await talk.send(in: store)
    let asked = server.submissions.last!
    check(talk.sent[asked] == nil && server.users("再讲一段") == 0, "received, its row not stored yet")
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = true
    let again = word(talk, store, server)
    server.beforeResumeAnswers = [again, again, again, {
        server.pending = []
        server.begin()
        server.running = true
        frame(talk, store, server, "session.info", ["running": true])
        frame(talk, store, server, "message.start", [:])
        frame(talk, store, server, "message.delta", ["text": "好，"])
    }]
    await talk.rejoin(in: store)
    check(texts(talk, .user).filter { $0 == "再讲一段" }.count == 1, "your message is still there, once: \(texts(talk, .user))")
    check(talk.busy && talk.items.suffix(2).map(\.text) == ["再讲一段", "好，"] && talk.items.last?.streaming == true,
          "and its reply goes on under it: \(talk.items.suffix(2).map(\.text))")
}

do {
    print("a message received and not begun yet, the session read with nothing overtaking")
    let (talk, store, server, id) = await answering()
    ends(talk, store, server, id)
    server.storesAtStart = true
    talk.draft = "再讲一段"
    await talk.send(in: store)
    _ = talk.take("session.replay_gap", sessionId: "review-sr1", [:])
    store.gateway.replayAnswer = true
    let resumes = server.resumes
    await talk.rejoin(in: store)
    check(server.resumes == resumes + 1, "read once")
    check(texts(talk, .user).last == "再讲一段", "Hermes lists it as admitted: it stays, though no row is it yet: \(texts(talk, .user))")
    server.pending = []
    server.begin()
    await talk.open(in: store)
    check(texts(talk, .user).filter { $0 == "再讲一段" }.count == 1, "and is its row once the turn has begun")
}

// ---- SessionWords ---------------------------------------------------------------------------------
do {
    print("SessionWords")
    var words = SessionWords()
    func at(_ type: String, _ seq: Int, _ payload: JSONValue = [:], epoch: String = "e", session: String = "s") -> JSONValue {
        ["type": .string(type), "session_id": .string(session), "payload": payload, "seq": .number(Double(seq)), "replay_epoch": .string(epoch)]
    }
    let snapshot: JSONValue = ["session_id": "s", "replay_epoch": "e", "last_sequence": 10, "running": true]
    check(!words.outdate(snapshot) && words.running(after: snapshot) == nil, "nothing taken: the snapshot is the newest word")
    words.note(at("message.start", 8))
    words.note(at("message.delta", 12))
    check(!words.outdate(snapshot) && words.running(after: snapshot) == nil, "a start before it and words after it do not outdate it")
    words.note(at("message.complete", 13))
    check(words.outdate(snapshot) && words.running(after: snapshot) == false, "a turn's end after it does, and says no turn runs")
    words.note(at("session.info", 14, ["running": true]))
    check(words.running(after: snapshot) == true, "the newest word on the turn is the one")
    words.note(at("session.info", 15, ["pending": []]))
    check(words.running(after: snapshot) == true && words.outdate(snapshot), "a frame that does not say leaves the last word")
    check(!words.outdate(["session_id": "s", "replay_epoch": "e", "last_sequence": 15]), "a snapshot read after them is not older")
    check(!words.outdate(["session_id": "s", "replay_epoch": "f", "last_sequence": 1]), "nor one of another epoch")
    check(!words.outdate(["session_id": "s"]) && words.running(after: ["session_id": "s"]) == nil, "nor one that does not say where it was read")
    check(!words.outdate(["session_id": "t", "replay_epoch": "e", "last_sequence": 1]), "another session's frames say nothing of this one")
    words.note(at("approval.request", 20, ["prompt_id": "p1"]))
    check(words.outdate(["session_id": "s", "replay_epoch": "e", "last_sequence": 19]), "something asked after it outdates it")
    words.note(["type": "message.complete", "session_id": "s", "payload": [:]])
    check(!words.outdate(["session_id": "s", "replay_epoch": "e", "last_sequence": 20]), "a frame without a place in the stream outdates nothing")
    check(words.ended(after: ["session_id": "s", "replay_epoch": "e", "last_sequence": 12])
          && !words.ended(after: ["session_id": "s", "replay_epoch": "e", "last_sequence": 13])
          && !words.ended(after: ["session_id": "s", "replay_epoch": "f", "last_sequence": 1]),
          "a turn ended after a snapshot read before its end, not after one read since, nor one of another epoch")
    // what waits for you: p0 listed and settled since, p1 asked since, p2 listed and not said of again
    words.note(at("approval.settled", 21, ["prompt_id": "p0"]))
    let listed: JSONValue = ["session_id": "s", "replay_epoch": "e", "last_sequence": 19, "running": false,
                             "prompts": [["prompt_id": "p0"], ["prompt_id": "p2"]]]
    let now = words.current(listed)
    check((now["prompts"]?.array ?? []).compactMap { $0["prompt_id"]?.string } == ["p2", "p1"],
          "what frames said since stands over the list: settled since is gone, asked since is there, the rest stays: \(String(describing: now["prompts"]))")
    check(now["running"]?.bool == false && now["last_sequence"]?.int == 19, "the rest of the snapshot is its own")
    words.note(at("session.info", 22, ["running": true]))
    check(words.current(listed)["running"]?.bool == true, "and whether a turn runs is the newest frame's word")
    let later: JSONValue = ["session_id": "s", "replay_epoch": "e", "last_sequence": 22, "running": false, "prompts": [["prompt_id": "p0"]]]
    check(words.current(later) == later, "a snapshot read after every frame is itself")
    let other: JSONValue = ["session_id": "s", "replay_epoch": "f", "last_sequence": 1, "running": false, "prompts": [["prompt_id": "p0"]]]
    check(words.current(other) == other, "so is one of another epoch")
}

// ---- SkillReviewDelivery ------------------------------------------------------------------------------
do {
    print("SkillReviewDelivery.found")
    typealias D = SkillReviewDelivery
    check(D.found(waiting: [("a", "继续")], known: ["继续"], rows: ["继续"], pending: []) == [:], "an older row is not a new message")
    check(D.found(waiting: [("a", "继续")], known: ["继续"], rows: ["继续", "继续"], pending: []) == ["a": .stored], "a new row is")
    check(D.found(waiting: [("a", "继续"), ("b", "继续")], known: [], rows: ["继续"], pending: []) == ["a": .stored],
          "one row answers for one message, the oldest")
    check(D.found(waiting: [("a", "x")], known: [], rows: [], pending: ["a"]) == ["a": .admitted], "listed as pending")
    check(D.found(waiting: [("a", "x")], known: [], rows: ["x"], pending: ["a"]) == ["a": .stored], "a row wins over the list")
    check(SkillReviewMaterial.opens(SkillReviewMaterial.prompt(skill: "ci", kind: .created, assistant: "詩音", talk: [], files: [],
                                                             document: nil, complete: true)), "the material is known by its opening")
    check(!SkillReviewMaterial.opens("这个技能安全吗"), "a question of yours is not the material")
}

print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
