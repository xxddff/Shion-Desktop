import Foundation

// The Bot Chat's attach and rejoin (cut from the app's own files by extract.py) against a session
// whose frames can overtake the answer to `session.resume`: the main chat's side of RR07.

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok {
        print("  ok  \(what)")
    } else {
        failures += 1
        print("FAIL  \(what)")
    }
}

let bot = "shion", session = "sess"

final class Server {
    var running = false
    var prompts: [String] = []
    var numbered = true
    var epoch = "epoch-1"
    var seq = 40
    var resumes = 0
    /// The passwords and keys still waited for, as a resume lists them (`open_requests`); nil: not listed.
    var openRequests: [String]?
    /// What happens between a snapshot being read and its answer going out, one per resume.
    var beforeResumeAnswers: [() -> Void] = []

    func handle(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard method == "session.resume" else { return .null }
        resumes += 1
        var snapshot: [String: JSONValue] = [
            "session_id": .string(session), "running": .bool(running), "messages_omitted": true,
            "prompts": .array(prompts.map { ["prompt_id": .string($0), "kind": "approval"] })]
        if numbered {
            snapshot["replay_epoch"] = .string(epoch)
            snapshot["last_sequence"] = .number(Double(seq))
        }
        if let openRequests {
            snapshot["open_requests"] = .array(openRequests.map {
                ["id": .string($0), "method": "sudo", "params": ["session_id": .string(session)]]
            })
        }
        let meanwhile = beforeResumeAnswers.isEmpty ? nil : beforeResumeAnswers.removeFirst()
        meanwhile?()
        return .object(snapshot)
    }
}

/// A frame as the store takes it (Gateway.deliver: onFrame, then AppStore.apply), as far as attach
/// and rejoin look at what it leaves: the reply's bubble, whether a turn runs, what is asked. A
/// session this socket has not attached has no chat to put it in (apply's guard); it is noted all
/// the same.
func frame(_ store: AppStore, _ server: Server, _ type: String, _ payload: JSONValue = [:]) {
    var params: [String: JSONValue] = ["type": .string(type), "session_id": .string(session), "payload": payload]
    if server.numbered {
        server.seq += 1
        params["seq"] = .number(Double(server.seq))
        params["replay_epoch"] = .string(server.epoch)
    }
    store.words.note(.object(params))
    guard let bot = store.sessionBots[session] else { return }
    switch type {
    case "message.start":
        store.setReplying(bot, true)
        let id = "live-\(store.chats[bot]?.count ?? 0)"
        store.chats[bot, default: []].append(ChatItem(id: id, role: .assistant, streaming: true))
        store.streaming[bot] = id
    case "message.delta":
        store.setReplying(bot, true)
        if let id = store.streaming[bot], let index = store.chats[bot]?.firstIndex(where: { $0.id == id }) {
            store.chats[bot]?[index].text += payload["text"]?.string ?? ""
        }
    case "message.complete":
        store.setReplying(bot, false)
        if let id = store.streaming.removeValue(forKey: bot), let index = store.chats[bot]?.firstIndex(where: { $0.id == id }) {
            store.chats[bot]?[index].streaming = false
        }
    case "session.info":
        if let running = payload["running"]?.bool {
            store.setRunning(bot, running)
            if !running { store.setReplying(bot, false) }
        }
    case "approval.request":
        store.addPrompt(payload, sessionId: session, botId: bot)
    case "approval.settled":
        store.asks.removeAll { $0.id == payload["prompt_id"]?.string }
    default:
        break
    }
}

/// A Bot Chat attached and shown, a turn under way with one part of its reply here.
func answering(numbered: Bool = true) -> (AppStore, Server) {
    let store = AppStore()
    let server = Server()
    server.numbered = numbered
    store.gateway.answer = { try await server.handle($0, $1) }
    store.sessions[bot] = session
    store.sessionBots[session] = bot
    store.loadedChats = [bot]
    store.chats[bot] = [ChatItem(id: "row-1", role: .user, text: "讲长一点")]
    server.running = true
    frame(store, server, "session.info", ["running": true])
    frame(store, server, "message.start")
    frame(store, server, "message.delta", ["text": "第一段。"])
    return (store, server)
}

func ends(_ store: AppStore, _ server: Server) {
    server.running = false
    frame(store, server, "message.delta", ["text": "第二段。"])
    frame(store, server, "message.complete", ["text": "第一段。第二段。"])
    frame(store, server, "session.info", ["running": false])
}

