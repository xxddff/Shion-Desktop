import Foundation

// The store's own sending methods (cut from the production files, AppStore+Compose.swift whole),
// run against a gateway that records what it is called with. Each line says what is expected.

var failures = 0

func check(_ what: String, _ ok: Bool) {
    print(ok ? "ok   " : "FAIL ", what)
    if !ok { failures += 1 }
}

/// Waits for what a send's task does, a little at a time.
func until(_ condition: () -> Bool) async {
    for _ in 0..<150 where !condition() {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

let bot = "shion", session = "s1"

/// A message's same-words boundary as words: the rows it names, and how many other messages it
/// counts beside them. Read off the value's own fields, so the same check runs on sources that
/// keep a count and on sources that keep the messages' ids.
func shape(_ before: DeliveryCheck.Before?) -> String {
    guard let before else { return "none" }
    var more = 0
    for child in Mirror(reflecting: before).children {
        if let count = child.value as? Int { more = count }
        if let ids = child.value as? Set<String> { more = ids.count }
    }
    return "rows \(before.rows.sorted()), \(more) more"
}

/// A chat that is open and attached, with a turn of generation 1 under way.
func store(_ mode: BusyMode, attached: Bool = true, running: Bool = true) -> AppStore {
    let store = AppStore()
    store.sessions[bot] = session
    store.busyMode = mode
    if attached { store.gateway.attached = [session] }
    if running { store.running = [bot] }
    store.control.fences[session] = ChatControl.Fence(generation: 1, revision: 1)
    store.gateway.answer = { method, _ in
        switch method {
        case "session.steer": return ["status": "queued"]
        case "session.redirect": return ["status": "redirected"]
        default: return ["status": "queued"]
        }
    }
    return store
}

func typed(_ text: String, in store: AppStore) -> Bool {
    store.setDraft(text, for: bot)
    return store.sendDraft(to: bot)
}

func generation(_ call: (method: String, params: JSONValue)) -> Int? { call.params["execution_generation"]?.int }

// ---- R09 -------------------------------------------------------------------------------------
do {
    let s = store(.interrupt)
    s.send("小窗：到家了吗", to: bot)          // as QuickAsk, Shortcuts, 今天's field and a notification's reply call it
    await until { !s.gateway.calls.isEmpty }
    check("R09 打断 chosen, a turn running, said from outside the composer: prompt.submit", s.gateway.methods == ["prompt.submit"])
    check("R09 …and it is not marked as part of the running turn", s.chats[bot]?.last?.midTurn == false)
    let c = store(.interrupt)
    _ = typed("改一下", in: c)
    await until { !c.gateway.calls.isEmpty && c.chats[bot]?.last?.midTurn == true }
    check("R09 the same from the chat's composer: session.redirect, for the run under way",
          c.gateway.methods == ["session.redirect"] && generation(c.gateway.calls[0]) == 1)
    check("R09 …marked as part of that turn", c.chats[bot]?.last?.midTurn == true)
    let st = store(.steer)
    st.send("今天页的话", to: bot)
    await until { !st.gateway.calls.isEmpty }
    check("R09 引导 chosen, said from outside the composer: prompt.submit", st.gateway.methods == ["prompt.submit"])
}

// ---- R07 -------------------------------------------------------------------------------------
do {
    // sent for generation 1 while the chat is not attached (a replay gap: it is being attached
    // again); generation 2 is running by the time it can go
    let s = store(.steer, attached: false)
    _ = typed("别这样", in: s)
    try? await Task.sleep(for: .milliseconds(150))
    check("R07 nothing goes out while the chat is not attached", s.gateway.calls.isEmpty)
    s.control.fences[session]?.generation = 2
    s.gateway.attached = [session]
    await until { !s.gateway.calls.isEmpty }
    check("R07 sent for generation 1, generation 2 running once attached: prompt.submit, no steer",
          s.gateway.methods == ["prompt.submit"])
    // the same wait, and the same turn still running: into it, named as generation 1
    let same = store(.steer, attached: false)
    _ = typed("别这样", in: same)
    try? await Task.sleep(for: .milliseconds(150))
    same.gateway.attached = [session]
    await until { !same.gateway.calls.isEmpty }
    check("R07 the turn it was sent for still runs once attached: session.steer for generation 1",
          same.gateway.methods == ["session.steer"] && generation(same.gateway.calls[0]) == 1)
    // nothing ran when it was sent; a turn runs by the time it can go
    let idle = store(.interrupt, attached: false, running: false)
    _ = typed("新的一句", in: idle)
    try? await Task.sleep(for: .milliseconds(150))
    idle.running = [bot]
    idle.control.fences[session]?.generation = 3
    idle.gateway.attached = [session]
    await until { !idle.gateway.calls.isEmpty }
    check("R07 nothing ran when it was sent, a turn runs once attached: prompt.submit", idle.gateway.methods == ["prompt.submit"])
}

// ---- R06 -------------------------------------------------------------------------------------
do {
    let s = store(.steer)
    s.gateway.answer = { method, params in
        method == "session.steer" ? ["status": "rejected", "text": params["text"] ?? .null, "execution_generation": 1]
            : ["status": "queued"]
    }
    _ = typed("别讲了", in: s)
    let id = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(id) == .declined }
    check("R06 rejected without `delivered`: declined, not 没发出去", s.deliveries.state(id) == .declined)
    check("R06 …and not sent again by itself", s.gateway.methods == ["session.steer"])
    s.resend(id, in: bot)
    await until { s.gateway.calls.count == 2 && s.deliveries.state(id) == nil }
    check("R06 再发一次: a prompt of its own, under the item's id",
          s.gateway.methods == ["session.steer", "prompt.submit"] && s.gateway.calls[1].params["submission_id"]?.string == id)
    check("R06 …after which Hermes has it", s.deliveries.state(id) == nil)

    let late = store(.steer)
    late.gateway.answer = { method, _ in
        method == "session.steer" ? ["status": "rejected", "delivered": false] : ["status": "queued"]
    }
    _ = typed("刚好没赶上", in: late)
    let lateId = late.chats[bot]?.last?.id ?? ""
    await until { late.gateway.calls.count == 2 && late.deliveries.state(lateId) == nil }
    check("R06 rejected with delivered false: sent as a prompt by itself, as before",
          late.gateway.methods == ["session.steer", "prompt.submit"] && late.deliveries.state(lateId) == nil)

    let stale = store(.interrupt)
    stale.gateway.answer = { method, _ in
        if method == "session.redirect" { throw GatewayError.rpc(code: 4001, message: "stale_generation", reason: "stale_generation") }
        return ["status": "queued"]
    }
    _ = typed("那一轮已经过去了", in: stale)
    await until { stale.gateway.calls.count == 2 }
    check("R06 refused outright (a stale run): sent as a prompt by itself, as before",
          stale.gateway.methods == ["session.redirect", "prompt.submit"])
}

// ---- R08 -------------------------------------------------------------------------------------
let then = Date().addingTimeInterval(-20)

func row(_ id: Int, _ text: String, steer: Bool = false) -> JSONValue {
    var row: [String: JSONValue] = ["row_id": .number(Double(id)), "role": "user", "text": .string(text),
                                    "timestamp": .number(Date().timeIntervalSince1970)]
    if steer { row["display_kind"] = "steer" }
    return .object(row)
}

/// 「继续」 said 20 s ago and stored as row 1; said again into the turn as the connection goes.
func droppedCorrection(_ mode: BusyMode, earlier: ChatItem) async -> (AppStore, String) {
    let s = store(mode)
    s.chats[bot] = [earlier]
    s.gateway.answer = { method, _ in
        if method == "session.steer" || method == "session.redirect" { throw GatewayError.offline }
        return ["status": "queued"]
    }
    _ = typed("继续", in: s)
    let id = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(id) == .unconfirmed }
    return (s, id)
}

func page(_ rows: [JSONValue], for s: AppStore) {
    s.gateway.answer = { method, _ in
        guard method == "session.transcript" else { return ["status": "queued"] }
        return ["rows": .array(rows)]
    }
}

