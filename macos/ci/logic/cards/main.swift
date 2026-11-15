import Foundation

// The cards for what Hermes says on its own, checked away from a Mac: the app's own StatusCards.swift
// and Compose.swift compiled in as they are, and the store's own AppStore.noteSaid, shownChat and
// transcriptItems (cut from its files by extract.py, against stubs.swift), driven the way AppStore.apply
// drives them: every frame of a chat's session goes to noteSaid, in the order it came. The frames and
// pages of held.json and status.json are Hermes's own (../../real, stages held and status). Each check
// prints ok or FAIL; the run fails on any FAIL.
//
// What is covered: a compaction is one card from its first line to its end, never left running, and
// the transcript's summary row and the live card are one item; a warning Hermes tags as compaction is
// none; while one runs only 排队 and 引导 go, 打断 as 排队 (what Hermes did with each, held open, is in
// held.json); the notices keyed and replaced, a cleared one settled; a fallback, a goal's verdict, a
// turn picked up again, a side question's and a side task's answers kept once, a frame replayed the
// same card; a wait for the provider one card while it lasts.

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String, line: Int = #line) {
    print((ok ? "ok    " : "FAIL  ") + what + (ok ? "" : "  (line \(line))"))
    if !ok { failures += 1 }
}

let bot = "diary"

/// A frame as AppStore.apply takes it: its name first (AppStore.swift, gateway.onFrame), then noteSaid.
@MainActor func take(_ store: AppStore, _ frame: JSONValue, shown: Bool = true) {
    store.frameName = AppStore.frameName(frame)
    store.noteSaid(frame["type"]?.string ?? "", frame["payload"] ?? .null, in: bot, shown: shown)
}

@MainActor func frame(_ type: String, _ payload: JSONValue = [:], seq: Int? = nil) -> JSONValue {
    var fields: [String: JSONValue] = ["type": .string(type), "session_id": "s1", "payload": payload]
    if let seq {
        fields["seq"] = .number(Double(seq))
        fields["replay_epoch"] = "e1"
    }
    return .object(fields)
}

@MainActor func status(_ kind: String, _ text: String, seq: Int? = nil) -> JSONValue {
    frame("status.update", ["kind": .string(kind), "text": .string(text)], seq: seq)
}

@MainActor func states(_ store: AppStore) -> [String] {
    (store.status.compactions[bot] ?? []).compactMap { ChatStatus.state(of: $0)?.rawValue }
}

@MainActor func shown(_ store: AppStore) -> [ChatItem] {
    store.shownChat(bot)
}

/// The compaction cards a chat shows: the live ones and the transcript's rows.
@MainActor func compactions(_ items: [ChatItem]) -> [ChatItem] {
    items.filter { if case .compaction? = $0.event { return true } else { return false } }
}

let preflight = "📦 Preflight compression: ~6,041 tokens >= 4,000 threshold. This may take a moment."
let summarizing = "🗜️ Compacting context — summarizing earlier conversation so I can continue..."
let done = "✓ Context compaction complete — continuing turn..."
let repeated = "⚠️  Session compressed 2 times — accuracy may degrade. Consider /new to start fresh."

// MARK: what the frames say

