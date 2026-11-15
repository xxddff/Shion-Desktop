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

// ---- while Hermes compacts the session: 排队 and 引导 only ------------------------------------
// Held open against Hermes itself (../../real, stage held; ../cards), a redirect while a compaction
// runs is answered `rejected` and kept nowhere; a steer is kept for the turn's next step.
do {
    let c = store(.interrupt)
    c.compactingBots = [bot]
    _ = typed("改一下（压缩中）", in: c)
    await until { !c.gateway.calls.isEmpty }
    try? await Task.sleep(for: .milliseconds(100))
    check("compacting. 打断 chosen, Hermes compacting the session: prompt.submit, no session.redirect",
          c.gateway.methods == ["prompt.submit"])
    check("compacting. …not marked as part of the running turn", c.chats[bot]?.last?.midTurn == false)
    check("compacting. …and 打断 stays the way chosen", c.busyMode == .interrupt)
    let st = store(.steer)
    st.compactingBots = [bot]
    _ = typed("讲短一点（压缩中）", in: st)
    await until { st.chats[bot]?.last?.midTurn == true }
    check("compacting. 引导 while it compacts: session.steer, for the run under way",
          st.gateway.methods == ["session.steer"] && generation(st.gateway.calls[0]) == 1)
    let q = store(.queue)
    q.compactingBots = [bot]
    _ = typed("等你做完（压缩中）", in: q)
    await until { !q.gateway.calls.isEmpty }
    check("compacting. 排队 while it compacts: prompt.submit", q.gateway.methods == ["prompt.submit"])
    // said as 打断 before the compaction began, going out once it runs (the chat attached again meanwhile)
    let late = store(.interrupt, attached: false)
    _ = typed("改一下（压缩之前说的）", in: late)
    try? await Task.sleep(for: .milliseconds(150))
    late.compactingBots = [bot]
    late.gateway.attached = [session]
    await until { !late.gateway.calls.isEmpty }
    try? await Task.sleep(for: .milliseconds(100))
    check("compacting. 打断 said before the compaction, going out while it runs: prompt.submit, no session.redirect",
          late.gateway.methods == ["prompt.submit"])
    // the compaction over, 打断 as it always went
    let over = store(.interrupt)
    _ = typed("改一下（压缩之后）", in: over)
    await until { !over.gateway.calls.isEmpty }
    check("compacting. no compaction: 打断 is session.redirect again", over.gateway.methods == ["session.redirect"])
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

// ---- what the checks below share ------------------------------------------------------------
let then = Date().addingTimeInterval(-20)

func row(_ id: Int, _ text: String, steer: Bool = false) -> JSONValue {
    var row: [String: JSONValue] = ["row_id": .number(Double(id)), "role": "user", "text": .string(text),
                                    "timestamp": .number(Date().timeIntervalSince1970)]
    if steer { row["display_kind"] = "steer" }
    return .object(row)
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

// ---- coming back -----------------------------------------------------------------------------
// The production rejoin, with what it calls (keepReply, loadLatestPage, reconcile), against a
// server these checks script.

/// A server as a check scripts it: the newest page of its transcript, whether a turn runs, and
/// what becomes of a message put into the turn or submitted.
final class Server {
    /// The transcript, oldest first, paged as Hermes pages it (`page`)
    var rows: [JSONValue] = []
    /// Hermes's own pages, newest first, served as they came in place of `rows`: the first for a
    /// read without a cursor, then each by the cursor the one before gave
    var pages: [JSONValue] = []
    /// What a transcript read answers, where a check scripts it; else `page`
    var paging: ((JSONValue) -> JSONValue)?
    /// The cursor each transcript read gave (nil: the newest page)
    var cursors: [String?] = []
    var running = true
    var correction: () throws -> JSONValue = { throw GatewayError.offline }
    var prompt: () throws -> JSONValue = { ["status": "queued"] }
    /// What a rewind (session.mutate) answers, by the row it names: a receipt, or a refusal's error object
    var rewinds: [Int: JSONValue] = [:]

    /// A page as Hermes gives one (gateway/session_stored_reads.py, latest order): the newest
    /// `limit` rows, or the `limit` rows above `cursor`, with a cursor for the rows above them
    /// while there are any, `reset` on a read without a cursor. A cursor it did not give starts
    /// over from the newest page, as one of another scope does.
    func page(_ params: JSONValue) -> JSONValue {
        let cursor = params["cursor"]?.string
        if !pages.isEmpty {
            let index = cursor.flatMap { cursor in pages.firstIndex { $0["next_cursor"]?.string == cursor } }.map { $0 + 1 }
            return index.map { $0 < pages.count ? pages[$0] : ["rows": [], "next_cursor": .null, "reset": false] } ?? pages[0]
        }
        let limit = params["limit"]?.int ?? 100
        let given = cursor.flatMap { $0.hasPrefix("c:") ? Int($0.dropFirst(2)) : nil }
        let end = min(given ?? rows.count, rows.count)
        let begin = max(0, end - limit)
        return ["session_id": .string(session), "rows": .array(Array(rows[begin..<end])), "reset": .bool(given == nil),
                "next_cursor": begin > 0 ? .string("c:\(begin)") : .null]
    }

    init(for s: AppStore) {
        s.gateway.answer = { [unowned self] method, params in
            switch method {
            case "session.transcript":
                self.cursors.append(params["cursor"]?.string)
                return self.paging?(params) ?? self.page(params)
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

/// The servers of the chats below, for as long as the checks run (the gateway answers through them unowned).
var servers: [Server] = []

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

// ---- a message put into a running turn whose answer is lost -------------------------------------
// No receipt names a message put into a running turn (session.steer, session.redirect): Hermes's
// answer is all there is. When the connection takes it, the message is marked so for good
// (Delivery.unconfirmed): it may have got there or not, and no row of the transcript is taken for
// it, as Hermes's own desktop client takes none. 再发一次 sends it as a message of its own, behind
// the running turn; if the first got there, it is then said twice, and a page read later shows its
// row as well. Nothing merges, moves or drops either of the two. 不发了 takes it out of the chat,
// nothing sent, and so does 重试 of the turn it was put into.

/// Put into the turn under way (generation 1), and the connection takes the answer: its item's id.
func lostInto(_ s: AppStore, _ words: String) async -> String {
    _ = typed(words, in: s)
    let id = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(id) == .unconfirmed }
    return id
}

/// Marked as having had no answer, with 再发一次, part of the turn it was put into, its bubble once
/// in the chat, and no row taken for it.
func unanswered(_ id: String, in s: AppStore) -> Bool {
    s.deliveries.state(id) == .unconfirmed && s.deliveries.state(id)?.resendable == true
        && ids(s).filter { $0 == id }.count == 1 && s.chats[bot]?.first { $0.id == id }?.midTurn == true
        && s.control.storedRows[id] == nil
}

/// Where a message stands, in words: how it is getting there, the row taken for it, its bubble.
func standing(_ id: String, in s: AppStore) -> String {
    let bubble = s.chats[bot]?.first { $0.id == id }
    return "\(s.deliveries.state(id).map { "\($0)" } ?? "Hermes has it"), row \(s.control.storedRows[id].map { "\($0)" } ?? "none"), "
        + (bubble.map { $0.midTurn ? "its bubble part of the turn" : "its bubble" } ?? "no bubble")
}

/// 詩音's chat read from `rows`, with a turn under way (generation 1) to put things into, and the
/// server giving those rows until it is told otherwise.
func turnChat(_ rows: [JSONValue] = []) -> (AppStore, Server) {
    let s = store(.steer)
    s.loadedChats = [bot]
    let server = Server(for: s)
    servers.append(server)
    server.rows = rows
    s.chats[bot] = s.transcriptItems(["rows": .array(rows)])
        + [ChatItem(id: "reply", role: .assistant, at: then, text: "从前有座山", streaming: true)]
    s.streaming[bot] = "reply"
    return (s, server)
}

/// The chat's items in `words`, by their ids, in order.
func said(_ words: String, in s: AppStore) -> [String] { (s.chats[bot] ?? []).filter { $0.text == words }.map(\.id) }

for mode in [BusyMode.steer, .interrupt] {
    let (s, _) = turnChat([oldRow(1, "继续")])
    s.busyMode = mode
    let id = await lostInto(s, "继续")
    check("lost (\(mode.label)): no answer, the connection gone: marked so, 再发一次 under it, part of the turn, no row its: \(standing(id, in: s))",
          unanswered(id, in: s))
    try? await Task.sleep(for: .milliseconds(100))
    check("lost (\(mode.label)): …and nothing sent again by itself: \(s.gateway.methods)",
          s.gateway.methods == [mode.correction ?? ""])
}

// back, with the frames replayed or with the newest page read in the chat's place: nothing settles
// it. Not the row it was stored as, had it got there; nor an older one in its words
for replayed in [true, false] {
    let how = replayed ? "frames replayed" : "newest page read"
    for (got, rows) in [(false, [oldRow(1, "继续")]), (true, [oldRow(1, "继续"), row(2, "继续", steer: true)])] {
        let (s, server) = turnChat([oldRow(1, "继续")])
        let id = await lostInto(s, "继续")
        server.rows = rows
        for look in 1...2 {
            await comeBack(s, replayed: replayed)
            check("lost (\(how)) \(got ? "and stored after all" : "and never stored"), look \(look): still marked, its bubble once: \(standing(id, in: s))",
                  unanswered(id, in: s))
        }
        let shown = said("继续", in: s)
        check("lost (\(how)) \(got ? "and stored after all" : "and never stored"): what the chat has in its words: \(shown)",
              shown == (replayed ? ["row-1", id] : got ? ["row-1", "row-2", id] : ["row-1", id]))
    }
}

// the same words put into the turn twice as the connection goes, and Hermes stored one of them:
// both stay marked, each once; a page read shows the stored one's row as well
for replayed in [true, false] {
    let how = replayed ? "frames replayed" : "newest page read"
    let (s, server) = turnChat()
    let a = await lostInto(s, "讲短一点")
    let b = await lostInto(s, "讲短一点")
    server.rows = [row(501, "讲短一点", steer: true)]
    for look in 1...2 {
        await comeBack(s, replayed: replayed)
        check("twice (\(how)) look \(look): both still marked, each once: \(standing(a, in: s)); \(standing(b, in: s))",
              a != b && unanswered(a, in: s) && unanswered(b, in: s))
    }
    check("twice (\(how)) …and the row shows once beside them where the page was read: \(said("讲短一点", in: s))",
          said("讲短一点", in: s) == (replayed ? [a, b] : ["row-501", a, b]))
}

// said while the chat is being attached again, 「继续」 in the history: the page read in the chat's
// place leaves the message just said; it goes into the turn it was said for, and the answer is
// lost. Looked at again, and its own row on the page at last: marked still, and both show
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
    check("attaching: the page read in the chat's place leaves the message just said: \(ids(s))", ids(s).contains(c))
    check("attaching: …and nothing has gone out yet", !s.gateway.methods.contains("session.steer") && !s.gateway.methods.contains("prompt.submit"))
    await until { s.deliveries.state(c) == .unconfirmed }
    check("attaching: it goes into the turn it was said for, and the connection takes the answer: marked: \(standing(c, in: s))",
          s.gateway.methods.contains("session.steer") && unanswered(c, in: s))
    for look in 1...2 {
        await comeBack(s, replayed: false)
        check("attaching: look \(look): the old 「继续」 is not taken for it: still marked, its bubble once: \(standing(c, in: s))", unanswered(c, in: s))
    }
    server.rows.append(row(704, "继续", steer: true))
    await comeBack(s, replayed: false)
    check("attaching: its own row at last does not settle it either: both show, once each: \(said("继续", in: s)), \(standing(c, in: s))",
          unanswered(c, in: s) && said("继续", in: s) == ["row-701", "row-704", c])
}

// 再发一次: a message of its own, behind the turn still running, under the item's id; Hermes has
// it once its receipt comes, and it is no longer part of the turn the first was put into
for replayed in [true, false] {
    let how = replayed ? "frames replayed" : "newest page read"
    let (s, server) = turnChat([oldRow(1, "继续")])
    let id = await lostInto(s, "继续")
    await comeBack(s, replayed: replayed)
    s.resend(id, in: bot)
    await until { s.deliveries.state(id) == nil }
    let calls = s.gateway.calls.filter { ["session.steer", "prompt.submit"].contains($0.method) }
    check("再发一次 (\(how)): prompt.submit under the item's id, the turn still running, nothing put into it: \(calls.map(\.method))",
          calls.map(\.method) == ["session.steer", "prompt.submit"] && calls.last?.params["submission_id"]?.string == id
            && calls.last?.params["text"]?.string == "继续" && s.turnRunning(bot))
    check("再发一次 (\(how)): …Hermes has it, at the bottom, a message of its own, and no longer marked: \(standing(id, in: s))",
          s.deliveries.state(id) == nil && ids(s).last == id && s.chats[bot]?.last?.midTurn == false)
    // the first did get there: a page read later shows its row too, beside the one said again
    server.rows = [oldRow(1, "继续"), row(2, "继续", steer: true), namedRow(3, "继续", submission: id)]
    await comeBack(s, replayed: false)
    check("再发一次 (\(how)): …the first stored after all: its row and the one said again both show: \(said("继续", in: s))",
          said("继续", in: s) == ["row-1", "row-2", "row-3"])
}

// where the chat has it: a page read in the chat's place keeps it after what came before it, not
// at the end under the turns that came since
do {
    let (s, server) = turnChat([oldRow(1, "第一句"), theirRow(2, "好。")])
    s.chats[bot]?.insert(ChatItem(id: "P", role: .user, at: then, text: "讲个长故事"), at: 2)
    s.control.storedRows["P"] = 3
    let id = await lostInto(s, "讲短一点")
    server.running = false
    server.rows = [oldRow(1, "第一句"), theirRow(2, "好。"), row(3, "讲个长故事"), theirRow(4, "从前有座山……"),
                   row(5, "再讲一个"), theirRow(6, "好的。")]
    await comeBack(s, replayed: false)
    check("in place: after its turn's prompt, not under the turns that came since: \(ids(s))",
          ids(s) == ["row-1", "row-2", "row-3", id, "row-4", "row-5", "row-6"] && unanswered(id, in: s))
}

// R5-01 of the fifth review: 「继续」 put into run 1 and answered (queued), its row never read;
// then 「继续」 put into run 2 and stored, its answer lost. Nothing says that one got there, and
// nothing takes it away: it is marked, once, the first as it was
for replayed in [true, false] {
    let how = replayed ? "frames replayed" : "newest page read"
    let (s, server) = turnChat()
    s.chats[bot]?.insert(ChatItem(id: "prompt-1", role: .user, at: then, text: "第一轮"), at: 0)
    server.correction = { ["status": "queued"] }
    _ = typed("继续", in: s)
    let first = s.chats[bot]?.last?.id ?? ""
    await until { s.chats[bot]?.last?.midTurn == true && s.deliveries.state(first) == nil }
    s.chats[bot]?.append(ChatItem(id: "prompt-2", role: .user, at: Date(), text: "第二轮"))
    // run 2 begun, as Hermes says of it (its pending: the admission and its run)
    s.noteFences(["type": "session.info", "session_id": .string(session), "execution_generation": 2,
                  "payload": ["pending": [["input_id": "prompt-2", "execution_generation": 2, "status": "started"]]]])
    server.correction = { throw GatewayError.offline }
    let second = await lostInto(s, "继续")
    server.rows = [namedRow(1, "第一轮", submission: "prompt-1"), row(4, "继续", steer: true),
                   namedRow(6, "第二轮", submission: "prompt-2"), row(9, "继续", steer: true)]
    await comeBack(s, replayed: replayed)
    check("R5-01 (\(how)) the first answered, the second stored and its answer lost: the second marked, once: \(standing(second, in: s)); the first: \(standing(first, in: s))",
          unanswered(second, in: s) && s.deliveries.state(first) == nil)
}

#if !BEFORE
// kept across a relaunch (AppStore.keepUnanswered, this Mac's preferences per server): what was put
// into a turn and never answered is so still after it, its bubble back in the chat whatever the
// last data kept, and whatever the page read then shows; 再发一次 sends it, and nothing is kept
do {
    let suite = "ci.shion.send.unanswered"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let (s, _) = turnChat([oldRow(1, "继续")])
    s.keepUnanswered(in: defaults)
    let id = await lostInto(s, "继续")
    check("kept: the message whose answer never came is in this Mac's preferences, once",
          defaults.data(forKey: "ShionUnanswered").map { (try? JSONSerialization.jsonObject(with: $0) as? [Any])?.count } == 1)
    // relaunched: the last data's chat without it, then attached again and its newest page read
    let t = store(.queue, running: false)
    t.loadedChats = [bot]
    let server = Server(for: t)
    servers.append(server)
    server.running = false
    server.rows = [oldRow(1, "继续"), row(2, "继续", steer: true)]
    t.chats[bot] = t.transcriptItems(["rows": .array([oldRow(1, "继续")])])
    t.keepUnanswered(in: defaults)
    check("relaunched: marked still, its bubble back in the chat: \(standing(id, in: t))", unanswered(id, in: t))
    await comeBack(t, replayed: false)
    check("relaunched: …and once the newest page is read, its row stored after all on it, both show: \(said("继续", in: t)), \(standing(id, in: t))",
          unanswered(id, in: t) && said("继续", in: t) == ["row-1", id, "row-2"])
    t.resend(id, in: bot)
    await until { t.deliveries.state(id) == nil }
    check("relaunched: 再发一次 sent it, and nothing is kept any more", defaults.data(forKey: "ShionUnanswered") == nil)
    defaults.removePersistentDomain(forName: suite)
}

/// What the store follows of a message, and whether the chat has its bubble.
func record(_ id: String, in s: AppStore) -> String {
    (s.deliveries.state(id).map { "followed, \($0)" } ?? "followed no more") + (ids(s).contains(id) ? ", its bubble" : ", no bubble")
}

/// The ids of the messages whose answer never came that this Mac keeps in `defaults`.
func kept(in defaults: UserDefaults) -> [String] {
    guard let data = defaults.data(forKey: "ShionUnanswered"),
          let kept = try? JSONDecoder().decode([AppStore.KeptUnanswered].self, from: data)
    else { return [] }
    return kept.map(\.message.id)
}

// 不发了 (AppStore.giveUp): a message whose answer never came taken out of the chat. Nothing is
// sent and nothing needs the server; it is followed and kept no more, so neither a page read later
// nor a relaunch brings it back, and had it got there its row shows as any row does. Another such
// message is marked still
do {
    let suite = "ci.shion.send.giveup"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let (s, server) = turnChat([oldRow(1, "继续")])
    s.keepUnanswered(in: defaults)
    let id = await lostInto(s, "继续")
    let other = await lostInto(s, "讲短一点")
    let calls = s.gateway.calls.count
    // offline, and the chat not attached
    s.gateway.phase = .offline
    s.gateway.attached = []
    s.giveUp(id, in: bot)
    check("不发了, offline, the chat not attached: out of the chat, followed no more, nothing sent: \(record(id, in: s)); \(s.gateway.calls.count - calls) calls",
          !ids(s).contains(id) && s.deliveries.state(id) == nil && s.gateway.calls.count == calls)
    check("不发了: …kept on this Mac no more, the other one still: \(kept(in: defaults))", kept(in: defaults) == [other])
    check("不发了: …the other one marked still, with 再发一次: \(standing(other, in: s))", unanswered(other, in: s))
    // back, and a page read in the chat's place with its row on it: it got there after all
    s.gateway.phase = .online
    server.rows = [oldRow(1, "继续"), row(2, "继续", steer: true)]
    await comeBack(s, replayed: false)
    check("不发了: …a page read later, its row on it: the row shows, the bubble does not come back: \(said("继续", in: s))",
          said("继续", in: s) == ["row-1", "row-2"] && s.deliveries.state(id) == nil)
    // relaunched
    let t = store(.queue, running: false)
    t.chats[bot] = t.transcriptItems(["rows": .array([oldRow(1, "继续")])])
    t.keepUnanswered(in: defaults)
    check("不发了: …nor a relaunch, the other one back, marked: \(ids(t))",
          !ids(t).contains(id) && t.deliveries.state(id) == nil && unanswered(other, in: t))
    defaults.removePersistentDomain(forName: suite)
}

// only under a message whose answer never came: a declined one stays as it was
do {
    let s = store(.steer)
    s.gateway.answer = { method, params in
        method == "session.steer" ? ["status": "rejected", "text": params["text"] ?? .null, "execution_generation": 1]
            : ["status": "queued"]
    }
    _ = typed("别讲了", in: s)
    let id = s.chats[bot]?.last?.id ?? ""
    await until { s.deliveries.state(id) == .declined }
    s.giveUp(id, in: bot)
    check("不发了 only under a message whose answer never came: a declined one stays, with 再发一次: \(standing(id, in: s))",
          s.deliveries.state(id) == .declined && ids(s).contains(id))
}

// 重试 of the turn such a message was put into (AppStore.retryReply): the turn is taken back, and
// with it what was put into it; the message whose answer never came goes for good, as 不发了 takes
// it, and no page read later brings it back. One put into an earlier turn is marked still
do {
    let suite = "ci.shion.send.retried"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    servers.append(server)
    server.running = false
    s.keepUnanswered(in: defaults)
    /// Put into a turn, its answer lost.
    func lost(_ id: String, _ words: String) -> ChatItem {
        s.deliveries.track(id, botId: bot, text: words, at: then)
        s.deliveries.set(id, .unconfirmed)
        var item = AppStore.userItem(id: id, at: then, text: words)
        item.midTurn = true
        return item
    }
    s.chats[bot] = [ChatItem(id: "row-1", role: .user, at: then, text: "第一句"), lost("earlier", "等一下"),
                    ChatItem(id: "row-2", role: .assistant, at: then, text: "好。"),
                    ChatItem(id: "P", role: .user, at: then, text: "讲个长故事"),
                    ChatItem(id: "R", role: .assistant, at: then, text: "从前有座山", stopped: true),
                    lost("into", "讲短一点")]
    s.control.storedRows["P"] = 3
    server.rewinds = [3: ["target_message": ["id": 3, "content": "讲个长故事"], "rewound_count": 2]]
    await retryNow(s)
    check("重试 of the turn a message was put into, its answer never come: taken back and asked again, that message followed and kept no more, the one put into an earlier turn still: \(retried(s)); \(record("into", in: s)); kept \(kept(in: defaults))",
          rewound(s) == [3] && asked(s) == ["讲个长故事"] && s.deliveries.state("into") == nil && kept(in: defaults) == ["earlier"])
    server.rows = [oldRow(1, "第一句"), theirRow(2, "好。"), row(4, "讲个长故事")]
    await comeBack(s, replayed: false)
    check("重试 of that turn: …a page read in the chat's place later does not bring it back; the earlier one is there, marked: \(ids(s))",
          !ids(s).contains("into") && unanswered("earlier", in: s))
    defaults.removePersistentDomain(forName: suite)
}

// the line under it: what it says, and what 再发一次 says it does
check("the line: no answer came, whether it got there is not known and never will be, 再发一次 may say it twice: \(Delivery.unansweredNote) / \(Delivery.unansweredResend(to: "詩音"))",
      Delivery.unansweredNote.contains("没等到回音") && Delivery.unansweredNote.contains("送没送到不知道")
        && Delivery.unansweredNote.contains("以后也不会知道") && Delivery.unansweredNote.contains("两遍")
        && Delivery.unansweredResend(to: "詩音").contains("排在这一轮后面") && Delivery.unansweredResend(to: "詩音").contains("两遍"))
#endif

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

// a receipt lost, and the page has the row that names the message's submission
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
    server.rows += [namedRow(12, "好的", submission: id), theirRow(13, "嗯。")]
    await comeBack(s, replayed: false)
    check("control (a row that names the submission): the page's row stands for the message, once: \(ids(s))",
          ids(s) == ["row-10", "row-11", "row-12", "row-13"])
    check("control (a row that names the submission): …and Hermes has it", s.deliveries.state(id) == nil)
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

// ---- the third review: R3-02, what is left of it ------------------------------------------------
// A prompt Hermes admitted (its receipt came, so nothing follows it any more) whose turn's end was
// missed, the frames not to be had: only the page says which row it is, by the submission id Hermes
// keeps on that row, read as the page is read (AppStore.transcriptPage), the prompt followed here
// or not. Such a row is that prompt's and no one else's: a prompt in its words whose receipt was
// lost, and which never got there, is not taken for having it. (R3-02's other half, telling a
// message put into a turn apart from such a prompt, went with reading the transcript for those.)
for promptFirst in [true, false] {
    let order = promptFirst ? "the admitted one said first" : "the admitted one said after"
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    servers.append(server)
    server.running = false
    func prompt(lost: Bool) async -> String {
        server.prompt = lost ? { throw GatewayError.offline } : { ["status": "queued"] }
        _ = typed("继续", in: s)
        let id = s.chats[bot]?.last?.id ?? ""
        await until { s.deliveries.state(id) == (lost ? .unsure : nil) }
        return id
    }
    let admitted: String, lost: String
    if promptFirst {
        admitted = await prompt(lost: false)
        lost = await prompt(lost: true)
    } else {
        lost = await prompt(lost: true)
        admitted = await prompt(lost: false)
    }
    server.rows = [namedRow(901, "继续", submission: admitted), theirRow(902, "好，接着讲。")]
    for look in 1...2 {
        await comeBack(s, replayed: false)
        check("R3-02 (\(order)) look \(look): the row that names the admitted prompt is its own: \(s.control.storedRows[admitted].map(String.init) ?? "no row")",
              s.control.storedRows[admitted] == 901 && ids(s).contains("row-901") && !ids(s).contains(admitted))
        check("R3-02 (\(order)) look \(look): …and not the lost one's, in its words: 没发出去, under the page, once: \(ids(s))",
              s.deliveries.state(lost) == .unsent(nil) && ids(s).filter { $0 == lost }.count == 1)
    }
}

// ---- the pages Hermes gave before and after a compaction ------------------------------------
// compaction.json: ../../real, stage compact, in place (archive_and_compact) and into a new
// session (publish_compression_child), the newest page before and after each of four
// compactions. A compaction stores the messages it keeps again as new rows, each copy with all
// of its original but the number: the 「继续」 put into the turn as row 8 is row 16, the prompt
// 「继续」 row 18 is row 27, naming its submission still; a message summarized keeps its number.

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

let paths = ["in place", "rotation"]

for path in paths {
    let (before, after) = (captured(path, "before"), captured(path, "after"))
    let (old, copy) = (numbered(8, in: before), numbered(16, in: after))
    check("compact (\(path)) Hermes's pages: the 「继续」 put into the turn as row 8 is row 16 once compacted, at the same time, in the same words",
          old?["display_kind"] == "steer" && copy?["display_kind"] == "steer" && old?["timestamp"] == copy?["timestamp"]
            && old?["text"] == copy?["text"] && numbered(8, in: after) == nil)
    check("compact (\(path)) …a message summarized keeps its number, a prompt kept is a new row naming its submission still",
          numbered(5, in: after)?["timestamp"] == numbered(5, in: before)?["timestamp"]
            && numbered(10, in: after)?["display_metadata"]?["submission_id"] == numbered(1, in: before)?["display_metadata"]?["submission_id"]
            && numbered(10, in: after)?["timestamp"] == numbered(1, in: before)?["timestamp"])
    let (before2, after2) = (captured(path, "before2"), captured(path, "after2"))
    check("compact (\(path)) …and the second time: the prompt 「继续」 row 18 is row 27, the next 「继续」 put into a turn row 23 is row 32, the first stays row 16",
          numbered(27, in: after2)?["display_metadata"]?["submission_id"] == numbered(18, in: before2)?["display_metadata"]?["submission_id"]
            && numbered(32, in: after2)?["timestamp"] == numbered(23, in: before2)?["timestamp"]
            && numbered(16, in: after2)?["timestamp"] == numbered(16, in: before2)?["timestamp"])
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
    check("compact (\(path)) a prompt's receipt lost, and compacted since: row 27 names it, and stands for it, once: \(ids(s))",
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


/// 詩音's chat with the turn stopped: `rows` read from the transcript, then `prompt` (sent from here,
/// nil when it is the last of the rows) and the line the stop left; the server giving `page` and
/// answering a rewind as Hermes answered it, by the row it names (`answers`).
func stoppedChat(rows: [JSONValue], prompt: ChatItem?, page: [JSONValue], answers: [Int: JSONValue]) -> AppStore {
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    servers.append(server)
    server.running = false
    server.rows = page
    server.rewinds = answers
    s.chats[bot] = s.transcriptItems(["rows": .array(rows)]) + (prompt.map { [$0] } ?? [])
        + [ChatItem(id: "stopped", role: .system, at: Date(), text: "已停止", stopped: true)]
    return s
}

/// The same after the fourth compaction of the stage compact (with `later` after Hermes's rows).
func stoppedChat(_ path: String, rows: [JSONValue], prompt: ChatItem?, later: [JSONValue] = []) -> AppStore {
    var answers: [Int: JSONValue] = [:]
    for name in ["kept", "summarized", "rewound"] {
        if let rewind = compaction[path]?["rewinds4"]?[name], let row = rewind["row"]?.int {
            answers[row] = rewind["answer"]
        }
    }
    return stoppedChat(rows: rows, prompt: prompt, page: captured(path, "after4") + later, answers: answers)
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
// Hermes's wrapper for its words, no longer a steer. The turn under way keeps its prompt's name.

let auto = try JSONValue.parse(String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8))

/// The rows of a page the stage auto read (`before`, `after`, `during`, `after2`) on a path.
func autoPage(_ path: String, _ page: String) -> [JSONValue] { auto[path]?[page]?["rows"]?.array ?? [] }

/// The row a turn's end named (persisted_turn.user_row_id) for the turn begun with `words`.
func autoEnd(_ path: String, _ words: String) -> Int? { auto[path]?["ends"]?[words]?["user_row_id"]?.int }

/// The row on `rows` of `role` stored at `row`'s time: its copy, whatever its number and words.
func copy(of row: JSONValue?, in rows: [JSONValue]) -> JSONValue? {
    rows.first { $0["role"] == row?["role"] && $0["timestamp"] == row?["timestamp"] }
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
}

// R5-02 of the fifth review: the prompt 「继续（自动）」 said from here (its row known by number only,
// 5), then 「继续（自动）」 put into 「满了（自动）」's turn and never stored, its answer lost. Hermes
// compacts the session as 第三句 begins: every older row is a copy that names nothing, the copy of
// row 5 and that of the run's own first row too. Read then, nothing confirms it; it is marked
for path in paths {
    let before = autoPage(path, "before")
    let full = autoEnd(path, "满了（自动）") ?? 0
    guard let through = before.firstIndex(where: { $0["row_id"]?.int == full }),
          let submission = numbered(5, in: before)?["display_metadata"]?["submission_id"]?.string
    else {
        check("R5-02 (\(path)) the pages have 「满了（自动）」's and 「继续（自动）」's rows", false)
        continue
    }
    for replayed in [true, false] {
        let how = "\(path), \(replayed ? "frames replayed" : "newest page read")"
        let (s, server) = turnChat(Array(before[...through]))
        if let index = s.chats[bot]?.firstIndex(where: { $0.id == "row-5" }) {
            s.chats[bot]?[index] = ChatItem(id: submission, role: .user, at: then, text: "继续（自动）")
            s.control.storedRows[submission] = 5
        }
        let lost = await lostInto(s, "继续（自动）")
        server.rows = autoPage(path, "after")
        await comeBack(s, replayed: replayed)
        check("R5-02 (\(how)) put into 「满了」's turn and never stored, the session compacted since: no copy is it, marked: \(standing(lost, in: s))",
              unanswered(lost, in: s))
    }
}

// 重试 of a turn Hermes compacted in itself: read from the transcript while the turn ran, the prompt
// is the row it had then (in place a rewind to it is refused as no longer in the session's history,
// in a new session as compacted); its turn's end names its copy, which keeps the prompt's name
for path in paths {
    let (during, after2) = (autoPage(path, "during"), autoPage(path, "after2"))
    let prompt = during.last { $0["text"] == "慢慢做，满了（自动）" }
    let old = prompt?["row_id"]?.int ?? 0, now = autoEnd(path, "慢慢做，满了（自动）") ?? 0
    let submission = prompt?["display_metadata"]?["submission_id"]?.string ?? ""
    var answers: [Int: JSONValue] = [:]
    answers[old] = auto[path]?["rewinds"]?[String(old)]
    if auto[path]?["rewound"]?["row"]?.int == now {
        answers[now] = auto[path]?["rewound"]?["answer"]
    }
    let refusal = answers[old]?["error"]?["data"]?["detail"]?.string ?? "no refusal"
    check("auto 重试 (\(path)) Hermes's pages: the prompt, row \(old) as the turn ran, is row \(now) once compacted in the turn, at its time, named; its turn's end names \(now); a rewind to \(old) is refused (\(refusal)), one to \(now) taken",
          numbered(now, in: after2)?["display_metadata"]?["submission_id"]?.string == submission && !submission.isEmpty
            && numbered(now, in: after2)?["timestamp"] == prompt?["timestamp"] && numbered(old, in: after2) == nil
            && answers[old]?["error"] != nil && answers[now]?["target_message"]?["id"]?.int == now)
    let read = stoppedChat(rows: during, prompt: nil, page: after2, answers: answers)
    read.retryReply(bot)
    await until { !asked(read).isEmpty || notRetried(read) != nil }
    check("auto 重试 (\(path)) read from the transcript as row \(old), compacted in its turn: taken back as row \(now), at its time in its words, and asked again: \(retried(read))",
          rewound(read) == [old, now] && asked(read) == ["慢慢做，满了（自动）"] && notRetried(read) == nil)
    let sent = stoppedChat(rows: rows(during, before: old), prompt: ChatItem(id: submission, role: .user, at: Date(), text: "慢慢做，满了（自动）"),
                           page: after2, answers: answers)
    sent.control.storedRows[submission] = now
    sent.retryReply(bot)
    await until { !asked(sent).isEmpty || notRetried(sent) != nil }
    check("auto 重试 (\(path)) sent from here: its turn's end named the copy, taken back as it: \(retried(sent))",
          rewound(sent) == [now] && asked(sent) == ["慢慢做，满了（自动）"] && notRetried(sent) == nil)
}

// ---- Hermes's own compaction's copies -------------------------------------------------------
// Hermes's own pages (copies.json: ../../real, stage copies): 「继续（副本）」 put into the run
// 「慢慢做（副本）」 began (row 11), stored as row 14 (a steer), is a new row once Hermes compacted the
// session at 第三句's start, at its time, no longer a steer but Hermes's wrapper round its words; and
// the turns a background result and 课程's answer began, their rows copies that name nothing.

let copied = try JSONValue.parse(String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8))

for path in paths {
    let data = copied[path]
    let (before, after) = (data?["before1"]?["rows"]?.array ?? [], data?["after1"]?["rows"]?.array ?? [])
    let prompt = data?["steered"]?.string ?? ""
    let begun = numbered(11, in: before), steer = numbered(14, in: before)
    let kept = copy(of: steer, in: after)
    let third = after.last { $0["text"] == "第三句（副本）" }
    let thirds = third?["display_metadata"]?["submission_id"]?.string ?? "third"
    let run = (data?["runs1"]?.array ?? []).first { $0["input_id"]?.string == prompt }
    check("copies (\(path)) Hermes's pages: 「继续（副本）」 put into the run 「慢慢做（副本）」 began (row 11), row 14, is row \(kept?["row_id"]?.int ?? 0) once compacted, at its time, Hermes's wrapper, no steer; the prompt's own copy names nothing; 第三句 names its submission",
          begun?["display_metadata"]?["submission_id"]?.string == prompt && steer?["display_kind"] == "steer"
            && run?["persisted_turn"]?["user_row_id"]?.int == 11
            && kept?["display_kind"] == nil && kept?["text"]?.string?.hasPrefix("[OUT-OF-BAND USER MESSAGE") == true
            && kept?["text"]?.string?.contains("\n继续（副本）\n") == true
            && copy(of: begun, in: after)?["display_metadata"] == nil && third != nil && thirds != "third")
    // 重试 under a turn that a background result, or 课程's answer, began, stopped, the chat read
    // after the compaction: the copy of what began it is no message of yours to ask again
    for original in [9, 36] {
        guard let began = copy(of: numbered(original, in: before), in: after), let number = began["row_id"]?.int else {
            check("copies (\(path)) the copy of row \(original) is on the page", false)
            continue
        }
        let s = stoppedChat(rows: rows(after, before: number) + [began], prompt: nil, page: after, answers: [:])
        check("copies (\(path)) the turn row \(original) began, its copy row \(number) read after the compaction, stopped: no 重试 (\(s.chats[bot]?.dropLast().last.map { "\($0.role)" } ?? "none") before it)",
              s.retryTarget(bot) == nil)
    }
}

// ---- 重试 of a long turn Hermes compacted in itself (R5-03 of the fifth review) -------------------
// Hermes's own pages (longturn.json: ../../real, stage long, in place and into a new session): the
// prompt 「逐个检查这些文件，满了（长轮）」 read as row 9 while its first command ran, naming its
// submission; Hermes compacted the session once that command's result was back, the prompt's copy
// row 16 naming it still; 28 commands, the turn stopped in the last, its end naming 16. The newest
// page of 50 after it is 25 rows of tool calls with a cursor, the prompt on the second. A rewind to
// 9 is refused (in place as no longer in the session's history, in a new session as compacted), one
// to 16 takes the turn back. 重试 takes the prompt back by the row its submission is now, and, where
// that is not known, reads the pages through by their cursors to the row that is it: not on the
// newest page is not summarized. With 3 commands (78, then 83) the copy is on the newest page, and a
// prompt sent from here has its row from its end: the controls.

let long = try JSONValue.parse(String(contentsOfFile: CommandLine.arguments[4], encoding: .utf8))

/// The row of `page` that names `submission`.
func naming(_ submission: String, in page: JSONValue?) -> JSONValue? {
    (page?["rows"]?.array ?? []).first { $0["display_metadata"]?["submission_id"]?.string == submission }
}

/// `page` with its rows that name `submission` naming nothing.
func unnaming(_ submission: String, in page: JSONValue) -> JSONValue {
    guard case .object(var fields) = page else { return page }
    fields["rows"] = .array((page["rows"]?.array ?? []).map { row in
        guard row["display_metadata"]?["submission_id"]?.string == submission, case .object(var named) = row else { return row }
        named["display_metadata"] = nil
        return .object(named)
    })
    return .object(fields)
}

/// 詩音's chat with stage long's turn (`long`, `short`) stopped: read while it ran (Hermes's page of
/// then, by the store's own newest-page read, as a chat opened or attached again mid-run reads it),
/// or, `sentHere`, its prompt this Mac's bubble under its submission, after the rows before it; its
/// end noted, unless `missed` (the connection went); the line the stop left. The server then gives
/// Hermes's pages after the end, and answers the two rewinds as Hermes did. `unnamed`: as though
/// the prompt's row named no submission, on every page.
func longChat(_ path: String, _ name: String, missed: Bool = false, sentHere: Bool = false,
              unnamed: Bool = false) async -> (AppStore, Server) {
    let data = long[path]?[name]
    let submission = data?["submission"]?.string ?? ""
    func shown(_ page: JSONValue) -> JSONValue { unnamed ? unnaming(submission, in: page) : page }
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    servers.append(server)
    server.running = false
    let during = data?["during"] ?? .null
    if sentHere {
        let rows = during["rows"]?.array ?? []
        let before = Array(rows.prefix { $0["display_metadata"]?["submission_id"]?.string != submission })
        s.chats[bot] = s.transcriptItems(["rows": .array(before)])
            + [ChatItem(id: submission, role: .user, at: Date(), text: naming(submission, in: during)?["text"]?.string ?? "")]
    } else {
        server.pages = [shown(during)]
        s.attachMarks[bot] = 0
        try? await s.loadLatestPage(bot)
    }
    if !missed, let turn = data?["persisted_turn"] {
        s.noteFences(["session_id": .string(session), "type": "message.complete", "payload": ["persisted_turn": turn]])
    }
    s.chats[bot, default: []].append(ChatItem(id: "stopped", role: .system, at: Date(), text: "已停止", stopped: true))
    server.pages = (data?["after"]?.array ?? []).map(shown)
    server.cursors = []
    for key in ["old", "now"] {
        if let row = data?["rewinds"]?[key]?["row"]?.int {
            server.rewinds[row] = data?["rewinds"]?[key]?["answer"]
        }
    }
    return (s, server)
}

/// 重试 under the chat's stopped turn, and what it came to: the retry over, and what it asked
/// again or said (or the chat on another session).
func retryNow(_ s: AppStore) async {
    s.retryReply(bot)
    await until { !s.control.retrying.contains(bot) }
    await until { !asked(s).isEmpty || notRetried(s) != nil || s.sessions[bot] != session }
}

/// The pages a chat's server was asked for since, in words.
func pagesRead(_ server: Server) -> String {
    "pages read: " + server.cursors.map { $0 == nil ? "the newest" : "by cursor" }.joined(separator: ", ")
}

for path in paths {
    for (name, calls) in [("long", 28), ("short", 3)] {
        let data = long[path]?[name]
        let submission = data?["submission"]?.string ?? ""
        let after = data?["after"]?.array ?? []
        let old = data?["rewinds"]?["old"]?["row"]?.int ?? 0, now = data?["rewinds"]?["now"]?["row"]?.int ?? 0
        let first = naming(submission, in: data?["during"]), copy = after.lazy.compactMap { naming(submission, in: $0) }.first
        let on = after.firstIndex { naming(submission, in: $0) != nil }
        let refusal = data?["rewinds"]?["old"]?["answer"]?["error"]?["data"]?["detail"]?.string ?? "no refusal"
        let taken = data?["rewinds"]?["now"]?["answer"]?["rewound_count"]?.int ?? 0
        check("long turn (\(path), \(calls) commands) Hermes's pages: the prompt read mid-run as row \(old), naming its submission, is row \(now) once Hermes compacted in its turn, at its time, naming it still, and its end names \(now); after the end it is on page \((on ?? -1) + 1) of \(after.count) (the newest has \(after.first?["next_cursor"]?.string == nil ? "no" : "a") cursor); a rewind to \(old) is refused (\(refusal)), one to \(now) takes back \(taken) rows",
              first?["row_id"]?.int == old && copy?["row_id"]?.int == now && old != now && copy?["timestamp"] == first?["timestamp"]
                && data?["persisted_turn"]?["user_row_id"]?.int == now && on == (name == "long" ? 1 : 0)
                && (name == "short" || naming(submission, in: after.first) == nil && after.first?["next_cursor"]?.string != nil)
                && data?["rewinds"]?["old"]?["answer"]?["error"] != nil
                && taken == data?["persisted_turn"]?["row_ids"]?.array.count)
    }
    let words = naming(long[path]?["long"]?["submission"]?.string ?? "", in: long[path]?["long"]?["during"])?["text"]?.string ?? ""
    let old = long[path]?["long"]?["rewinds"]?["old"]?["row"]?.int ?? 0, now = long[path]?["long"]?["rewinds"]?["now"]?["row"]?.int ?? 0
    let firstCursor = long[path]?["long"]?["after"]?.array.first?["next_cursor"]?.string

    // the review's case: read mid-run as row 9, its end naming 16
    let (mid, _) = await longChat(path, "long")
    await retryNow(mid)
    check("重试 long turn (\(path)) read mid-run as row \(old), its end naming \(now): taken back as \(now), the row its submission is now, and asked again: \(retried(mid))",
          rewound(mid).last == now && asked(mid) == [words] && notRetried(mid) == nil)
    check("重试 long turn (\(path)) …by that row, not first by \(old), which Hermes no longer takes back: \(rewound(mid))", rewound(mid) == [now])
    // its end missed (the connection went): the pages read through, by their cursors, to the row that names it
    let (missed, server) = await longChat(path, "long", missed: true)
    await retryNow(missed)
    check("重试 long turn (\(path)) read mid-run, its end missed: \(old) refused; not on the newest page, on the second, by its cursor, \(now) names it: taken back as it, asked again: \(retried(missed)); \(pagesRead(server))",
          rewound(missed) == [old, now] && asked(missed) == [words] && notRetried(missed) == nil
            && server.cursors == [nil, firstCursor])
    // and with its row naming nothing, on every page: the copy at its time in its words
    let (plain, _) = await longChat(path, "long", missed: true, unnamed: true)
    await retryNow(plain)
    check("重试 long turn (\(path)) read mid-run, its row naming no submission, its end missed: \(now) found on the second page at its time in its words: \(retried(plain))",
          rewound(plain) == [old, now] && asked(plain) == [words] && notRetried(plain) == nil)
    // sent from here: its end names the copy (a control), or, missed, the pages are read through for it
    let (sent, _) = await longChat(path, "long", sentHere: true)
    await retryNow(sent)
    check("重试 long turn (\(path)) sent from here, its end naming \(now): taken back as it, as before: \(retried(sent))",
          rewound(sent) == [now] && asked(sent) == [words] && notRetried(sent) == nil)
    let (sentMissed, sentServer) = await longChat(path, "long", missed: true, sentHere: true)
    await retryNow(sentMissed)
    check("重试 long turn (\(path)) sent from here, its end missed, no page read since naming it: the second page does, \(now): \(retried(sentMissed)); \(pagesRead(sentServer))",
          rewound(sentMissed) == [now] && asked(sentMissed) == [words] && notRetried(sentMissed) == nil)
    // 3 commands: the copy on the newest page, its end seen or not (the controls)
    let short = long[path]?["short"]
    let shortWords = naming(short?["submission"]?.string ?? "", in: short?["during"])?["text"]?.string ?? ""
    let shortNow = short?["rewinds"]?["now"]?["row"]?.int ?? 0
    for missed in [false, true] {
        let (s, _) = await longChat(path, "short", missed: missed)
        await retryNow(s)
        check("重试 short turn (\(path)) read mid-run, its end \(missed ? "missed" : "seen"): taken back as \(shortNow), on the newest page, asked again, as before: \(retried(s))",
              rewound(s).last == shortNow && asked(s) == [shortWords] && notRetried(s) == nil)
    }
}

// ---- reading the pages through: as far as it takes, bounded, never round ---------------------------
// The stand-in's own pages (50 rows a page, a cursor for the rows above while there are any): the
// prompt 「逐个检查（替身）」 read as row 9 while its turn ran, naming its submission, its end missed;
// a rewind to 9 refused as no longer in the session's history (as Hermes refused it in place), one
// to 16 taken.

let checkWords = "逐个检查（替身）", checking = "CHECKING-SUBMISSION"

func refusedAs(_ detail: String) -> JSONValue {
    ["error": ["code": 4001, "message": "invalid_params",
               "data": ["reason": "invalid_params", "field": "target_message_id", "detail": .string(detail)]]]
}
let noLonger = refusedAs("target user message is no longer in session history")
let summarizedAway = refusedAs("compacted: target user message was summarized when the session was compressed")

/// `count` rows of a turn's tool calls, numbered from `from`.
func toolRows(_ count: Int, from: Int) -> [JSONValue] { (0..<count).map { theirRow(from + $0, "检查了第\($0 + 1)个文件") } }

/// The chat read while the turn ran (row 9 naming the submission), stopped since, its end missed;
/// the server then paging `rows` (oldest first), a rewind to 9 refused with `refusal`, one to 16 taken.
func pagedChat(_ rows: [JSONValue], refusal: JSONValue = noLonger) async -> (AppStore, Server) {
    let s = store(.queue, running: false)
    s.loadedChats = [bot]
    let server = Server(for: s)
    servers.append(server)
    server.running = false
    server.rows = [oldRow(1, "开始吧"), theirRow(2, "好。"), namedRow(9, checkWords, submission: checking)]
    s.attachMarks[bot] = 0
    try? await s.loadLatestPage(bot)
    s.chats[bot, default: []].append(ChatItem(id: "stopped", role: .system, at: Date(), text: "已停止", stopped: true))
    server.rows = rows
    server.cursors = []
    server.rewinds = [9: refusal, 16: ["target_message": ["id": 16, "content": .string(checkWords)], "rewound_count": 3]]
    return (s, server)
}

// what ControlError.notFound says (not in sources older than the change)
let notRead = "没能重试：没能把对话记录读完，不知道这条消息现在是哪一行"
// how many pages it reads at most (AppStore.searchPages)
let searchPages = 20
do {
    // far up, within the bound: page 13
    let (far, server) = await pagedChat([namedRow(16, checkWords, submission: checking)] + toolRows(600, from: 17))
    await retryNow(far)
    check("paged 重试: the prompt's copy 13 pages up: read through to it, taken back, asked again: \(retried(far)); \(server.cursors.count) pages read",
          rewound(far) == [9, 16] && asked(far) == [checkWords] && server.cursors.count == 13)
    // further up than it reads: it says it could not read them all, not that the prompt was summarized
    let (beyond, beyondServer) = await pagedChat([namedRow(16, checkWords, submission: checking)] + toolRows(1100, from: 17))
    await retryNow(beyond)
    check("paged 重试: the copy 23 pages up: \(searchPages) read, nothing taken back, and the chat says it could not read them all: \(retried(beyond)); \(beyondServer.cursors.count) pages read",
          rewound(beyond) == [9] && asked(beyond).isEmpty && notRetried(beyond) == notRead && beyondServer.cursors.count == searchPages)
    // every page read and none is it: then, and only then, Hermes's refusal says it (here: summarized)
    let (gone, goneServer) = await pagedChat(toolRows(120, from: 17), refusal: summarizedAway)
    await retryNow(gone)
    check("paged 重试: no copy on any of the 3 pages: every one read, then Hermes's word for it: \(retried(gone)); \(goneServer.cursors.count) pages read",
          rewound(gone) == [9] && asked(gone).isEmpty && notRetried(gone) == "没能重试：这条消息已经压缩进摘要里了" && goneServer.cursors.count == 3)
}
do {
    // a server that gives the same cursor again: two pages, not round and round
    let (again, server) = await pagedChat(toolRows(120, from: 17))
    server.paging = { params in
        ["rows": .array(toolRows(50, from: params["cursor"] == nil ? 200 : 100)), "next_cursor": "c:once", "reset": .bool(params["cursor"] == nil)]
    }
    await retryNow(again)
    check("paged 重试: a cursor given twice: two pages read, then it stops, says it could not read them all: \(retried(again)); \(server.cursors.count) pages read",
          rewound(again) == [9] && notRetried(again) == notRead && server.cursors == [nil, "c:once"])
    // a page read by a cursor that starts over (`reset`: the newest page again)
    let (over, overServer) = await pagedChat(toolRows(120, from: 17))
    overServer.paging = { params in
        params["cursor"] == nil ? ["rows": .array(toolRows(50, from: 200)), "next_cursor": "c:50", "reset": true]
            : ["rows": .array(toolRows(50, from: 300)), "next_cursor": "c:60", "reset": true]
    }
    await retryNow(over)
    check("paged 重试: the page read by the cursor starts over (reset): it stops there, says it could not read them all: \(retried(over)); \(overServer.cursors.count) pages read",
          rewound(over) == [9] && notRetried(over) == notRead && overServer.cursors.count == 2)
    // the chat moves to another session while the pages are read: nothing more is done or said
    let (moved, movedServer) = await pagedChat([namedRow(16, checkWords, submission: checking)] + toolRows(120, from: 17))
    movedServer.paging = { [unowned movedServer] params in
        moved.sessions[bot] = "s2"
        return movedServer.page(params)
    }
    await retryNow(moved)
    try? await Task.sleep(for: .milliseconds(100))
    check("paged 重试: the chat on another session meanwhile: no row of the old one taken back past 9, nothing asked, nothing said: \(retried(moved)); \(movedServer.cursors.count) pages read",
          rewound(moved) == [9] && asked(moved).isEmpty && notRetried(moved) == nil && movedServer.cursors.count == 1)
}
do {
    // a page read later that shows the prompt as the row it was before a compaction stored it again
    // (one above where it is now) leaves the newer one standing for it
    let s = store(.queue, running: false)
    let server = Server(for: s)
    servers.append(server)
    s.control.storedRows[checking] = 16
    server.rows = [namedRow(9, checkWords, submission: checking)]
    _ = try? await s.transcriptPage(bot, session, limit: 50)
    check("a page showing the prompt's row before its copy, read after its end named the copy: it is the copy still: \(s.control.storedRows[checking] ?? 0)",
          s.control.storedRows[checking] == 16)
}

// ---- 重试 of a prompt in the words of Hermes's wrapper (R5-04 of the fifth review) ----------------
// Hermes's own page (explicit.json: ../../real, stage explicit): 「整理上周的计划（粘贴）」 answered
// (rows 1, 2), then Hermes's wrapper for a message put into a turn, whole, sent as a prompt of its
// own (row 3, naming its submission), its turn stopped as it streamed (row 4). Hermes took a rewind
// to 3 back as 2 rows. The prompt is the stopped turn's own: 重试 takes back 3 and asks it again,
// and never 1, which would take the turn that answered back too and ask the old question again.

let explicit = try JSONValue.parse(String(contentsOfFile: CommandLine.arguments[5], encoding: .utf8))
do {
    let data = explicit["default"]
    let words = data?["words"]?.string ?? ""
    let rows = data?["page"]?["rows"]?.array ?? []
    let taken = data?["rewound"]?["answer"]
    check("pasted wrapper Hermes's page: row 3 names its submission, has no kind, is the wrapper as typed; 4 is its stopped reply, the last; a rewind to 3 took back \(taken?["rewound_count"]?.int ?? 0) rows",
          numbered(3, in: rows)?["display_metadata"]?["submission_id"]?.string == data?["submission"]?.string
            && numbered(3, in: rows)?["display_kind"] == nil && numbered(3, in: rows)?["text"]?.string == words
            && rows.last?["row_id"]?.int == 4 && rows.last?["display_metadata"]?["interrupted"] == true
            && data?["rewound"]?["row"]?.int == 3 && taken?["rewound_count"]?.int == 2)
    /// The chat read from `page` (by the store's own newest-page read), the stopped reply its last;
    /// the server answering a rewind to 3 as Hermes did (`typed` what it says was typed), and one to
    /// 1 as it would (the two turns).
    func pastedChat(_ page: [JSONValue], typed: String? = nil) async -> AppStore {
        let s = store(.queue, running: false)
        s.loadedChats = [bot]
        let server = Server(for: s)
        servers.append(server)
        server.running = false
        server.rows = page
        s.attachMarks[bot] = 0
        try? await s.loadLatestPage(bot)
        var answer = taken ?? .null
        if let typed, case .object(var fields) = answer, case .object(var target)? = fields["target_message"] {
            target["content"] = .string(typed)
            fields["target_message"] = .object(target)
            answer = .object(fields)
        }
        server.rewinds = [3: answer, 1: ["target_message": ["id": 1, "content": "整理上周的计划（粘贴）"], "rewound_count": 4]]
        return s
    }
    let pasted = await pastedChat(rows)
    check("pasted wrapper: 重试 under its stopped reply: \(pasted.retryTarget(bot) ?? "none")", pasted.retryTarget(bot) == "row-4")
    await retryNow(pasted)
    check("pasted wrapper: …takes back its own row, 3, and asks it again as typed, not the turn before: \(retried(pasted))",
          rewound(pasted) == [3] && asked(pasted) == [words] && notRetried(pasted) == nil)
    // the control: a plain prompt in its place
    let plainRows = rows.map { row -> JSONValue in
        guard row["row_id"]?.int == 3, case .object(var fields) = row else { return row }
        fields["text"] = "慢慢说（粘贴）"
        return .object(fields)
    }
    let plain = await pastedChat(plainRows, typed: "慢慢说（粘贴）")
    await retryNow(plain)
    check("pasted wrapper: the control, a plain prompt as row 3: taken back as 3, asked again, as before: \(retried(plain))",
          rewound(plain) == [3] && asked(plain) == ["慢慢说（粘贴）"] && notRetried(plain) == nil)
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