do {
    let earlier = ChatItem(id: "row-1", role: .user, at: then, text: "继续")
    var (s, id) = await droppedCorrection(.steer, earlier: earlier)
    check("R08 the connection went before the answer: unconfirmed", s.deliveries.state(id) == .unconfirmed)
    check("R08 …with the earlier 「继续」 noted as row 1", shape(s.deliveries.sent[id]?.before) == "rows [1], 0 more")
    // it never reached the server: the page has only the earlier one
    page([row(1, "继续")], for: s)
    await s.settleCorrections(bot, session)
    check("R08 lost, and the earlier one within the minute: still unconfirmed", s.deliveries.state(id) == .unconfirmed)
    check("R08 …and still in the chat", s.chats[bot]?.contains { $0.id == id } == true && s.chats[bot]?.count == 2)
    check("R08 …and nothing was sent again", !s.gateway.methods.contains("prompt.submit"))
    // it did reach the server: a row that was not there
    page([row(1, "继续"), row(2, "继续", steer: true)], for: s)
    await s.settleCorrections(bot, session)
    check("R08 arrived: Hermes has it", s.deliveries.state(id) == nil)
    check("R08 …the item stays (the chat was not read again), marked as part of the turn",
          s.chats[bot]?.first { $0.id == id }?.midTurn == true && s.chats[bot]?.count == 2)
    check("R08 …and its row is known", s.control.storedRows[id] == 2)

    // the chat was read again in its place: the page's row is the message
    (s, id) = await droppedCorrection(.steer, earlier: earlier)
    var reread = ChatItem(id: "row-2", role: .user, at: Date(), text: "继续")
    reread.midTurn = true
    s.chats[bot] = [earlier, reread] + (s.chats[bot] ?? []).filter { $0.id == id }
    page([row(1, "继续"), row(2, "继续", steer: true)], for: s)
    await s.settleCorrections(bot, session)
    check("R08 arrived, and the chat read again: the page's row stands for it, once",
          s.deliveries.state(id) == nil && s.chats[bot]?.map(\.id) == ["row-1", "row-2"])

    // 打断 during a model request is stored as an ordinary row of yours, not marked
    (s, id) = await droppedCorrection(.interrupt, earlier: earlier)
    page([row(1, "继续"), row(2, "继续")], for: s)
    await s.settleCorrections(bot, session)
    check("R08 a redirect stored as an ordinary row confirms too", s.deliveries.state(id) == nil)

    // the earlier one was sent from here and its turn has not ended: its row is not known
    let local = ChatItem(id: "8E0B1A9C-0000-4000-8000-000000000001", role: .user, at: then, text: "继续")
    (s, id) = await droppedCorrection(.steer, earlier: local)
    check("R08 an earlier one whose row is not known yet is counted", shape(s.deliveries.sent[id]?.before) == "rows [], 1 more")
    page([row(1, "继续")], for: s)
    await s.settleCorrections(bot, session)
    check("R08 …and its row, stored since, does not confirm the lost one", s.deliveries.state(id) == .unconfirmed)

    // the page cannot be read
    (s, id) = await droppedCorrection(.steer, earlier: earlier)
    s.gateway.answer = { _, _ in throw GatewayError.offline }
    await s.settleCorrections(bot, session)
    check("R08 the page cannot be read: still unconfirmed, still in the chat",
          s.deliveries.state(id) == .unconfirmed && s.chats[bot]?.contains { $0.id == id } == true)
}

// ---- R10 -------------------------------------------------------------------------------------
do {
    let theirs = ChatItem(id: "row-9", role: .assistant, at: then, text: "明天晴，最高 18 度。")
    let quote = "[Replying to your previous message: \"明天晴，最高 18 度。\"]"
    let s = store(.queue, running: false)
    s.reply(to: theirs, in: bot)
    s.media.drafts[bot] = [Draft(kind: .file, name: "a.pdf", ref: "@file:a.pdf")]
    check("R10 a file and a marked message, no words: it goes", s.sendDraft(to: bot))
    await until { !s.gateway.calls.isEmpty }
    check("R10 …with the quote after the file's reference",
          s.gateway.calls.first?.params["text"]?.string == "@file:a.pdf\n\n" + quote)
    check("R10 …the mark is taken off", s.replyTarget(for: bot) == nil)
    let shown = ReplyQuote.split(s.chats[bot]?.last?.text ?? "")
    check("R10 …and the message shows the quote, and no words", shown.quote == "明天晴，最高 18 度。" && shown.words.isEmpty)

    let p = store(.queue, running: false)
    p.reply(to: theirs, in: bot)
    p.media.drafts[bot] = [Draft(kind: .image, name: "p.jpg", mime: "image/jpeg", path: "/srv/p.jpg")]
    _ = p.sendDraft(to: bot)
    await until { !p.gateway.calls.isEmpty }
    check("R10 a picture and a marked message, no words: the quote in place of Hermes's own caption",
          p.gateway.calls.first?.params["text"]?.string == quote && p.gateway.calls.first?.params["attachments"] != nil)

    let none = store(.queue, running: false)
    none.reply(to: theirs, in: bot)
    check("R10 a marked message and nothing to send: it does not go", !none.sendDraft(to: bot))
    try? await Task.sleep(for: .milliseconds(80))
    check("R10 …nothing is sent, and the mark stays", none.gateway.calls.isEmpty && none.replyTarget(for: bot) != nil)

    let plain = store(.queue, running: false)
    plain.media.drafts[bot] = [Draft(kind: .image, name: "p.jpg", mime: "image/jpeg", path: "/srv/p.jpg")]
    _ = plain.sendDraft(to: bot)
    await until { !plain.gateway.calls.isEmpty }
    check("R10 a picture alone, nothing marked: Hermes's own caption, as before",
          plain.gateway.calls.first?.params["text"]?.string == SentNotes.defaultCaption)

    let words = store(.queue, running: false)
    words.reply(to: theirs, in: bot)
    _ = typed("那周末呢", in: words)
    await until { !words.gateway.calls.isEmpty }
    check("R10 words and a marked message: as before", words.gateway.calls.first?.params["text"]?.string == quote + "\n\n那周末呢")
}

// ---- the second review: RR04, RR05 ---------------------------------------------------------------
// The production rejoin, with what it calls (keepReply, loadLatestPage, reconcile,
// settleCorrections), against a server these checks script.

/// A server as a check scripts it: the newest page of its transcript, whether a turn runs, and
/// what becomes of a message put into the turn or submitted.
final class Server {
    var rows: [JSONValue] = []
    var running = true
    var correction: () throws -> JSONValue = { throw GatewayError.offline }
    var prompt: () throws -> JSONValue = { ["status": "queued"] }
    /// What a rewind (session.mutate) answers, by the row it names: a receipt, or a refusal's error object
    var rewinds: [Int: JSONValue] = [:]

    init(for s: AppStore) {
        s.gateway.answer = { [unowned self] method, params in
            switch method {
            case "session.transcript": return ["rows": .array(self.rows)]
            case "session.resume":
                return ["session_id": .string(session), "running": .bool(self.running), "messages_omitted": .bool(true)]
            case "session.steer", "session.redirect": return try self.correction()
            case "prompt.submit": return try self.prompt()
            case "session.mutate":
                return self.rewinds[params["payload"]?["target_message_id"]?.int ?? 0]
                    ?? ["error": ["code": 4001, "message": "not scripted"]]
            default: return [:]
            }
        }
    }
}

func theirRow(_ id: Int, _ text: String) -> JSONValue {
    .object(["row_id": .number(Double(id)), "role": "assistant", "text": .string(text),
             "timestamp": .number(Date().timeIntervalSince1970)])
}

/// A row of yours stored ten minutes ago; with `submission`, as Hermes itself keeps a prompt's id on its row.
func oldRow(_ id: Int, _ text: String) -> JSONValue {
    .object(["row_id": .number(Double(id)), "role": "user", "text": .string(text),
             "timestamp": .number(Date().timeIntervalSince1970 - 600)])
}

func namedRow(_ id: Int, _ text: String, submission: String) -> JSONValue {
    .object(["row_id": .number(Double(id)), "role": "user", "text": .string(text),
             "timestamp": .number(Date().timeIntervalSince1970),
             "display_metadata": .object(["submission_id": .string(submission), "gateway_input_owner": "x"])])
}

/// The connection is back on a new socket: the chat is attached again, with the frames it missed
/// replayed or (they cannot be had) its newest page read instead.
func comeBack(_ s: AppStore, replayed: Bool) async {
    s.gateway.replays = replayed
    s.gateway.attached = []
    await s.rejoin(bot, session)
}

func ids(_ s: AppStore) -> [String] { (s.chats[bot] ?? []).map(\.id) }