do {
    check(HermesStatus.compaction(kind: "compacting", text: preflight) == .runs(preflight)
          && HermesStatus.compaction(kind: "compressing", text: "Compressing…") == .runs("Compressing…")
          && HermesStatus.compaction(kind: "compacted", text: done) == .over(done)
          && HermesStatus.compaction(kind: "ready", text: "") == .over(""),
          "status. compacting and compressing run a compaction, compacted and ready end it")
    check(HermesStatus.compaction(kind: "compacting", text: repeated) == nil
          && HermesStatus.compaction(kind: "compacting", text: "⚠ Compression model context is below the threshold") == nil,
          "status. a warning the gateway tags compacting (⚠, alone or as the emoji) runs no compaction")
    check(HermesStatus.compaction(kind: "lifecycle", text: summarizing) == nil
          && HermesStatus.compaction(kind: "process", text: "✔ [default] @study Kanban t_1 done") == nil,
          "status. other kinds are no compaction's")
    let fallback = "⚠️ Model fallback: mock-model via custom unavailable (model not found); using mock-fallback via custom."
    check(HermesStatus.isFallbackSwitch(kind: "lifecycle", text: fallback)
          && HermesStatus.isFallbackSwitch(kind: "fallback", text: "on gpt-5 now")
          && HermesStatus.isFallbackSwitch(kind: "warn", text: "Switching to fallback provider"),
          "status. a fallback switch: Hermes's lifecycle line, kind fallback, the official client's other wordings")
    check(!HermesStatus.isFallbackSwitch(kind: "fallback", text: "  ")
          && !HermesStatus.isFallbackSwitch(kind: "lifecycle",
                                            text: "✅ Primary model restored: mock-model via custom; fallback mock-fallback via custom is no longer active.")
          && !HermesStatus.isFallbackSwitch(kind: "lifecycle", text: summarizing),
          "status. no switch: an empty one, the primary model back (the official client shows none), a compaction's line")
    let wait = "⏳ waiting on mock-model — 60s waiting for the first stream chunk (auto-reconnect: stream stale watchdog in 840s)"
    check(HermesStatus.providerWait(wait) == wait && HermesStatus.providerWait(" ⚙ processing prompt — 31% ") == "⚙ processing prompt — 31%"
          && HermesStatus.providerWait("⏳ still waiting on gpt-5 — 170s") != nil
          && HermesStatus.providerWait("↻ rate limited, retrying in 4s") != nil,
          "status. an explained wait: waiting on, processing prompt, still waiting, rate limited")
    check(HermesStatus.providerWait("(°ロ°) synthesizing...") == nil && HermesStatus.providerWait("") == nil
          && HermesStatus.providerWait("waiting on mock-model") == nil,
          "status. the spinner's faces, the empty frame, a wait without Hermes's mark: none")
}

// MARK: 打断 while Hermes compacts (Compose.swift)

do {
    check(BusyMode.interrupt.now(compacting: true) == .queue && BusyMode.steer.now(compacting: true) == .steer
          && BusyMode.queue.now(compacting: true) == .queue && BusyMode.interrupt.now(compacting: false) == .interrupt,
          "compose. while compacting 打断 goes as 排队; 引导 and 排队 as chosen; not compacting, 打断 as chosen")
    check(BusyMode.allCases.filter { $0.offered(compacting: true) } == [.queue, .steer]
          && BusyMode.allCases.filter { $0.offered(compacting: false) } == BusyMode.allCases,
          "compose. while compacting the menu offers 排队 and 引导; otherwise all three")
    let redirect = Sending(mode: .interrupt, generation: 8)
    check(redirect.correction(running: true, generation: 8, compacting: true) == nil
          && redirect.correction(running: true, generation: 8, compacting: false)?.method == "session.redirect",
          "compose. 打断 settled before the compaction: no session.redirect while it runs, and as before once it is over")
    check(Sending(mode: .steer, generation: 8).correction(running: true, generation: 8, compacting: true)?.method == "session.steer",
          "compose. 引导 still goes into the turn while it compacts (Hermes keeps it for the turn's next step)")
}

// MARK: a compaction, scripted

