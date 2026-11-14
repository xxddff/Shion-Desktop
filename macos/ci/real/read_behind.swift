import Foundation

// The app's own review talk (SkillReviewTalk.swift) and SessionWords (EventCursors.swift) over
// what Hermes itself sent when a turn's end overtook the answer to `session.resume` (probe.py,
// stage `behind`): the frames in the order they were on the socket, and the snapshots as they
// were answered. Compiled by read_behind.sh with the stand-ins of ci/logic/talk for the rest of
// the app.
//
// Twice. As it went: the talk reads the session, the frames Hermes sent while it held the answer
// come first, then the snapshot older than they are; it is asked for again and the next one is
// current. And as it would go on a server whose frames kept coming: every time the session is
// asked for again the answer is as old as the first (the same captured snapshot), so the talk
// has to go by it; later the session is read with nothing in the way (the captured later one).

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok {
        print("  ok  \(what)")
    } else {
        failures += 1
        print("FAIL  \(what)")
    }
}

func texts(_ talk: SkillReviewTalk, _ role: ChatRole) -> [String] {
    talk.items.filter { $0.role == role }.map(\.text)
}

func rows(_ snapshot: JSONValue) -> String {
    (snapshot["display_messages"]?.array ?? []).map { "\($0["row_id"]?.int ?? 0) \($0["role"]?.string ?? "?")" }
        .joined(separator: ", ")
}

guard CommandLine.arguments.count > 1, let raw = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8),
      let probe = try? JSONValue.parse(raw), let session = probe["session"]?.string,
      let probeId = probe["submission"]?.string
else {
    print("usage: read_behind <capture-behind.json>")
    exit(2)
}
let asked = (probe["held"]?["display_messages"]?.array ?? []).last { $0["role"]?.string == "user" }?["text"]?.string ?? ""
let reply = probe["frames_between"]?.array.first { $0["type"]?.string == "message.complete" }?["payload"]?["text"]?.string ?? ""
let before = (probe["opened"]?["display_messages"]?.array ?? []).filter { $0["role"]?.string == "assistant" }
    .compactMap { $0["text"]?.string }

print("what Hermes sent")
print("      frames while the answer was held: "
      + (probe["frames_between"]?.array ?? []).map { "\($0["type"]?.string ?? "?") \($0["seq"]?.int ?? 0)" }.joined(separator: ", "))
for (name, snapshot) in [("the held snapshot", probe["held"] ?? .null), ("the one after", probe["again"] ?? .null)] {
    print("      \(name): last_sequence \(snapshot["last_sequence"]?.int ?? -1), running \(snapshot["running"]?.bool ?? false), "
          + "pending \(snapshot["pending"]?.array.count ?? 0), rows \(rows(snapshot))")
}
check(probe["overtaken"]?.bool == true, "the turn's end was on the socket before the answer to session.resume")

func run(everyTimeOld: Bool) async {
    let store = AppStore()
    var card = review()
    card.reviewSession = session
    let talk = SkillReviewTalk(review: card)
    var capture = probe
    var answers: [JSONValue] = [probe["opened"] ?? .null]
    var resumes = 0
    var meanwhile: (() -> Void)?
    store.gateway.answer = { method, _ in
        switch method {
        case "session.resume":
            resumes += 1
            // what Hermes published while it held the answer is on the socket before it
            meanwhile?()
            meanwhile = nil
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        case "prompt.submit":
            return capture["receipt"] ?? .null
        default:
            return .null
        }
    }
    func take(_ frames: JSONValue?) {
        for frame in frames?.array ?? [] {
            store.words.note(frame)
            _ = talk.take(frame["type"]?.string ?? "", sessionId: frame["session_id"]?.string, frame["payload"] ?? .null)
        }
    }
    // the sheet opens on the session after its first turn, and the message is typed and sent
    await talk.open(in: store)
    talk.draft = asked
    await talk.send(in: store)
    guard let mine = talk.items.last(where: { $0.role == .user })?.id, mine != talk.materialId,
          let own = try? JSONValue.parse(raw.replacingOccurrences(of: probeId, with: mine))
    else { return check(false, "the message was not sent: \(talk.items.map(\.text))") }
    // the capture as this talk would have got it: the probe's submission id is the message's own
    capture = own
    take(capture["frames_before"])
    check(talk.busy && texts(talk, .assistant).last.map { reply.hasPrefix($0) && $0 != reply } == true,
          "the reply is arriving: \(texts(talk, .assistant).last ?? "")")

    let held = capture["held"] ?? .null, again = capture["again"] ?? .null
    answers = everyTimeOld ? [held] : [held, again]
    resumes = 0
    meanwhile = { take(capture["frames_between"]) }
    do {
        try await talk.read(in: store)
    } catch {
        check(false, "the session could not be read: \(error)")
    }
    check(store.words.outdate(held) && store.words.running(after: held) == false && store.words.ended(after: held),
          "SessionWords: the held snapshot is older than frames taken, which say the turn ended and nothing runs")
    check(store.words.current(held)["running"]?.bool == false && held["running"]?.bool == true,
          "SessionWords.current: it says running, and brought up to date it does not")
    check(!store.words.outdate(again), "SessionWords: the one after is not older than any frame")
    check(resumes == (everyTimeOld ? 1 + SessionWords.rereads : 2), "session.resume asked \(resumes) time(s)")
    check(!talk.busy && talk.items.allSatisfy { !$0.streaming }, "the talk is not left answering")
    check(texts(talk, .assistant) == before + [reply], "the reply is there, whole and once: \(texts(talk, .assistant))")
    check(texts(talk, .user).filter { $0 == asked }.count == 1 && talk.items.last?.text == reply,
          "under the message it answers, which is there once")
    check(talk.failure == nil && talk.sent.isEmpty, "nothing said to have failed or not to have gone")
    // read again later, nothing in the way
    answers = [again]
    try? await talk.read(in: store)
    check(!talk.busy && texts(talk, .assistant) == before + [reply] && texts(talk, .user).filter { $0 == asked }.count == 1,
          "read again with the later snapshot: the same, each once: \(talk.items.map(\.text))")
}

print("as it went: the snapshot asked for again is current")
await run(everyTimeOld: false)
print("had every answer been as old as the first: the talk goes by the old snapshot and the frames")
await run(everyTimeOld: true)
print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

func review() -> SkillReview {
    SkillReview(["id": "probe", "profile": "default", "skill": "probe", "kind": "updated", "entries": ["e1"],
                 "status": "pending", "at": "2026-11-13T10:00:00+09:00"])!
}