// RR04: the same words put into a turn twice as the connection goes; Hermes has one of them
for replayed in [true, false] {
    let path = replayed ? "frames replayed" : "newest page read"
    let s = store(.steer)
    s.loadedChats = [bot]
    let server = Server(for: s)
    s.chats[bot] = [ChatItem(id: "reply", role: .assistant, at: then, text: "从前有座山", streaming: true)]
    s.streaming[bot] = "reply"
    _ = typed("讲短一点", in: s)
    let a = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(a) == .unconfirmed }
    _ = typed("讲短一点", in: s)
    let b = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(b) == .unconfirmed }
    check("RR04 (\(path)) two in the same words, both in doubt", a != b && s.deliveries.state(a) == .unconfirmed && s.deliveries.state(b) == .unconfirmed)
    server.rows = [row(501, "讲短一点", steer: true)]
    await comeBack(s, replayed: replayed)
    check("RR04 (\(path)) first look: the one row confirms the older, the other stays in doubt",
          s.deliveries.state(a) == nil && s.deliveries.state(b) == .unconfirmed)
    check("RR04 (\(path)) …and stays in the chat, once: \(ids(s))", ids(s).filter { $0 == b }.count == 1)
    for look in 2...3 {
        await comeBack(s, replayed: replayed)
        check("RR04 (\(path)) look \(look): the same row does not confirm the other", s.deliveries.state(b) == .unconfirmed)
        check("RR04 (\(path)) look \(look): …which is still in the chat, once: \(ids(s))", ids(s).filter { $0 == b }.count == 1)
    }
    check("RR04 (\(path)) the confirmed one shows once: \(ids(s))",
          ids(s).filter { $0 == a || $0 == "row-501" }.count == 1)
    // a second row in those words: the other got there too
    server.rows.append(row(502, "讲短一点", steer: true))
    await comeBack(s, replayed: replayed)
    check("RR04 (\(path)) a second row confirms the second message", s.deliveries.state(b) == nil)
    check("RR04 (\(path)) …each shown once: \(ids(s))",
          ids(s).filter { $0 == a || $0 == "row-501" }.count == 1 && ids(s).filter { $0 == b || $0 == "row-502" }.count == 1)
}

// RR04 control, within one look: two rows confirm two, one row confirms one
do {
    let s = store(.steer)
    let server = Server(for: s)
    _ = typed("再短一点", in: s)
    let a = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(a) == .unconfirmed }
    _ = typed("再短一点", in: s)
    let b = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(b) == .unconfirmed }
    server.rows = [row(601, "再短一点", steer: true), row(602, "再短一点", steer: true)]
    await comeBack(s, replayed: true)
    check("RR04 control: two real rows confirm two messages in one look", s.deliveries.state(a) == nil && s.deliveries.state(b) == nil)
}

// RR05: 「继续」 is in the history; said again into the running turn while the chat is being attached again
do {
    let s = store(.steer)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.rows = [oldRow(701, "继续"), theirRow(702, "好，接着讲。"), oldRow(703, "讲个长故事")]
    s.chats[bot] = s.transcriptItems(["rows": .array(server.rows)])
        + [ChatItem(id: "reply", role: .assistant, at: then, text: "从前有座山", streaming: true)]
    s.streaming[bot] = "reply"
    // the session's frames stopped coming on this socket: it is not attached, and is being attached again
    s.gateway.attached = []
    _ = typed("继续", in: s)
    let c = s.chats[bot]?.last?.id ?? ""
    s.gateway.replays = false
    await s.rejoin(bot, session)
    check("RR05 the page read in the chat's place leaves the message just said: \(ids(s))", ids(s).contains(c))
    check("RR05 …and nothing has gone out yet", !s.gateway.methods.contains("session.steer") && !s.gateway.methods.contains("prompt.submit"))
    await until { s.deliveries.state(c) == .unconfirmed }
    check("RR05 it goes into the turn it was said for, and the connection takes the answer: in doubt",
          s.gateway.methods.contains("session.steer") && s.deliveries.state(c) == .unconfirmed)
    check("RR05 what read the same when it was said is on its record: \(shape(s.deliveries.sent[c]?.before))",
          shape(s.deliveries.sent[c]?.before) == "rows [701], 0 more")
    for look in 1...2 {
        await comeBack(s, replayed: false)
        check("RR05 look \(look): the old 「继续」 is not taken for it: still in doubt", s.deliveries.state(c) == .unconfirmed)
        check("RR05 look \(look): …and still in the chat, once: \(ids(s))", ids(s).filter { $0 == c }.count == 1)
    }
    await comeBack(s, replayed: true)
    check("RR05 nor with the frames replayed", s.deliveries.state(c) == .unconfirmed && ids(s).filter { $0 == c }.count == 1)
    // it did get there: a row that was not there when it was said
    server.rows.append(row(704, "继续", steer: true))
    await comeBack(s, replayed: false)
    check("RR05 its own row confirms it, and stands for it: \(ids(s))",
          s.deliveries.state(c) == nil && ids(s).contains("row-704") && !ids(s).contains(c))
}

// RR05, a prompt: the same words said twice while the chat is being attached again; the page has an old row in them
do {
    let s = store(.queue, attached: false, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.running = false
    server.rows = [oldRow(10, "好的"), theirRow(11, "那就这么定了。")]
    s.chats[bot] = s.transcriptItems(["rows": .array(server.rows)])
    _ = typed("好的", in: s)
    let first = s.chats[bot]?.last?.id ?? ""
    _ = typed("好的", in: s)
    let second = s.chats[bot]?.last?.id ?? ""
    s.gateway.replays = false
    await s.rejoin(bot, session)
    check("RR05 two prompts just said, an old row in their words on the page: both stay: \(ids(s))",
          ids(s) == ["row-10", "row-11", first, second])
    await until { s.gateway.methods.filter { $0 == "prompt.submit" }.count == 2 }
    check("RR05 …and both go out once the chat is attached", s.gateway.methods.filter { $0 == "prompt.submit" }.count == 2)
}

// a receipt lost, and the page has the message's row
for named in [true, false] {
    let how = named ? "a row that names the submission" : "a row in its words that was not there before"
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.running = false
    server.prompt = { throw GatewayError.offline }
    server.rows = [oldRow(10, "好的"), theirRow(11, "那就这么定了。")]
    s.chats[bot] = s.transcriptItems(["rows": .array(server.rows)])
    _ = typed("好的", in: s)
    let id = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(id) == .unsure }
    server.rows += [named ? namedRow(12, "好的", submission: id) : row(12, "好的"), theirRow(13, "嗯。")]
    await comeBack(s, replayed: false)
    check("control (\(how)): the page's row stands for the message, once: \(ids(s))",
          ids(s) == ["row-10", "row-11", "row-12", "row-13"])
    check("control (\(how)): …and Hermes has it", s.deliveries.state(id) == nil)
}

// a receipt lost, and the page has a row that names the submission in other words than the bubble's
// (as Hermes stored it): only the id can say it is the same message
do {
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.running = false
    server.prompt = { throw GatewayError.offline }
    server.rows = [oldRow(10, "好的"), theirRow(11, "那就这么定了。")]
    s.chats[bot] = s.transcriptItems(["rows": .array(server.rows)])
    _ = typed("看这张图", in: s)
    let id = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(id) == .unsure }
    server.rows += [namedRow(12, "看这张图\n\n[image: a.png]", submission: id), theirRow(13, "看到了。")]
    await comeBack(s, replayed: false)
    check("a row that names the submission is the message, whatever its words: \(ids(s))",
          ids(s) == ["row-10", "row-11", "row-12", "row-13"] && s.deliveries.state(id) == nil)
}

// a receipt lost, the message never got there, and an old row reads the same
do {
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.running = false
    server.prompt = { throw GatewayError.offline }
    server.rows = [oldRow(10, "好的"), theirRow(11, "那就这么定了。")]
    s.chats[bot] = s.transcriptItems(["rows": .array(server.rows)])
    _ = typed("好的", in: s)
    let id = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(id) == .unsure }
    await comeBack(s, replayed: false)
    check("control: lost, an old row in its words: 没发出去, under the page: \(ids(s))",
          s.deliveries.state(id) == .unsent(nil) && ids(s) == ["row-10", "row-11", id])
}

// a receipt lost, the message never got there, and a row in its words stored a moment ago names
// another submission (the same words said from another window): that row is that message's
do {
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.running = false
    server.prompt = { throw GatewayError.offline }
    server.rows = [oldRow(10, "嗯"), theirRow(11, "那就这么定了。")]
    s.chats[bot] = s.transcriptItems(["rows": .array(server.rows)])
    _ = typed("好的", in: s)
    let id = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(id) == .unsure }
    server.rows += [namedRow(12, "好的", submission: "SOMEONE-ELSES"), theirRow(13, "嗯。")]
    await comeBack(s, replayed: false)
    check("a row that names another submission does not pass for a message in its words: \(ids(s)) \(String(describing: s.deliveries.state(id)))",
          s.deliveries.state(id) == .unsent(nil) && ids(s) == ["row-10", "row-11", "row-12", "row-13", id])
}

// a message Hermes refused, with 重发 under it, when the page is read in the chat's place later
do {
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.running = false
    server.prompt = { throw GatewayError.rpc(code: 4001, message: "queue_full", reason: "queue_full") }
    server.rows = [oldRow(10, "好的"), theirRow(11, "那就这么定了。")]
    s.chats[bot] = s.transcriptItems(["rows": .array(server.rows)])
    _ = typed("再说一件事", in: s)
    let id = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(id) == .unsent("排队的消息太多了") }
    await comeBack(s, replayed: false)
    check("a message that did not go out keeps its bubble when the page is read in the chat's place: \(ids(s))",
          ids(s) == ["row-10", "row-11", id] && s.deliveries.state(id) == .unsent("排队的消息太多了"))
}