do {
    // its card from the first line to its end; the line it shows is the newest; the end is its word
    let s = AppStore()
    take(s, status("compacting", preflight, seq: 1))
    check(s.compacting(bot) && states(s) == ["running"], "compaction. the first line: running, one card: \(states(s))")
    take(s, status("compacting", summarizing, seq: 2))
    take(s, status("compacting", "🗜️ Compacting context — still summarizing earlier conversation so I can continue...", seq: 3))
    check(states(s) == ["running"] && s.status.compactions[bot]?.first?.text.hasPrefix("🗜️ Compacting context — still") == true,
          "compaction. more lines, the heartbeat among them: the same card, with the newest line")
    take(s, status("compacting", repeated, seq: 4))
    check(s.status.compactions[bot]?.first?.text.hasPrefix("🗜️") == true, "compaction. a warning tagged compacting changes nothing of it")
    take(s, status("compacted", done, seq: 5))
    check(!s.compacting(bot) && states(s) == ["done"], "compaction. compacted: done, nothing runs: \(states(s))")
    take(s, frame("message.start", seq: 6))
    take(s, status("compacting", repeated, seq: 7))
    take(s, frame("thinking.delta", ["text": "(¬‿¬) brainstorming..."], seq: 8))
    check(!s.compacting(bot) && states(s) == ["done"],
          "compaction. the warning again as the next turn starts: no card, nothing runs (Hermes's own stage held)")
    check(s.notes[bot]?.isEmpty != false, "compaction. nothing of it among the kept cards")
}

do {
    // never left running: each end it can have
    let ends: [(String, [JSONValue])] = [
        ("the turn's end", [frame("message.complete", ["status": "complete"])]),
        ("a failed turn's end", [frame("message.complete", ["status": "error"])]),
        ("the error frame", [frame("error", ["message": "boom"])]),
        ("nothing runs (session.info)", [frame("session.info", ["running": false])]),
        ("the next turn's start", [frame("message.start")]),
        ("the model's next words", [frame("message.delta", ["text": "好"])]),
        ("the spinner of the next call", [frame("thinking.delta", ["text": "(¬‿¬) brainstorming..."])]),
        ("a tool", [frame("tool.start", ["name": "terminal"])]),
    ]
    for (name, frames) in ends {
        let s = AppStore()
        take(s, status("compacting", summarizing))
        for f in frames { take(s, f) }
        check(!s.compacting(bot) && states(s) == ["ended"], "compaction. no compacted, then \(name): over, ended: \(states(s))")
    }
    let s = AppStore()
    take(s, status("compacting", summarizing))
    take(s, frame("session.info", ["running": true, "pending": []]))
    take(s, frame("session.usage", ["context_tokens": 110]))
    take(s, frame("agent.print", ["text": "  ⟳ compacting context…"]))
    check(s.compacting(bot) && states(s) == ["running"], "compaction. a session.info that says it runs, usage, a print: it runs still")
    s.status.attached(bot, running: true)
    check(s.compacting(bot), "compaction. a snapshot that says the session runs: it runs still")
    s.status.attached(bot, running: false)
    check(!s.compacting(bot) && states(s) == ["ended"], "compaction. a snapshot that says nothing runs (a reconnect): ended")
    take(s, status("compacted", done))
    check(states(s) == ["done"], "compaction. its compacted after all, nothing in between: the newest card is done")
}

do {
    // a chat whose rows are not loaded: followed, no card; opened while it runs, its card from when it began
    let s = AppStore()
    take(s, status("compacting", summarizing), shown: false)
    check(s.compacting(bot) && states(s).isEmpty, "compaction. a chat not open: it runs, no card yet")
    s.chats[bot] = [ChatItem(id: "row-30", role: .assistant, at: Date(), text: "好")]
    s.status.opened(bot, after: s.knownRow(bot))
    check(states(s) == ["running"], "compaction. the chat opened while it runs: its card: \(states(s))")
    take(s, status("compacted", done))
    check(states(s) == ["done"] && !s.compacting(bot), "compaction. …and done with its compacted")
    let t = AppStore()
    take(t, status("compacting", summarizing), shown: false)
    take(t, status("compacted", done), shown: false)
    t.status.opened(bot, after: nil)
    check(states(t).isEmpty, "compaction. over before the chat opened: no card (the page has its row)")
}