for caughtUp in [true, false] {
    print("the turn's end overtakes the snapshot (the frames missed \(caughtUp ? "replayed" : "not to be had"))")
    let (store, server) = answering()
    check(store.working[bot] == true && store.replying[bot] == true, "a turn under way")
    store.gateway.replayAnswer = caughtUp
    server.beforeResumeAnswers = [{ ends(store, server) }]
    await store.rejoin(bot, session)
    check(store.working[bot] == false && store.replying[bot] == false, "not left as replying: working \(String(describing: store.working[bot])), replying \(String(describing: store.replying[bot]))")
    check(store.streaming[bot] == nil, "no reply is taken to be arriving still")
    if caughtUp {
        check(store.chats[bot]?.last?.text == "第一段。第二段。" && store.chats[bot]?.last?.streaming == false, "the reply the frames ended is still there, whole")
    } else {
        check(store.pagesRead == 1, "the newest page is read for it")
    }
    check(server.resumes == 2, "the snapshot older than the turn's end was asked for again: \(server.resumes) resume(s)")
}

do {
    print("control: nothing overtakes the snapshot, the turn still runs")
    let (store, server) = answering()
    let reply = store.streaming[bot]
    await store.rejoin(bot, session)
    check(server.resumes == 1, "read once")
    check(store.working[bot] == true && store.streaming[bot] == reply && reply != nil, "still replying, in its bubble")
}

do {
    print("control: only the reply's words overtake the snapshot")
    let (store, server) = answering()
    let reply = store.streaming[bot]
    server.beforeResumeAnswers = [{ frame(store, server, "message.delta", ["text": "第二段。"]) }]
    await store.rejoin(bot, session)
    check(server.resumes == 1, "no reason to read again: \(server.resumes)")
    check(store.working[bot] == true && store.streaming[bot] == reply && store.chats[bot]?.last?.text == "第一段。第二段。", "still replying, in its bubble, with what came")
}

do {
    print("a turn begins between the snapshot and its answer")
    let (store, server) = answering()
    ends(store, server)
    check(store.working[bot] == false, "the turn over")
    server.beforeResumeAnswers = [{
        server.running = true
        frame(store, server, "session.info", ["running": true])
        frame(store, server, "message.start")
        frame(store, server, "message.delta", ["text": "好，"])
    }]
    await store.rejoin(bot, session)
    check(store.working[bot] == true && store.replying[bot] == true, "replying: working \(String(describing: store.working[bot]))")
    check(store.streaming[bot] != nil && store.chats[bot]?.last?.id == store.streaming[bot] && store.chats[bot]?.last?.text == "好，",
          "the reply goes on in the bubble the frames began")
}

do {
    print("an approval asked between the snapshot and its answer")
    let (store, server) = answering()
    server.beforeResumeAnswers = [{
        server.prompts = ["p1"]
        frame(store, server, "approval.request", ["prompt_id": "p1"])
    }]
    await store.rejoin(bot, session)
    check(store.asked == ["p1"], "it still waits for you: \(store.asked)")
}

do {
    print("an approval answered between the snapshot and its answer")
    let (store, server) = answering()
    server.prompts = ["p1"]
    frame(store, server, "approval.request", ["prompt_id": "p1"])
    server.beforeResumeAnswers = [{
        server.prompts = []
        frame(store, server, "approval.settled", ["prompt_id": "p1"])
    }]
    await store.rejoin(bot, session)
    check(store.asked.isEmpty, "it does not come back: \(store.asked)")
}

do {
    print("a server that numbers nothing: as before")
    let (store, server) = answering(numbered: false)
    server.beforeResumeAnswers = [{ ends(store, server) }]
    await store.rejoin(bot, session)
    check(server.resumes == 1, "nothing tells the snapshot older: read once")
}

#if !OLD
do {
    print("a first attach (a chat not opened on this socket yet): its frames are not shown, but noted")
    let store = AppStore()
    let server = Server()
    store.gateway.answer = { try await server.handle($0, $1) }
    server.running = true
    server.beforeResumeAnswers = [{ ends(store, server) }]
    let snapshot = try! await store.resumed(bot, session)
    store.attach(bot, snapshot: snapshot)
    check(server.resumes == 2 && store.working[bot] == false && store.replying[bot] == false, "not attached as replying: \(server.resumes) resume(s)")
}