// a turn that ended between the attach and the page: the page's copy, once
do {
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.running = false
    _ = typed("讲个故事", in: s)
    let id = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(id) == nil && s.gateway.methods.contains("prompt.submit") }
    s.chats[bot]?.append(ChatItem(id: "live-reply", role: .assistant, at: Date(), text: "从前有座山。"))
    // as on an attach: what is held stays up until the page replaces it, and these came after the mark
    s.attachMarks[bot] = 0
    server.rows = [row(20, "讲个故事"), theirRow(21, "从前有座山。")]
    try? await s.loadLatestPage(bot)
    check("control: a turn that ended meanwhile is the page's, once: \(ids(s))", ids(s) == ["row-20", "row-21"])
}

// ---- the boundary names its messages -------------------------------------------------------------
// A message put into a turn as the connection goes has only the transcript to say it got there:
// a row of yours in its words that is no other message's. The other messages in those words are
// asked what became of them when the transcript is looked at.

/// The turn's end names a prompt's row (AppStore.noteFences, on `message.complete`).
func turnEnded(_ id: String, row: Int, in s: AppStore) { s.control.storedRows[id] = row }

/// 「继续」 said as a prompt (behind the turn), then again into the turn at once, before anything
/// of the first is known: the first is on its way when the second is said. Hermes's answer to the
/// prompt is `prompt`; the one put into the turn loses its answer with the connection.
func promptThenCorrection(_ prompt: @escaping () throws -> JSONValue) async -> (AppStore, Server, String, String) {
    let s = store(.queue)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.prompt = prompt
    s.chats[bot] = [ChatItem(id: "reply", role: .assistant, at: then, text: "从前有座山", streaming: true)]
    s.streaming[bot] = "reply"
    _ = typed("继续", in: s)
    let first = s.chats[bot]?.last?.id ?? ""
    s.busyMode = .steer
    _ = typed("继续", in: s)
    let second = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(second) == .unconfirmed && s.deliveries.state(first) != .sending }
    return (s, server, first, second)
}

// the one before it is refused: it is on no row, and the row in those words is the second's
for replayed in [true, false] {
    let path = replayed ? "frames replayed" : "newest page read"
    let (s, server, first, second) = await promptThenCorrection { throw GatewayError.rpc(code: 4001, message: "queue_full", reason: "queue_full") }
    check("names (\(path)) the first was on its way when the second was said: \(shape(s.deliveries.sent[second]?.before))",
          shape(s.deliveries.sent[second]?.before) == "rows [], 1 more")
    check("names (\(path)) Hermes refused the first: 没发出去", s.deliveries.state(first) == .unsent("排队的消息太多了"))
    await comeBack(s, replayed: replayed)
    check("names (\(path)) no row in those words: the second stays in doubt", s.deliveries.state(second) == .unconfirmed)
    server.rows = [row(801, "继续", steer: true)]
    await comeBack(s, replayed: replayed)
    check("names (\(path)) a row in those words, and the first refused: it is the second's", s.deliveries.state(second) == nil)
    check("names (\(path)) …the refused one still says so, under what Hermes has: \(ids(s))",
          s.deliveries.state(first) == .unsent("排队的消息太多了") && ids(s).contains(first))
}

// the one before it got there: its row is its own, whenever it becomes known, and never the second's
for replayed in [true, false] {
    let path = replayed ? "frames replayed" : "newest page read"
    let (s, server, first, second) = await promptThenCorrection { ["status": "queued"] }
    check("names (\(path)) Hermes has the first", s.deliveries.state(first) == nil)
    server.rows = [row(811, "继续")]
    await comeBack(s, replayed: replayed)
    check("names (\(path)) one row, the first's (not known as its yet): the second stays in doubt", s.deliveries.state(second) == .unconfirmed)
    turnEnded(first, row: 811, in: s)
    await comeBack(s, replayed: replayed)
    check("names (\(path)) the first's row is known: still not the second's", s.deliveries.state(second) == .unconfirmed)
    server.rows.append(row(812, "继续", steer: true))
    await comeBack(s, replayed: replayed)
    check("names (\(path)) a second row: the second got there, as that row",
          s.deliveries.state(second) == nil && s.control.storedRows[second] == 812)
}

// the first is known as its row before the second's page is ever read, and its row is no longer on the page
do {
    let (s, server, first, second) = await promptThenCorrection { ["status": "queued"] }
    turnEnded(first, row: 811, in: s)
    server.rows = [row(812, "继续", steer: true)]
    await comeBack(s, replayed: true)
    check("names: the first's row known and off the page, one row in those words: it is the second's (\(first.prefix(4)))",
          s.deliveries.state(second) == nil && s.control.storedRows[second] == 812)
}

// the one before it was put into a turn that did not take it: no row is its
do {
    let s = store(.steer)
    s.loadedChats = [bot]
    let server = Server(for: s)
    var asked = 0
    server.correction = {
        asked += 1
        if asked == 1 { return ["status": "rejected", "execution_generation": 1] }
        throw GatewayError.offline
    }
    s.chats[bot] = [ChatItem(id: "reply", role: .assistant, at: then, text: "从前有座山", streaming: true)]
    s.streaming[bot] = "reply"
    _ = typed("讲短一点", in: s)
    let first = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(first) == .declined }
    _ = typed("讲短一点", in: s)
    let second = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(second) == .unconfirmed }
    server.rows = [row(821, "讲短一点", steer: true)]
    await comeBack(s, replayed: true)
    check("names: the one before it was not taken by its turn: the row in those words is the second's",
          s.deliveries.state(second) == nil && s.deliveries.state(first) == .declined)
}

// said again after it, while it is in doubt: the later one's row is not its
for replayed in [true, false] {
    let path = replayed ? "frames replayed" : "newest page read"
    let s = store(.steer)
    s.loadedChats = [bot]
    let server = Server(for: s)
    s.chats[bot] = [ChatItem(id: "reply", role: .assistant, at: then, text: "从前有座山", streaming: true)]
    s.streaming[bot] = "reply"
    _ = typed("继续", in: s)
    let lost = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(lost) == .unconfirmed }
    await comeBack(s, replayed: replayed)
    check("later (\(path)) put into the turn and lost: in doubt", s.deliveries.state(lost) == .unconfirmed)
    // said again, as a message of its own: Hermes has it, and stores it
    s.busyMode = .queue
    _ = typed("继续", in: s)
    let again = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(again) == nil && s.gateway.methods.contains("prompt.submit") }
    server.rows = [row(831, "继续")]
    await comeBack(s, replayed: replayed)
    check("later (\(path)) the same words said again and stored: that row is not the lost one's", s.deliveries.state(lost) == .unconfirmed)
    check("later (\(path)) …which is still in the chat, once: \(ids(s))", ids(s).filter { $0 == lost }.count == 1)
    turnEnded(again, row: 831, in: s)
    await comeBack(s, replayed: replayed)
    check("later (\(path)) nor once that row is known as the later one's", s.deliveries.state(lost) == .unconfirmed)
}

// said again after it, and both got there: the older row is the one in doubt's
do {
    let s = store(.steer)
    s.loadedChats = [bot]
    let server = Server(for: s)
    s.chats[bot] = [ChatItem(id: "reply", role: .assistant, at: then, text: "从前有座山", streaming: true)]
    s.streaming[bot] = "reply"
    _ = typed("继续", in: s)
    let first = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(first) == .unconfirmed }
    s.busyMode = .queue
    _ = typed("继续", in: s)
    let again = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(again) == nil && s.gateway.methods.contains("prompt.submit") }
    server.rows = [row(841, "继续", steer: true), row(842, "继续")]
    await comeBack(s, replayed: true)
    check("later: two rows, one for the message said after it: the older row confirms the one in doubt",
          s.deliveries.state(first) == nil && s.control.storedRows[first] == 841)
}

// said again after it, and refused: it is on no row, so a row in those words is the one in doubt's
do {
    let s = store(.steer)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.prompt = { throw GatewayError.rpc(code: 4001, message: "queue_full", reason: "queue_full") }
    s.chats[bot] = [ChatItem(id: "reply", role: .assistant, at: then, text: "从前有座山", streaming: true)]
    s.streaming[bot] = "reply"
    _ = typed("继续", in: s)
    let first = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(first) == .unconfirmed }
    s.busyMode = .queue
    _ = typed("继续", in: s)
    let again = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(again) == .unsent("排队的消息太多了") }
    server.rows = [row(851, "继续", steer: true)]
    await comeBack(s, replayed: true)
    check("later: the one said after it was refused: the row in those words confirms the one in doubt", s.deliveries.state(first) == nil)
}