do {
    // the transcript's summary row and the live card are one item
    let s = AppStore()
    let now = Date()
    s.chats[bot] = [ChatItem(id: "row-12", role: .user, at: now.addingTimeInterval(-5), text: "满了"),
                    ChatItem(id: "row-13", role: .assistant, at: now.addingTimeInterval(-4), text: "好")]
    take(s, status("compacting", summarizing))
    take(s, status("compacted", done))
    check(compactions(shown(s)).count == 1, "compaction. done, the transcript not read again: its live card, once")
    let page = s.transcriptItems(["rows": [
        ["row_id": 12, "row_kind": "message", "role": "user", "text": "满了", "timestamp": .number(now.timeIntervalSince1970 - 5)],
        ["row_id": 15, "row_kind": "compaction", "role": "system", "text": "## Historical Task Snapshot\n满了", "compacted_messages": 9,
         "timestamp": .number(now.timeIntervalSince1970)],
        ["row_id": 16, "row_kind": "message", "role": "assistant", "text": "好", "timestamp": .number(now.timeIntervalSince1970 + 1)],
    ]])
    let row = page.first { $0.id == "compaction-15" }
    check(row?.role == .card && row?.event == .compaction(.done, messages: 9) && row?.text == "## Historical Task Snapshot\n满了",
          "compaction. its row read: a done compaction card, how many messages it folded, the summary as its words")
    s.chats[bot] = page
    s.status.settle(bot, rows: page)
    let cards = compactions(shown(s))
    check(cards.map(\.id) == ["compaction-15"], "compaction. read again: one item, the row's, not the live card besides: \(cards.map(\.id))")
    // an older summary row (the chat knew it before this compaction) is not this one's
    let t = AppStore()
    t.chats[bot] = [ChatItem(id: "compaction-9", role: .card, at: now, text: "旧的", event: .compaction(.done, messages: 3)),
                    ChatItem(id: "row-13", role: .assistant, at: now, text: "好")]
    take(t, status("compacting", summarizing))
    t.status.settle(bot, rows: t.chats[bot] ?? [])
    check(t.compacting(bot) && compactions(shown(t)).count == 2,
          "compaction. a summary row older than the compaction (row 9 of 13 known): not its, it runs still, two cards")
    // the row read while it runs (its compacted not seen: a reconnect without replay): done, nothing runs
    t.chats[bot] = (t.chats[bot] ?? []) + [ChatItem(id: "compaction-14", role: .card, at: now, text: "新的",
                                                     event: .compaction(.done, messages: 5))]
    t.status.settle(bot, rows: t.chats[bot] ?? [])
    check(!t.compacting(bot) && compactions(shown(t)).map(\.id) == ["compaction-9", "compaction-14"],
          "compaction. its row on a page while it still ran: done, nothing runs, the row is the card: \(compactions(shown(t)).map(\.id))")
    // two compactions, the first gave up: the second's row is not the first's
    let u = AppStore()
    u.chats[bot] = [ChatItem(id: "row-20", role: .assistant, at: now, text: "好")]
    take(u, status("compacting", preflight))
    take(u, frame("thinking.delta", ["text": "(◔_◔) contemplating..."]))
    u.chats[bot] = (u.chats[bot] ?? []) + [ChatItem(id: "row-21", role: .user, at: now, text: "再来")]
    take(u, status("compacting", summarizing))
    take(u, status("compacted", done))
    u.chats[bot] = (u.chats[bot] ?? []) + [ChatItem(id: "compaction-25", role: .card, at: now, text: "摘要",
                                                     event: .compaction(.done, messages: 7))]
    u.status.settle(bot, rows: u.chats[bot] ?? [])
    let both = compactions(shown(u))
    check(states(u) == ["ended", "done"] && both.count == 2 && both.contains { $0.id == "compaction-25" }
          && both.contains { ChatStatus.state(of: $0) == .ended },
          "compaction. one gave up, the next made row 25: the first ended, the second is its row: \(both.map(\.id))")
}

// MARK: compactions Hermes held open (held.json)