do {
    print("every snapshot is overtaken: asked a few times, then the frames' word on the turn stands")
    let (store, server) = answering()
    server.beforeResumeAnswers = Array(repeating: { frame(store, server, "session.info", ["running": false]) }, count: 12)
    await store.rejoin(bot, session)
    check(server.resumes == 1 + SessionWords.rereads, "bounded: \(server.resumes) resume(s)")
    check(store.working[bot] == false && store.replying[bot] == false, "the newest frame's word, not the snapshot's")
}

do {
    print("every snapshot is overtaken by an approval asked after it was read")
    let (store, server) = answering()
    var n = 0
    server.beforeResumeAnswers = Array(repeating: {
        // asked after this snapshot was read: the next one lists it, and is overtaken in its turn
        n += 1
        frame(store, server, "approval.request", ["prompt_id": .string("p\(n)"), "kind": "approval"])
        server.prompts.append("p\(n)")
    }, count: 12)
    await store.rejoin(bot, session)
    check(server.resumes == 1 + SessionWords.rereads, "bounded: \(server.resumes) resume(s)")
    check(store.asked == ["p1", "p2", "p3", "p4"], "every approval a frame brought still waits, the one no snapshot lists too: \(store.asked)")
}

do {
    print("every snapshot is overtaken, the last one by the answer to an approval it still lists")
    let (store, server) = answering()
    server.prompts = ["p1"]
    frame(store, server, "approval.request", ["prompt_id": "p1", "kind": "approval"])
    let busy = { frame(store, server, "session.info", ["running": true]) }
    server.beforeResumeAnswers = [busy, busy, busy, {
        frame(store, server, "approval.settled", ["prompt_id": "p1"])
        server.prompts = []
    }]
    await store.rejoin(bot, session)
    check(server.resumes == 1 + SessionWords.rereads, "bounded: \(server.resumes) resume(s)")
    check(store.asked.isEmpty, "the approval a frame settled does not come back with a snapshot older than that frame: \(store.asked)")
}

do {
    print("a first attach, every snapshot overtaken by an approval: the frames are not shown, the asks are not lost")
    let store = AppStore()
    let server = Server()
    store.gateway.answer = { try await server.handle($0, $1) }
    var n = 0
    server.beforeResumeAnswers = Array(repeating: {
        n += 1
        frame(store, server, "approval.request", ["prompt_id": .string("p\(n)"), "kind": "approval"])
        server.prompts.append("p\(n)")
    }, count: 12)
    let snapshot = try! await store.resumed(bot, session)
    store.attach(bot, snapshot: snapshot)
    check(store.asked == ["p1", "p2", "p3", "p4"], "all of them wait for you: \(store.asked)")
}

do {
    print("the stream started over (another epoch): the snapshot is the session as it is")
    let (store, server) = answering()
    frame(store, server, "approval.request", ["prompt_id": "p1", "kind": "approval"])
    ends(store, server)
    server.epoch = "epoch-2"
    server.seq = 2
    server.running = true
    server.prompts = ["p9"]
    await store.rejoin(bot, session)
    check(server.resumes == 1, "nothing taken before can be told newer than it: read once")
    check(store.working[bot] == true && store.asked == ["p9"], "its word on the turn and on what waits: working \(String(describing: store.working[bot])), \(store.asked)")
}

do {
    print("a password asked for between the snapshot and its answer")
    let (store, server) = answering()
    server.openRequests = []
    store.take(store.secretRequest("sudo", id: "srq-before", params: .null, botId: bot, sessionId: session, timed: true,
                                   at: Date().addingTimeInterval(-60)))
    server.beforeResumeAnswers = [{
        store.take(store.secretRequest("sudo", id: "srq-since", params: .null, botId: bot, sessionId: session, timed: true))
    }]
    await store.rejoin(bot, session)
    check(store.secrets.request("srq-since")?.state == .waiting && store.asks.contains { $0.id == "srq-since" },
          "it still waits, though the snapshot does not list it: \(String(describing: store.secrets.request("srq-since")?.state))")
    check(store.secrets.request("srq-before")?.state == .expired && !store.asks.contains { $0.id == "srq-before" },
          "one from before the resume that the snapshot leaves out is over")
}
#endif

print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