// ---- the third review: R3-02 --------------------------------------------------------------------
// A prompt Hermes admitted (its receipt came, so nothing follows it any more) whose turn's end was
// missed, the frames not to be had: only the page says which row it is, by the submission id
// Hermes keeps on that row. A message put into a turn in the same words, its answer lost with the
// connection, is told apart from it by that row, and the prompt is not also counted as a message
// whose row nobody can name.

/// 「继续」 as a prompt, admitted, and 「继续」 put into a running turn, its answer lost. Said first,
/// the prompt starts the turn the other is put into; said after, it waits behind that turn. Both
/// turns end while away, and neither end is seen.
func admittedAndLost(promptFirst: Bool) async -> (AppStore, Server, String, String) {
    let s = store(.queue, running: !promptFirst)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.running = false
    func prompt() async -> String {
        s.busyMode = .queue
        _ = typed("继续", in: s)
        let id = s.chats[bot]?.last?.id ?? ""
        await until { s.deliveries.state(id) == nil && s.gateway.methods.contains("prompt.submit") }
        return id
    }
    func correction() async -> String {
        s.busyMode = .steer
        _ = typed("继续", in: s)
        let id = s.chats[bot]?.last?.id ?? ""
        await until { s.deliveries.state(id) == .unconfirmed }
        return id
    }
    guard promptFirst else {
        let correction = await correction()
        return (s, server, await prompt(), correction)
    }
    let prompt = await prompt()
    // its turn starts, the session's second run: what is put into a turn now goes into this one
    s.running = [bot]
    s.control.fences[session]?.generation = 2
    return (s, server, prompt, await correction())
}

/// The chat's messages of yours, by their items' ids.
func yours(_ s: AppStore) -> [String] { (s.chats[bot] ?? []).filter { $0.role == .user }.map(\.id) }

// both got there: the page has the prompt's row, which names it, and the other's own row
for promptFirst in [true, false] {
    let order = promptFirst ? "the prompt said first" : "the prompt said after"
    let (s, server, prompt, correction) = await admittedAndLost(promptFirst: promptFirst)
    check("R3-02 (\(order)) Hermes has the prompt, the one put into the turn is in doubt",
          s.deliveries.state(prompt) == nil && s.deliveries.state(correction) == .unconfirmed)
    let (named, own) = promptFirst ? (901, 902) : (903, 901)
    server.rows = promptFirst
        ? [namedRow(901, "继续", submission: prompt), row(902, "继续", steer: true), theirRow(903, "好，接着讲。")]
        : [row(901, "继续", steer: true), theirRow(902, "从前有座山。"), namedRow(903, "继续", submission: prompt),
           theirRow(904, "好，接着讲。")]
    for look in 1...3 {
        await comeBack(s, replayed: false)
        check("R3-02 (\(order)) look \(look): the one put into the turn got there, as its own row, not the prompt's",
              s.deliveries.state(correction) == nil && s.control.storedRows[correction] == own
                && s.control.confirmedRows[session]?.count == 1)
        check("R3-02 (\(order)) look \(look): two messages, two bubbles, both the page's: \(yours(s))",
              yours(s) == ["row-\(min(named, own))", "row-\(max(named, own))"])
    }
}

// the frames replayed and the prompt's turn still under way, so no end has named its row: the page
// is read only for the one put into the turn (settleCorrections), and names the prompt's row there too
do {
    let (s, server, prompt, correction) = await admittedAndLost(promptFirst: true)
    server.running = true
    server.rows = [namedRow(901, "继续", submission: prompt), row(902, "继续", steer: true)]
    await comeBack(s, replayed: true)
    check("R3-02 (frames replayed, the prompt's turn running) the one put into it got there, as its own row: \(ids(s))",
          s.deliveries.state(correction) == nil && s.control.storedRows[correction] == 902
            && ids(s) == [prompt, correction] && s.chats[bot]?.last?.midTurn == true)
}

// the one put into the turn did not get there: the prompt's row, which reads the same, is not it
for promptFirst in [true, false] {
    let order = promptFirst ? "the prompt said first" : "the prompt said after"
    let (s, server, prompt, correction) = await admittedAndLost(promptFirst: promptFirst)
    server.rows = promptFirst
        ? [namedRow(901, "继续", submission: prompt), theirRow(903, "好，接着讲。")]
        : [theirRow(902, "从前有座山。"), namedRow(903, "继续", submission: prompt), theirRow(904, "好，接着讲。")]
    for look in 1...2 {
        await comeBack(s, replayed: false)
        check("R3-02 (\(order)) lost, look \(look): the prompt's row does not confirm it: in doubt, under the page, once: \(yours(s))",
              s.deliveries.state(correction) == .unconfirmed && s.control.storedRows[correction] == nil
                && yours(s) == ["row-\(promptFirst ? 901 : 903)", correction])
    }
}

// a row that names a submission nothing here follows (the same words, said as a prompt from another
// window) is that prompt's: it does not confirm a message put into a turn in its words either
for replayed in [true, false] {
    let path = replayed ? "frames replayed" : "newest page read"
    let s = store(.steer)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.running = false
    _ = typed("继续", in: s)
    let correction = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(correction) == .unconfirmed }
    server.rows = [namedRow(901, "继续", submission: "SOMEONE-ELSES"), theirRow(902, "好，接着讲。")]
    for look in 1...2 {
        await comeBack(s, replayed: replayed)
        check("R3-02 (\(path)) look \(look): another submission's row does not confirm one put into a turn in its words: \(ids(s))",
              s.deliveries.state(correction) == .unconfirmed && ids(s).filter { $0 == correction }.count == 1)
    }
}

// two put into the prompt's turn in its words and one row of theirs: it confirms one of them, the older
do {
    let (s, server, prompt, first) = await admittedAndLost(promptFirst: true)
    _ = typed("继续", in: s)
    let second = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(second) == .unconfirmed }
    server.rows = [namedRow(901, "继续", submission: prompt), row(902, "继续", steer: true), theirRow(903, "好，接着讲。")]
    for look in 1...2 {
        await comeBack(s, replayed: false)
        check("R3-02 two put into the turn, one row, look \(look): the older got there as that row, the other is in doubt: \(yours(s))",
              s.deliveries.state(first) == nil && s.control.storedRows[first] == 902
                && s.deliveries.state(second) == .unconfirmed && yours(s) == ["row-901", "row-902", second])
    }
}

// ---- the fourth review: R4-01 -------------------------------------------------------------------
// A compaction stores the messages it keeps again, as new rows: in place (archive_and_compact) or
// in a new session (publish_compression_child), each copy with all of its original but the number.
// The pages here are Hermes's own (compaction.json: ../../real, stage compact), the newest page
// before and after each of two compactions, on each path. The first time, the 「继续」 put into the
// turn as row 8 is row 16 after it, at the same time and in the same words; a message the
// compaction summarized keeps its number (row 5). The second time, the prompt 「继续」 (row 18) is
// row 27, still naming its submission, and the 「继续」 put into the next turn (row 23) is row 32,
// while the first one, summarized now, stays row 16. Whatever its number, a row that was another
// message's is not the one that says a message put into a turn got there.

let compaction = try JSONValue.parse(String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))

/// The rows of the newest page Hermes gave (`before`, `after`, `before2`, `after2`) on a path
/// (`in place`, `rotation`), oldest first.
func captured(_ path: String, _ page: String) -> [JSONValue] { compaction[path]?[page]?["rows"]?.array ?? [] }

/// The rows before the one numbered `number`: the transcript as it was when that row's message was said.
func rows(_ rows: [JSONValue], before number: Int) -> [JSONValue] { Array(rows.prefix { $0["row_id"]?.int != number }) }

/// The row numbered `number` on a page.
func numbered(_ number: Int, in rows: [JSONValue]) -> JSONValue? { rows.first { $0["row_id"]?.int == number } }

/// 詩音's chat read from `rows`, with a turn under way (generation 1) to put things into, and the
/// server giving those rows until it is told otherwise.
func readChat(_ rows: [JSONValue]) -> (AppStore, Server) {
    let s = store(.steer)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.rows = rows
    s.chats[bot] = s.transcriptItems(["rows": .array(rows)])
        + [ChatItem(id: "reply", role: .assistant, at: then, text: "从前有座山", streaming: true)]
    s.streaming[bot] = "reply"
    return (s, server)
}

/// Still 不确定有没有送到: its bubble once in the chat, not marked as part of the turn, and no row its.
func inDoubt(_ id: String, in s: AppStore) -> Bool {
    s.deliveries.state(id) == .unconfirmed && ids(s).filter { $0 == id }.count == 1 && s.control.storedRows[id] == nil
        && s.chats[bot]?.first { $0.id == id }?.midTurn == false
}