let held = try JSONValue.parse(String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))
for path in ["in place", "rotation", "gave up"] {
    for name in ["start", "middle"] {
        guard let ran = held[path]?[name] else { continue }
        let frames = ran["frames"]?.array ?? []
        let sends = ran["sends"]?.array ?? []
        let issued = ran["issued_before"]?.int
        let label = "held. (\(path), \(name))"
        let s = AppStore()
        // the chat knows every row issued before the turn, at most
        s.chats[bot] = issued.map { [ChatItem(id: "row-\($0)", role: .assistant, at: .distantPast, text: "之前")] } ?? []
        var running: [Bool] = []
        for f in frames {
            take(s, f)
            running.append(s.compacting(bot))
        }
        let kinds = frames.map { $0["type"]?.string ?? "" }
        let first = kinds.indices.first { kinds[$0] == "status.update" && frames[$0]["payload"]?["kind"]?.string == "compacting" }
        let over = kinds.indices.first { kinds[$0] == "status.update" && frames[$0]["payload"]?["kind"]?.string == "compacted" }
        if path == "gave up" {
            // Hermes said it compacts, gave up (too little to fold), and the turn went on
            check(first != nil && over == nil, "\(label) Hermes said compacting and never compacted")
            check(!s.compacting(bot) && states(s) == ["ended"], "\(label) the card ended, nothing runs: \(states(s))")
            let page = s.transcriptItems(ran["page"] ?? [:])
            s.chats[bot] = page
            s.status.settle(bot, rows: page)
            check(compactions(page).isEmpty && compactions(shown(s)).map { ChatStatus.state(of: $0) } == [.ended],
                  "\(label) no summary row: its card stays, ended")
            continue
        }
        guard let first, let over else {
            check(false, "\(label) the capture has its compacting and compacted: \(kinds.joined(separator: " "))")
            continue
        }
        check(running[first...].prefix(over - first).allSatisfy { $0 } && !running[over],
              "\(label) running from its first line to its compacted, not after")
        check(running[..<first].allSatisfy { !$0 }, "\(label) not before its first line")
        check(states(s) == ["done"], "\(label) one card, done: \(states(s))")
        check(!running.suffix(from: over).contains(true),
              "\(label) after compacted nothing runs again (the warning tagged compacting at the next turn's start included)")
        // what was sent meanwhile: the store saw it compacting then, so 打断 would have gone as 排队
        for send in sends {
            let method = send["method"]?.string ?? ""
            let at = send["sent_after_frames"]?.int ?? 0
            let compactingThen = at > 0 && at <= running.count ? running[at - 1] : false
            check(compactingThen, "\(label) \(method) was sent while the store said it compacts")
        }
        let answers = Dictionary(uniqueKeysWithValues: sends.map { ($0["method"]?.string ?? "", $0["answer"] ?? .null) })
        check(answers["session.redirect"]?["status"]?.string == "rejected" && answers["session.redirect"]?["delivered"] == nil,
              "\(label) Hermes answered the redirect rejected, without delivered: false (it kept nothing of it)")
        check(answers["session.steer"]?["status"]?.string == "queued" && answers["prompt.submit"]?["admission_id"] != nil,
              "\(label) the steer queued, the prompt admitted")
        // read again once every turn ran: the summary row is the card, not the live one besides
        let page = s.transcriptItems(ran["page"] ?? [:])
        s.chats[bot] = page
        s.status.settle(bot, rows: page)
        let summaries = compactions(page).compactMap { ChatStatus.compactionRow($0.id) }.filter { $0 > (issued ?? 0) }
        check(summaries.count == 1, "\(label) the page has its summary row past the rows issued before: \(summaries)")
        check(compactions(shown(s)).filter { $0.id.hasPrefix(ChatStatus.compactionPrefix) }.isEmpty,
              "\(label) read again: its live card is that row, one item")
    }
}

// MARK: what the official client reads besides (status.json)

let captured = try JSONValue.parse(String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8))
func frames(_ name: String) -> [JSONValue] { captured["spare"]?[name]?["frames"]?.array ?? [] }

@MainActor func kept(_ store: AppStore) -> [ChatItem] { store.notes[bot] ?? [] }

do {
    // the credits notices: one card a key, the newest words where they came, a cleared one settled
    let s = AppStore()
    var after: [[String]] = []
    for f in frames("credits") {
        take(s, f)
        if f["type"]?.string == "notification.show" { after.append(kept(s).map(\.id)) }
    }
    let notices = kept(s)
    check(notices.map(\.id) == ["status-notice-credits.usage", "status-notice-credits.depleted", "status-notice-credits.restored"],
          "notices. Hermes's credits notices: one card a key: \(notices.map(\.id))")
    let usage = notices.first { $0.id == "status-notice-credits.usage" }
    check(usage?.text == "⚠ You've used $20.00 of your $20.00 cap" && usage?.event == .notice(level: "warn", key: "credits.usage", cleared: true),
          "notices. the cap's line: its newest words (Hermes replaced it twice), then cleared: \(usage?.text ?? "") \(String(describing: usage?.event))")
    check(notices[1].event == .notice(level: "error", key: "credits.depleted", cleared: true),
          "notices. the paused access: cleared once it was back")
    check(notices[2].event == .notice(level: "success", key: "credits.restored", cleared: false) && notices[2].text == "✓ Credit access restored",
          "notices. the access back: a card of its own, not cleared")
    check(after.first == ["status-notice-credits.usage"] && after.allSatisfy { Set($0).count == $0.count },
          "notices. never two cards for one key along the way: \(after)")
    // the same frames again, all of them (the gateway drops a frame it has seen by its seq: Gateway+Replay.swift;
    // one that came twice all the same): no other card, and each ends as it did
    let before = Dictionary(uniqueKeysWithValues: kept(s).map { ($0.id, ($0.text, $0.event)) })
    for f in frames("credits") { take(s, f) }
    let replayed = Dictionary(uniqueKeysWithValues: kept(s).map { ($0.id, ($0.text, $0.event)) })
    check(kept(s).count == 3 && Set(replayed.keys) == Set(before.keys)
          && before.allSatisfy { replayed[$0.key]?.0 == $0.value.0 && replayed[$0.key]?.1 == $0.value.1 },
          "notices. the same frames again: the same cards, saying the same")
    // a show of the same key and words it already shows changes nothing; new words move it to where they came
    var notes = kept(s)
    let same = ChatItem(id: "status-notice-credits.restored", role: .card, at: Date().addingTimeInterval(60),
                        text: "✓ Credit access restored", event: .notice(level: "success", key: "credits.restored", cleared: false))
    StatusNotes.keep(same, in: &notes, limit: 30)
    check(notes == kept(s), "notices. the same key and words again: unchanged")
    var moved = notes
    StatusNotes.keep(ChatItem(id: "status-notice-credits.usage", role: .card, at: Date().addingTimeInterval(60), text: "• 用了一半",
                              event: .notice(level: "info", key: "credits.usage", cleared: false)), in: &moved, limit: 30)
    check(moved.map(\.id) == notes.map(\.id).filter { $0 != "status-notice-credits.usage" } + ["status-notice-credits.usage"]
          && moved.last?.text == "• 用了一半" && moved.last?.event == .notice(level: "info", key: "credits.usage", cleared: false),
          "notices. the key again with new words: its card takes them, at the end, not settled")
    // a notice without a key: its own card, by its frame
    let t = AppStore()
    take(t, frame("notification.show", ["text": "注意（CI）", "level": "warn", "kind": "ttl"], seq: 3))
    take(t, frame("notification.show", ["text": "注意（CI）", "level": "warn", "kind": "ttl"], seq: 3))
    take(t, frame("notification.show", ["text": "注意（CI）", "level": "warn", "kind": "ttl"], seq: 9))
    check(kept(t).count == 2, "notices. without a key: one card a frame, the same frame once")
    take(t, frame("notification.clear", ["key": "credits.usage"]))
    check(kept(t).count == 2, "notices. a clear for a key no card has: nothing")
    // the whole of what a short line stands for (the low-disk question: hermes_cli/prune_advisor.py
    // notice_payload): under the line, as the official client's toast unfolds it
    let u = AppStore()
    take(u, frame("notification.show", ["text": "⚠ Low disk (3.1 GB free) · /autoprune on|off|later", "level": "warn",
                                        "kind": "sticky", "key": "disk.autoprune", "id": "disk.autoprune",
                                        "detail": "Hermes can prune old sessions.\nReply /autoprune on, off or later."], seq: 20))
    check(kept(u).first?.text == "⚠ Low disk (3.1 GB free) · /autoprune on|off|later\n\nHermes can prune old sessions.\nReply /autoprune on, off or later.",
          "notices. a notice's detail: under its line: \(kept(u).first?.text ?? "")")
}