/// Where a message stands, in words: how it is getting there, the row taken for it, its bubble.
func standing(_ id: String, in s: AppStore) -> String {
    let bubble = s.chats[bot]?.first { $0.id == id }
    return "\(s.deliveries.state(id).map { "\($0)" } ?? "Hermes has it"), row \(s.control.storedRows[id].map { "\($0)" } ?? "none"), "
        + (bubble.map { $0.midTurn ? "its bubble part of the turn" : "its bubble" } ?? "no bubble")
}

let paths = ["in place", "rotation"]

for path in paths {
    let (before, after) = (captured(path, "before"), captured(path, "after"))
    let (old, copy) = (numbered(8, in: before), numbered(16, in: after))
    check("R4-01 (\(path)) Hermes's pages: the 「继续」 put into the turn as row 8 is row 16 once compacted, at the same time, in the same words",
          old?["display_kind"] == "steer" && copy?["display_kind"] == "steer" && old?["timestamp"] == copy?["timestamp"]
            && old?["text"] == copy?["text"] && numbered(8, in: after) == nil)
    check("R4-01 (\(path)) …a message summarized keeps its number, a prompt kept is a new row naming its submission still",
          numbered(5, in: after)?["timestamp"] == numbered(5, in: before)?["timestamp"]
            && numbered(10, in: after)?["display_metadata"]?["submission_id"] == numbered(1, in: before)?["display_metadata"]?["submission_id"]
            && numbered(10, in: after)?["timestamp"] == numbered(1, in: before)?["timestamp"])
    let (before2, after2) = (captured(path, "before2"), captured(path, "after2"))
    check("R4-01 (\(path)) …and the second time: the prompt 「继续」 row 18 is row 27, the next 「继续」 put into a turn row 23 is row 32, the first stays row 16",
          numbered(27, in: after2)?["display_metadata"]?["submission_id"] == numbered(18, in: before2)?["display_metadata"]?["submission_id"]
            && numbered(32, in: after2)?["timestamp"] == numbered(23, in: before2)?["timestamp"]
            && numbered(16, in: after2)?["timestamp"] == numbered(16, in: before2)?["timestamp"])
}

// the review's case: 「继续」 is in the history as row 8, and said again into a running turn, its
// answer lost with the connection, Hermes never having had it. Back before the session is
// compacted, it is in doubt; after, row 16 is the old one, and it is in doubt still
for path in paths {
    for replayed in [true, false] {
        let how = "\(path), \(replayed ? "frames replayed" : "newest page read")"
        let (s, server) = readChat(captured(path, "before"))
        _ = typed("继续", in: s)
        let lost = s.chats[bot]?.last?.id ?? ""
        await until { s.deliveries.state(lost) == .unconfirmed }
        check("R4-01 (\(how)) put into the turn and lost: in doubt, row 8 in its words before it: \(shape(s.deliveries.sent[lost]?.before))",
              s.deliveries.state(lost) == .unconfirmed && shape(s.deliveries.sent[lost]?.before) == "rows [8], 0 more")
        await comeBack(s, replayed: replayed)
        check("R4-01 (\(how)) back, not compacted: in doubt, with its bubble and no row: \(standing(lost, in: s))", inDoubt(lost, in: s))
        server.rows = captured(path, "after")
        for look in 1...2 {
            await comeBack(s, replayed: replayed)
            check("R4-01 (\(how)) compacted, look \(look): row 16 is the old 「继续」, not it: in doubt, with its bubble and no row: \(standing(lost, in: s))",
                  inDoubt(lost, in: s))
        }
    }
}

// a message that got there: said before row 8 was stored, that row is its own, and once compacted,
// row 16 is; said after the first compaction and stored as row 23, row 32 is, the old 「继续」
// (row 16) and the prompt in its words (row 27) not
for path in paths {
    for replayed in [true, false] {
        let how = "\(path), \(replayed ? "frames replayed" : "newest page read")"
        let (s, server) = readChat(rows(captured(path, "before"), before: 8))
        _ = typed("继续", in: s)
        let stored = s.chats[bot]?.last?.id ?? ""
        await until { s.deliveries.state(stored) == .unconfirmed }
        server.rows = captured(path, "after")
        await comeBack(s, replayed: replayed)
        check("R4-01 (\(how)) stored as row 8, and compacted since: row 16 is its own, and says it got there",
              s.deliveries.state(stored) == nil && s.control.storedRows[stored] == 16)
        check("R4-01 (\(how)) …shown once: \(ids(s))",
              replayed ? ids(s).contains(stored) && !ids(s).contains("row-16") : ids(s).contains("row-16") && !ids(s).contains(stored))
        let (later, laterServer) = readChat(rows(captured(path, "before2"), before: 23))
        _ = typed("继续", in: later)
        let again = later.chats[bot]?.last?.id ?? ""
        await until { later.deliveries.state(again) == .unconfirmed }
        check("R4-01 (\(how)) said after the first compaction, rows 16 and 18 in its words before it: \(shape(later.deliveries.sent[again]?.before))",
              shape(later.deliveries.sent[again]?.before) == "rows [16, 18], 0 more")
        laterServer.rows = captured(path, "after2")
        await comeBack(later, replayed: replayed)
        check("R4-01 (\(how)) stored as row 23, and compacted again: row 32 says it got there, not row 16 or the prompt's row 27",
              later.deliveries.state(again) == nil && later.control.storedRows[again] == 32)
    }
}

// the same words put into the turn twice and lost, one of them stored as row 8: it confirms one
// of them. Compacted, it is row 16, and still that message's, not the other's
for path in paths {
    for replayed in [true, false] {
        let how = "\(path), \(replayed ? "frames replayed" : "newest page read")"
        let (s, server) = readChat(rows(captured(path, "before"), before: 8))
        _ = typed("继续", in: s)
        let first = s.chats[bot]?.last?.id ?? ""
        await until { s.deliveries.state(first) == .unconfirmed }
        _ = typed("继续", in: s)
        let second = s.chats[bot]?.last?.id ?? ""
        await until { s.deliveries.state(second) == .unconfirmed }
        server.rows = captured(path, "before")
        await comeBack(s, replayed: replayed)
        check("R4-01 (\(how)) twice, one stored as row 8: it confirms the first, the second is in doubt",
              s.deliveries.state(first) == nil && s.control.storedRows[first] == 8 && inDoubt(second, in: s))
        server.rows = captured(path, "after")
        for look in 1...2 {
            await comeBack(s, replayed: replayed)
            check("R4-01 (\(how)) compacted, look \(look): row 16 is the first's row, not the second's: in doubt still: \(standing(second, in: s))",
                  inDoubt(second, in: s))
            check("R4-01 (\(how)) compacted, look \(look): …and the first shows once: \(ids(s))",
                  ids(s).filter { [first, "row-8", "row-16"].contains($0) }.count == 1)
        }
    }
}

// a prompt whose receipt the connection took is found by the submission its row names, compacted
// or not: 「继续」 said after the first compaction, stored as row 18, which is row 27 once compacted.
// On the newest page read in the chat's place, as when the frames cannot be had (replayed, the
// frames say it was admitted)
for path in paths {
    let (s, server) = readChat(rows(captured(path, "before2"), before: 18))
    s.running = []
    server.running = false
    server.prompt = { throw GatewayError.offline }
    s.busyMode = .queue
    _ = typed("继续", in: s)
    let prompt = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(prompt) == .unsure }
    // the row that names it, as Hermes keeps it: under this message's submission
    server.rows = captured(path, "after2").map { row in
        guard row["row_id"]?.int == 27, case .object(var fields) = row else { return row }
        fields["display_metadata"] = ["submission_id": .string(prompt), "gateway_input_owner": "ci"]
        return .object(fields)
    }
    await comeBack(s, replayed: false)
    check("R4-01 (\(path)) a prompt's receipt lost, and compacted since: row 27 names it, and stands for it, once: \(ids(s))",
          s.deliveries.state(prompt) == nil && s.control.storedRows[prompt] == 27 && ids(s).contains("row-27") && !ids(s).contains(prompt))
}

// ---- 重试 once the session is compacted ---------------------------------------------------------
// 重试 takes the prompt's row and what came after it back (session.mutate rewind), then asks the
// same words again. The pages' fourth round: a turn stopped in its command, its prompt 「慢慢做」
// stored as row 56 (its end says so: `stopped`, its persisted_turn), then the session compacted. The
// compaction kept the prompt as row 66, at the same time, naming its submission still; the newest
// prompt it summarized, 「后台跑一下」 (row 50), is on the page under its own number. Hermes refused a
// rewind to 56 as it refused one to 50 (`rewinds4`), and took the prompt back as row 66.

/// The rows 重试 asked Hermes to take back, in order.
func rewound(_ s: AppStore) -> [Int] {
    s.gateway.calls.filter { $0.method == "session.mutate" }.compactMap { $0.params["payload"]?["target_message_id"]?.int }
}