do {
    let s = AppStore()
    for f in frames("fallback") { take(s, f) }
    let cards = kept(s)
    check(cards.count == 1 && cards.first?.event == .fallback
          && cards.first?.text == "⚠️ Model fallback: mock-model via custom unavailable (model not found); using mock-fallback via custom.",
          "fallback. the switch Hermes said: one card, kept, in its words: \(cards.map(\.text))")
    for f in frames("fallback") { take(s, f) }
    check(kept(s).count == 1, "fallback. replayed: the same card")
    check(states(s).isEmpty && !s.compacting(bot), "fallback. no compaction of it")
}

do {
    let s = AppStore()
    var during: [Int] = []
    var waitText: [String] = []
    for f in frames("provider wait") {
        take(s, f)
        let waits = shown(s).filter { $0.event == .providerWait }
        during.append(waits.count)
        if let text = waits.first?.text, waitText.last != text { waitText.append(text) }
    }
    check(during.contains(1) && during.allSatisfy { $0 <= 1 }, "wait. one card while Hermes waits on the provider, never two")
    check(waitText == ["⏳ waiting on mock-model — 60s waiting for the first stream chunk (auto-reconnect: stream stale watchdog in 840s)"],
          "wait. in Hermes's words: \(waitText)")
    check(during.last == 0, "wait. gone once the reply came and the turn ended")
    check(kept(s).isEmpty, "wait. nothing of it kept")
    // its words change in place; a reply's words end it; the spinner's face ends it
    let t = AppStore()
    take(t, frame("thinking.delta", ["text": "⏳ waiting on gpt-5 — 60s waiting for the first stream chunk"]))
    let id = shown(t).first { $0.event == .providerWait }?.id
    take(t, frame("thinking.delta", ["text": "⏳ still waiting on gpt-5 — 170s waiting for the first stream chunk"]))
    let again = shown(t).filter { $0.event == .providerWait }
    check(again.count == 1 && again.first?.id == id && again.first?.text.hasPrefix("⏳ still waiting") == true,
          "wait. new words: the same card, with them")
    take(t, frame("message.delta", ["text": "好"]))
    check(shown(t).allSatisfy { $0.event != .providerWait }, "wait. the reply goes on: gone")
    take(t, frame("thinking.delta", ["text": "⏳ waiting on gpt-5 — 60s waiting for the first stream chunk"]))
    take(t, frame("thinking.delta", ["text": "(°ロ°) synthesizing..."]))
    check(shown(t).allSatisfy { $0.event != .providerWait }, "wait. another thinking frame: gone")
    take(t, frame("thinking.delta", ["text": "⏳ waiting on gpt-5 — 60s waiting for the first stream chunk"]))
    take(t, frame("session.info", ["running": false]))
    check(shown(t).allSatisfy { $0.event != .providerWait }, "wait. nothing runs: gone")
}

do {
    let s = AppStore()
    for f in frames("btw") + frames("background") { take(s, f) }
    let cards = kept(s)
    check(cards.map(\.event) == [.aside(question: "顺便问一句（探测）"), .sideTask] && cards.allSatisfy { $0.text == "好（mock）。" },
          "side. the side question's answer with its question, the side task's answer: a card each, kept: \(cards.map(\.id))")
    check(cards.allSatisfy { $0.id.hasPrefix("status-task-") }, "side. each its task's card")
    for f in frames("btw") + frames("background") { take(s, f) }
    check(kept(s).count == 2, "side. said again: the same cards")
}

do {
    let s = AppStore()
    for f in frames("goal") { take(s, f) }
    let cards = kept(s)
    check(cards.count == 1 && cards.first?.event == .goal && cards.first?.text == "✓ Goal achieved: 那句话写好了（mock 裁判）。",
          "goal. Hermes's verdict after the turn: one card, kept, in its words: \(cards.map(\.text))")
    for f in frames("goal") { take(s, f) }
    check(kept(s).count == 1, "goal. replayed: the same card")
}

do {
    // a frame a server did not number: the same words within five minutes are the same frame
    let s = AppStore()
    take(s, status("goal", "↻ Continuing toward goal (1/20): 还没写完"))
    take(s, status("goal", "↻ Continuing toward goal (1/20): 还没写完"))
    check(kept(s).count == 1, "unnamed. the same goal line again: one card")
    var notes = kept(s)
    let later = Date().addingTimeInterval(StatusNotes.saidAgain + 1)
    if let card = StatusNotes.card("status.update", ["kind": "goal", "text": "↻ Continuing toward goal (1/20): 还没写完"], frame: nil, at: later) {
        StatusNotes.keep(card, in: &notes, limit: 30)
    }
    check(notes.count == 2, "unnamed. the same words later: another card")
    // the kept cards are bounded, the newest stay
    let t = AppStore()
    for n in 0..<40 { take(t, status("goal", "↻ Continuing toward goal (\(n)/40)", seq: n + 1)) }
    check(kept(t).count == AppStore.notesKept && kept(t).last?.text == "↻ Continuing toward goal (39/40)",
          "kept. at most \(AppStore.notesKept), the newest")
}

do {
    // Hermes resuming a turn a crash or a restart cut off (tui_gateway/session_auto_continue.py: a process
    // line, then the turn's start): a card of its own, kept; another process line is NoticeCards'
    let s = AppStore()
    take(s, status("process", "Resuming interrupted turn…", seq: 70))
    take(s, frame("message.start", [:], seq: 71))
    let cards = kept(s)
    check(cards.count == 1 && cards.first?.event == .resumed && cards.first?.text == "Resuming interrupted turn…"
          && cards.first?.id == "status-e1-70",
          "resumed. Hermes resumes an interrupted turn: one card, kept, in its words: \(cards.map(\.text))")
    take(s, status("process", "Resuming interrupted turn…", seq: 70))
    check(kept(s).count == 1, "resumed. replayed: the same card")
    take(s, status("process", "Resuming interrupted turn…", seq: 90))
    check(kept(s).count == 2, "resumed. another time: another card")
    check(ChatEvent.resumed.startsTurn == false, "resumed. its card starts no turn of its own (the turn's start comes next)")
}

do {
    // what is no card: the board's word (NoticeCards'), other lines, a compaction's
    let s = AppStore()
    for f in [status("process", "✔ [default] @study Kanban t_1 done — 归档"), status("lifecycle", "Resuming after idle"),
              status("warn", "⚠ Context is over the compression threshold"), status("loop", "loop tick"),
              status("heartbeat", "♥ heartbeat #2 firing…"), status("compacting", summarizing), status("compacted", done),
              frame("btw.complete", ["task_id": "btw_1", "question": "?", "text": "  "])] {
        take(s, f)
    }
    check(kept(s).isEmpty, "none. the board's word, lifecycle, warn, loop, heartbeat, a compaction, an empty answer: nothing kept")
    // kept cards stand among the rows by their time
    let now = Date()
    s.chats[bot] = [ChatItem(id: "row-1", role: .user, at: now.addingTimeInterval(-10), text: "早"),
                    ChatItem(id: "row-2", role: .assistant, at: now.addingTimeInterval(10), text: "晚")]
    take(s, status("goal", "✓ Goal achieved: 写好了", seq: 50))
    let order = shown(s).map(\.id)
    check(order.firstIndex(of: "row-1")! < order.firstIndex(of: "status-e1-50")! && order.firstIndex(of: "status-e1-50")! < order.firstIndex(of: "row-2")!,
          "placing. a kept card stands between the rows by its time: \(order)")
}

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