/// The words that went in as new turns.
func asked(_ s: AppStore) -> [String] {
    s.gateway.calls.filter { $0.method == "prompt.submit" }.compactMap { $0.params["text"]?.string }
}

/// The line a retry that did not go through leaves.
func notRetried(_ s: AppStore) -> String? { s.chats[bot]?.last { $0.text.hasPrefix("没能重试") }?.text }

func retried(_ s: AppStore) -> String {
    "rewound \(rewound(s)), asked \(asked(s)), \(notRetried(s) ?? "nothing said")"
}

/// The servers of the chats below, for as long as the checks run (the gateway answers through them unowned).
var servers: [Server] = []

/// 詩音's chat with the turn stopped: `rows` read from the transcript, then `prompt` (sent from here,
/// nil when it is the last of the rows) and the line the stop left; the server giving the page
/// after the compaction (with `later` after Hermes's rows) and the answers Hermes gave then.
func stoppedChat(_ path: String, rows: [JSONValue], prompt: ChatItem?, later: [JSONValue] = []) -> AppStore {
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    servers.append(server)
    server.running = false
    server.rows = captured(path, "after4") + later
    for name in ["kept", "summarized", "rewound"] {
        if let rewind = compaction[path]?["rewinds4"]?[name], let row = rewind["row"]?.int {
            server.rewinds[row] = rewind["answer"]
        }
    }
    s.chats[bot] = s.transcriptItems(["rows": .array(rows)]) + (prompt.map { [$0] } ?? [])
        + [ChatItem(id: "stopped", role: .system, at: Date(), text: "已停止", stopped: true)]
    return s
}

for path in paths {
    let (before4, after4) = (captured(path, "before4"), captured(path, "after4"))
    let end = compaction[path]?["stopped"]
    let submission = end?["submission_id"]?.string ?? ""
    let answers = compaction[path]?["rewinds4"]
    let refusal = answers?["kept"]?["answer"]?["error"]?["data"]
    check("重试 (\(path)) Hermes's pages: the stopped turn's prompt, row 56 as its end says, is row 66 once compacted, at its time, naming its submission; row 50, summarized, keeps its number",
          end?["user_row_id"]?.int == 56 && numbered(56, in: after4) == nil
            && numbered(66, in: after4)?["display_metadata"]?["submission_id"]?.string == submission
            && numbered(66, in: after4)?["timestamp"] == numbered(56, in: before4)?["timestamp"]
            && numbered(50, in: after4)?["timestamp"] == numbered(50, in: before4)?["timestamp"])
    check("重试 (\(path)) …and Hermes refused a rewind to 56 as one to 50, and took 66 back: \(refusal?["detail"]?.string ?? "no refusal")",
          answers?["kept"]?["row"]?.int == 56 && answers?["summarized"]?["row"]?.int == 50 && answers?["rewound"]?["row"]?.int == 66
            && refusal?["detail"]?.string?.hasPrefix("compacted:") == true && refusal == answers?["summarized"]?["answer"]?["error"]?["data"]
            && answers?["rewound"]?["answer"]?["target_message"]?["id"]?.int == 66)

    // sent from here: its row is the one its turn's end named
    let sent = stoppedChat(path, rows: rows(before4, before: 56), prompt: ChatItem(id: submission, role: .user, at: Date(), text: "慢慢做（探测）"))
    sent.control.storedRows[submission] = 56
    sent.retryReply(bot)
    await until { !asked(sent).isEmpty || notRetried(sent) != nil }
    check("重试 (\(path)) sent from here, row 56 by its turn's end, compacted since: taken back as row 66, which names it, and asked again: \(retried(sent))",
          rewound(sent) == [56, 66] && asked(sent) == ["慢慢做（探测）"] && notRetried(sent) == nil)

    // read from the transcript (the chat read again while the turn ran), the stop's line come live:
    // row 66 by its time and words
    let read = stoppedChat(path, rows: before4, prompt: nil)
    read.retryReply(bot)
    await until { !asked(read).isEmpty || notRetried(read) != nil }
    check("重试 (\(path)) read from the transcript as row 56, compacted since: taken back as row 66, at its time in its words, and asked again: \(retried(read))",
          rewound(read) == [56, 66] && asked(read) == ["慢慢做（探测）"] && notRetried(read) == nil)
    // not by its words alone: a row after it in them (「慢慢做」 put into the turn again) is another message
    let steer: JSONValue = ["row_id": 70, "role": "user", "text": "慢慢做（探测）", "display_kind": "steer",
                            "timestamp": .number((numbered(66, in: after4)?["timestamp"]?.number ?? 0) + 1)]
    let twice = stoppedChat(path, rows: before4, prompt: nil, later: [steer])
    twice.retryReply(bot)
    await until { !asked(twice).isEmpty || notRetried(twice) != nil }
    check("重试 (\(path)) …and a row in its words after it, at another time, is not it: \(retried(twice))",
          rewound(twice) == [56, 66] && asked(twice) == ["慢慢做（探测）"] && notRetried(twice) == nil)

    // the prompt the compaction summarized cannot be taken back, and the chat says so, as before
    let named = numbered(50, in: before4)?["display_metadata"]?["submission_id"]?.string ?? ""
    let gone = stoppedChat(path, rows: rows(before4, before: 50), prompt: ChatItem(id: named, role: .user, at: Date(), text: "后台跑一下（探测）"))
    gone.control.storedRows[named] = 50
    gone.retryReply(bot)
    await until { !asked(gone).isEmpty || notRetried(gone) != nil }
    let goneRead = stoppedChat(path, rows: rows(before4, before: 50) + [numbered(50, in: before4) ?? .null], prompt: nil)
    goneRead.retryReply(bot)
    await until { !asked(goneRead).isEmpty || notRetried(goneRead) != nil }
    check("重试 (\(path)) the prompt summarized, sent from here or read as row 50: not taken back, nothing asked again, the refusal said: \(retried(gone)); \(retried(goneRead))",
          [gone, goneRead].allSatisfy { s in
              rewound(s) == [50] && asked(s).isEmpty && notRetried(s) == "没能重试：这条消息已经压缩进摘要里了"
          })
}

// ---- Hermes compacting the session by itself --------------------------------------------------
// At a turn's start (preflight) and in a turn, after a tool's result, once the context is past
// compression.threshold_tokens (autocompaction.json: ../../real, stage auto, in place and into a new
// session). Its copies keep a message's time and words but not its display_metadata: the prompt
// 「继续（自动）」, row 5 by its turn's end, is a row that names nothing once compacted (row 24 in
// place, 25 in a new session), at its time; the 「继续（自动）」 put into the next turn (row 10) is
// Hermes's wrapper for its words, no longer a steer. The turn under way keeps its prompt's name:
// 第三句, begun as the session was compacted, is stored after it, naming its submission.

let auto = try JSONValue.parse(String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8))

/// The rows of a page the stage auto read (`before`, `after`, `during`, `after2`) on a path.
func autoPage(_ path: String, _ page: String) -> [JSONValue] { auto[path]?[page]?["rows"]?.array ?? [] }

/// The row a turn's end named (persisted_turn.user_row_id) for the turn begun with `words`.
func autoEnd(_ path: String, _ words: String) -> Int? { auto[path]?["ends"]?[words]?["user_row_id"]?.int }

/// The row on `rows` of `role` stored at `row`'s time: its copy, whatever its number and words.
func copy(of row: JSONValue?, in rows: [JSONValue]) -> JSONValue? {
    rows.first { $0["role"] == row?["role"] && $0["timestamp"] == row?["timestamp"] }
}

/// 詩音's chat as it stood when Hermes compacted the session at 第三句's start: the rows before it,
/// 「继续（自动）」 among them the live message it was where `live` (said from here: its row known by
/// number only, from its turn's end), else as read from the transcript (naming nothing where
/// `anonymous`); then 第三句, said from here, its turn under way.
func autoChat(_ path: String, live: Bool, anonymous: Bool = false) -> (AppStore, Server) {
    let rows = autoPage(path, "before").map { row -> JSONValue in
        guard anonymous, row["row_id"]?.int == 5, case .object(var fields) = row else { return row }
        fields["display_metadata"] = nil
        return .object(fields)
    }
    let s = store(.steer)
    s.loadedChats = [bot]
    let server = Server(for: s)
    server.rows = rows
    var items = s.transcriptItems(["rows": .array(rows)])
    if live, let index = items.firstIndex(where: { $0.id == "row-5" }),
       let submission = numbered(5, in: rows)?["display_metadata"]?["submission_id"]?.string {
        items[index] = ChatItem(id: submission, role: .user, at: then, text: "继续（自动）")
        s.control.storedRows[submission] = autoEnd(path, "继续（自动）")
    }
    let third = autoEnd(path, "第三句（自动）").flatMap { numbered($0, in: autoPage(path, "after")) }
    items.append(ChatItem(id: third?["display_metadata"]?["submission_id"]?.string ?? "third", role: .user, at: Date(),
                          text: "第三句（自动）"))
    items.append(ChatItem(id: "reply", role: .assistant, at: Date(), text: "从前有座山", streaming: true))
    s.chats[bot] = items
    s.streaming[bot] = "reply"
    return (s, server)
}

for path in paths {
    let (before, after) = (autoPage(path, "before"), autoPage(path, "after"))
    let continued = numbered(5, in: before), kept = copy(of: numbered(5, in: before), in: after)
    let third = autoEnd(path, "第三句（自动）").flatMap { numbered($0, in: after) }
    check("auto (\(path)) Hermes's pages: 「继续（自动）」 row 5 by its turn's end, named, is row \(kept?["row_id"]?.int ?? 0) once compacted, at its time, naming nothing; 第三句, begun then, names its submission; the steer's copy is Hermes's wrapper",
          autoEnd(path, "继续（自动）") == 5 && continued?["display_metadata"]?["submission_id"]?.string != nil
            && kept?["text"] == "继续（自动）" && kept?["row_id"]?.int != 5 && kept?["display_metadata"] == nil
            && third?["display_metadata"]?["submission_id"]?.string != nil
            && numbered(10, in: before)?["display_kind"] == "steer"
            && copy(of: numbered(10, in: before), in: after)?["text"]?.string?.hasPrefix("[OUT-OF-BAND USER MESSAGE") == true)
    for replayed in [true, false] {
        let how = "\(path), \(replayed ? "frames replayed" : "newest page read")"
        // said from here, its row known by number: the copy names nothing, and was stored long before
        let (s, server) = autoChat(path, live: true)
        _ = typed("继续（自动）", in: s)
        let lost = s.chats[bot]?.last?.id ?? ""
        await until { s.deliveries.state(lost) == .unconfirmed }
        server.rows = after
        await comeBack(s, replayed: replayed)
        check("auto (\(how)) 「继续（自动）」 said from here, put into 第三句's turn and lost: its old prompt's copy, row \(kept?["row_id"]?.int ?? 0), is not it: in doubt, with its bubble and no row: \(standing(lost, in: s))",
              inDoubt(lost, in: s))
        // the same, and it got there: its row is the one stored in 第三句's turn
        let (got, gotServer) = autoChat(path, live: true)
        _ = typed("继续（自动）", in: got)
        let stored = got.chats[bot]?.last?.id ?? ""
        await until { got.deliveries.state(stored) == .unconfirmed }
        let row = (after.compactMap { $0["row_id"]?.int }.max() ?? 0) + 1
        gotServer.rows = after + [.object(["row_id": .number(Double(row)), "role": "user", "text": "继续（自动）",
                                           "display_kind": "steer",
                                           "timestamp": .number((third?["timestamp"]?.number ?? 0) + 1)])]
        await comeBack(got, replayed: replayed)
        check("auto (\(how)) …and when it got there, its own row \(row) says so, not the copy: \(standing(stored, in: got))",
              got.deliveries.state(stored) == nil && got.control.storedRows[stored] == row)
        // read from the transcript before, by its time and words, named or not; and the steer before it
        for anonymous in [false, true] {
            let (r, readServer) = autoChat(path, live: false, anonymous: anonymous)
            _ = typed("继续（自动）", in: r)
            let again = r.chats[bot]?.last?.id ?? ""
            await until { r.deliveries.state(again) == .unconfirmed }
            readServer.rows = after
            await comeBack(r, replayed: replayed)
            check("auto (\(how)) 「继续（自动）」 read from the transcript as row 5\(anonymous ? ", naming nothing" : ""), and the steer row 10 in its words: neither copy is it: \(standing(again, in: r))",
                  inDoubt(again, in: r))
        }
    }
}

#if !BEFORE
/// The row of yours in 「继续」 that Hermes stored `seconds` after `then`, whatever its number.
func continued(_ seconds: Int) -> StoredUserRow.Identity {
    StoredUserRow(text: "继续", at: then.addingTimeInterval(Double(seconds))).identity
}

// what the transcript is looked at with, message by message (AppStore.others)
do {
    let s = store(.steer)
    s.deliveries.track("L", botId: bot, text: "继续", at: Date(),
                       before: DeliveryCheck.Before(rows: [5], identities: [continued(5)], others: ["E"]))
    check("others: one that may be there, as a row nobody can name, counts as one",
          s.others(of: "L", in: bot) == DeliveryCheck.Others(rows: [5], identities: [continued(5)], earlier: 1, later: 0))
    // it never went out: it waits with what is said while not connected
    QuickAsk.shared.putBack([QuickAskWaiting(id: "E", text: "继续", at: Date(), botId: bot)])
    check("others: one that never went out, and waits, counts for nothing",
          s.others(of: "L", in: bot) == DeliveryCheck.Others(rows: [5], identities: [continued(5)], earlier: 0, later: 0))
    QuickAsk.shared.waiting = []
    s.deliveries.track("E", botId: bot, text: "继续", at: Date())
    check("others: on its way counts as one", s.others(of: "L", in: bot).earlier == 1)
    s.deliveries.set("E", .unsure)
    check("others: its receipt lost with the connection counts as one", s.others(of: "L", in: bot).earlier == 1)
    s.deliveries.set("E", .unsent(nil))
    check("others: found not to have got there counts for nothing", s.others(of: "L", in: bot).earlier == 0)
    s.deliveries.set("E", .unconfirmed)
    check("others: in doubt itself is looked for by itself", s.others(of: "L", in: bot).earlier == 0)
    s.deliveries.arrived("E")
    s.control.storedRows["E"] = 9
    check("others: once its row is known it is that row, and counts no more; a row taken is known by its time and words",
          s.others(of: "L", in: bot, taken: [continued(7)])
            == DeliveryCheck.Others(rows: [5, 9], identities: [continued(5), continued(7)], earlier: 0, later: 0))
    // said after it while it is still out
    s.chats[bot] = [ChatItem(id: "L", role: .user, at: Date(), text: "继续"), ChatItem(id: "M", role: .user, at: Date(), text: "继续")]
    s.follow("M", botId: bot, text: "继续", at: Date())
    check("others: a message said after it in its words is known to it", s.deliveries.sent["L"]?.later == ["M"])
    check("others: …and counts as one after it while Hermes may have it", s.others(of: "L", in: bot).later == 1)
    check("others: …while the later one has the earlier among the ones before it: \(shape(s.deliveries.sent["M"]?.before))",
          s.deliveries.sent["M"]?.before?.others == ["L"])
    // sent again, it goes to the bottom and is the newest in its words: nothing is after it
    s.chats[bot] = [ChatItem(id: "M", role: .user, at: Date(), text: "继续"), ChatItem(id: "L", role: .user, at: Date(), text: "继续")]
    s.deliveries.set("L", .unsent(nil))
    s.followAgain("L", in: bot)
    check("others: said again, nothing was said after it, and what is in the chat is before it: \(shape(s.deliveries.sent["L"]?.before))",
          s.deliveries.sent["L"]?.later == [] && s.deliveries.sent["L"]?.before?.others == ["M"]
            && s.deliveries.sent["M"]?.later == ["L"])
}

// the page's own arithmetic (DeliveryCheck.stored)
do {
    func rows(_ ids: [Int]) -> [StoredUserRow] { ids.map { StoredUserRow(text: "继续", at: Date(), row: $0) } }
    func found(_ ids: [Int], _ others: DeliveryCheck.Others) -> Int? { DeliveryCheck.stored("继续", others: others, page: rows(ids))?.row }
    check("stored: a row that is another's is not it", found([1], .init(rows: [1])) == nil)
    // stored eight seconds after `then` as row 8, and as row 16 once the session is compacted
    let copy = [StoredUserRow(text: "继续", at: then.addingTimeInterval(8), row: 16)]
    check("stored: nor under the number a compaction gave it, known by its time and words",
          DeliveryCheck.stored("继续", others: .init(rows: [8], identities: [continued(8)]), page: copy) == nil)
    check("stored: …which its old number alone does not say", DeliveryCheck.stored("继续", others: .init(rows: [8]), page: copy)?.row == 16)
    check("stored: nor the oldest free rows, as many as were said before it and may be there", found([1, 2], .init(earlier: 2)) == nil)
    check("stored: the row after those is it", found([1, 2, 3], .init(earlier: 2)) == 3)
    check("stored: the newest free rows are those said after it", found([1, 2], .init(later: 1)) == 1 && found([1], .init(later: 1)) == nil)
    check("stored: between the ones before and the ones after", found([1, 2, 3], .init(rows: [0], earlier: 1, later: 1)) == 2)
    check("stored: other words are not it", DeliveryCheck.stored("好的", others: .init(), page: rows([1])) == nil)
}
#endif

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
