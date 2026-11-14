import Foundation

// The notice cards' rules, checked away from a Mac: the app's own NoticeCards.swift and
// Notices.swift, compiled in as they are (run.sh; ChatEvent is cut out of Models.swift, which
// needs SwiftUI for its other types), driven the way AppStore+Events.swift drives them. A frame's
// notices become cards under NoticeCards.id(...), a row's under its row id (the first card under
// the id, the others under "<id>-cardN": AppStore.noticeCards), and a page of rows is put into the
// chat with NoticeCards.put(page:). Each check prints ok or FAIL; the run fails on any FAIL.
//
// What is covered: issue #2's R14 and R18, the placing of a notice only its row says, the second
// review's RR08 to RR11, and that what came live is matched by the row its turn's end named. Last,
// the third review's R3-05: how far up the store reads for a turn's notice, with the store's own
// AppStore.followNotices (cut from its file by extract.py, against stubs.swift).

typealias Item = NoticeCards.Held


/// The row a page's item is, from its id, as AppStore.rowNumber reads it.
func number(_ id: String) -> Int? {
    id.hasPrefix("row-") ? Int(id.dropFirst(4).prefix { $0.isNumber }) : nil
}

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String, line: Int = #line) {
    print((ok ? "ok    " : "FAIL  ") + what + (ok ? "" : "  (line \(line))"))
    if !ok { failures += 1 }
}

struct Chat {
    var items: [Item] = []
    var replies = 0

    private func cards(_ notices: [Notices.Notice], id: String, at: Date) -> [Item] {
        notices.enumerated().map { index, notice in
            Item(id: index == 0 ? id : "\(id)-card\(index + 1)", event: notice.event, text: notice.text, at: at)
        }
    }

    /// status.update, kind process (AppStore.noteStatus)
    mutating func status(_ text: String, at now: Date) {
        let notices = Notices.read(text, kind: nil, display: nil).filter { $0.event == .board }
        for card in cards(notices, id: NoticeCards.id(.told), at: now) {
            NoticeCards.tell(card, in: &items) { $0 }
        }
    }

    /// message.start with the turn's text (AppStore.noteTurnStart), then the reply's bubble
    mutating func start(_ text: String, kind: String? = nil, at now: Date) {
        for card in cards(Notices.read(text, kind: kind, display: nil), id: NoticeCards.id(.begun), at: now) {
            NoticeCards.begin(card, in: &items) { $0 }
        }
        reply(at: now)
    }

    /// what a turn puts out: an item that is no event's card
    mutating func reply(at now: Date) {
        replies += 1
        items.append(Item(id: "reply-\(replies)", event: nil, text: "reply \(replies)", at: now))
    }

    /// rows of the transcript, read while the chat is open (AppStore.followNotices)
    mutating func rows(_ rows: [(id: Int, text: String, kind: String?, at: Date)]) {
        let page = rows.flatMap { row in
            cards(Notices.read(row.text, kind: row.kind, display: nil), id: "row-\(row.id)", at: row.at).map { card -> Item in
                var card = card
                card.role = "card"
                card.stored = true
                card.row = number(card.id)
                return card
            }
        }
        NoticeCards.put(page: page, in: &items) { $0 }
    }

    var notices: [Item] { items.filter { $0.event != nil } }
    var order: String { items.map { $0.event == nil ? $0.id : ($0.stage == nil ? $0.id : "live") }.joined(separator: " ") }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let done = "✔ [study] @study Kanban t_ab12 done — Finish the paper\nReady to read"
let peer = "Message from 🤖 课程 (@study): 收到"

// 1. an hour-old notice, replayed after a reconnect, and its stored row: one card, at the row's time
do {
    var chat = Chat()
    chat.items.append(Item(id: "row-1", event: nil, text: "before the drop", at: now.addingTimeInterval(-7200)))
    chat.status(done, at: now)
    chat.start(done, at: now)
    check(chat.notices.count == 1, "1. a replayed status line and turn start are one card")
    chat.rows([(10, done, nil, now.addingTimeInterval(-3600))])
    check(chat.notices.count == 1, "1. replayed an hour later, with its row: one card, not two")
    check(chat.notices.first?.id == "row-10", "1. the card is the row's")
    check(chat.notices.first?.at == now.addingTimeInterval(-3600), "1. the card has the row's time, an hour before")
    check(chat.order == "row-1 row-10 reply-1", "1. it stays ahead of the reply it started: \(chat.order)")
    chat.rows([(10, done, nil, now.addingTimeInterval(-3600))])
    check(chat.notices.count == 1, "1. the row read again changes nothing")
}

// 2. two rows saying the same, 120 s apart: two cards
do {
    var chat = Chat()
    chat.rows([(20, peer, nil, now.addingTimeInterval(-300)), (22, peer, nil, now.addingTimeInterval(-180))])
    check(chat.notices.map(\.id) == ["row-20", "row-22"], "2. two rows of the same words are two cards: \(chat.order)")
}

// 3. the same notice live, twice, each with its turn; then both rows
do {
    var chat = Chat()
    chat.start(peer, at: now)
    chat.start(peer, at: now.addingTimeInterval(120))
    check(chat.notices.count == 2, "3. the same words live in two turns are two cards")
    check(chat.order == "live reply-1 live reply-2", "3. each ahead of its own reply: \(chat.order)")
    chat.rows([(30, peer, nil, now.addingTimeInterval(1)), (32, peer, nil, now.addingTimeInterval(121))])
    check(chat.notices.map(\.id) == ["row-30", "row-32"], "3. each row takes one card's place: \(chat.order)")
    check(chat.order == "row-30 reply-1 row-32 reply-2", "3. and keeps its place: \(chat.order)")
}

// 3b. the same, replayed together (every frame dated the moment of the replay) with a board notice
do {
    var chat = Chat()
    chat.status(done, at: now)
    chat.start(done, at: now)
    chat.start(peer, at: now)
    chat.start(peer, at: now)
    check(chat.notices.count == 3, "3b. three notices replayed at once are three cards")
    chat.rows([(40, done, nil, now.addingTimeInterval(-3600)), (42, peer, nil, now.addingTimeInterval(-1800)),
               (44, peer, nil, now.addingTimeInterval(-1680))])
    check(chat.order == "row-40 reply-1 row-42 reply-2 row-44 reply-3", "3b. rows in their cards' places: \(chat.order)")
    check(chat.notices.map(\.at) == [-3600, -1800, -1680].map { now.addingTimeInterval($0) }, "3b. each with its row's time")
}

// 4. live first, then the transcript (the usual order), with the row's clock a little ahead of the Mac's
do {
    var chat = Chat()
    chat.status(done, at: now)
    check(chat.notices.count == 1 && chat.notices[0].stage == .told, "4. told ahead of its turn: one card")
    chat.start(done, at: now.addingTimeInterval(1))
    check(chat.notices.count == 1 && chat.notices[0].stage == .begun, "4. its turn begins: the same card, begun")
    chat.rows([(50, done, nil, now.addingTimeInterval(4))])
    check(chat.order == "row-50 reply-1", "4. the row takes its place, ahead of the reply, whatever the clocks say: \(chat.order)")
}

// 4b. told, and the turn's start says nothing (a server whose message.start has no text): the row takes the told card's place
do {
    var chat = Chat()
    chat.status(done, at: now)
    chat.reply(at: now)
    chat.rows([(52, done, nil, now)])
    check(chat.order == "row-52 reply-1", "4b. a row takes the place of a card only told of: \(chat.order)")
}

// 5. the transcript first, then the frames of the same notice
do {
    var chat = Chat()
    chat.rows([(60, done, nil, now.addingTimeInterval(-2))])
    chat.status(done, at: now)
    check(chat.notices.count == 1, "5. the row is there, then the status line: still one card")
    chat.start(done, at: now)
    check(chat.notices.count == 1 && chat.order == "row-60 reply-1", "5. then the turn's start: still one, the row's: \(chat.order)")
    // the same words again once that turn has answered: a new notice
    chat.start(done, at: now.addingTimeInterval(60))
    check(chat.notices.count == 2, "5. the same words after that turn's reply are another notice")
}

// 6. told, then waiting more than five minutes behind another turn: one card, where its turn begins
do {
    var chat = Chat()
    chat.items.append(Item(id: "row-70", event: nil, text: "your question", at: now))
    chat.status(done, at: now.addingTimeInterval(5))
    chat.reply(at: now.addingTimeInterval(400))           // the turn under way goes on, and ends
    chat.start(done, at: now.addingTimeInterval(420))
    check(chat.notices.count == 1, "6. told seven minutes before its turn: one card")
    check(chat.order == "row-70 reply-1 live reply-2", "6. where its turn begins: \(chat.order)")
    chat.rows([(72, done, nil, now.addingTimeInterval(421))])
    check(chat.order == "row-70 reply-1 row-72 reply-2", "6. and the row in its place: \(chat.order)")
}

// 7. a status line twice within minutes is one card; the same line long after is another
do {
    var chat = Chat()
    let crashed = "✖ [study] @study Kanban t_ab12 worker crashed (pid gone); dispatcher will retry"
    chat.status(crashed, at: now)
    chat.status(crashed, at: now.addingTimeInterval(30))
    check(chat.notices.count == 1, "7. the same status line again half a minute later: one card")
    chat.status(crashed, at: now.addingTimeInterval(900))
    check(chat.notices.count == 2, "7. and a quarter of an hour later: another")
}

// 8. a notice of two lines is two cards, each replaced by its own
do {
    var chat = Chat()
    let two = "✔ [study] @study Kanban t_1 done — One\n⏸ [study] @study Kanban t_2 blocked: needs a password"
    chat.status(two, at: now)
    chat.start(two, at: now)
    check(chat.notices.count == 2, "8. two lines, told and begun: two cards")
    chat.rows([(80, two, nil, now.addingTimeInterval(-600))])
    check(chat.order == "row-80 row-80-card2 reply-1", "8. the row's two cards in their places: \(chat.order)")
}

// 9. a row with no card before it goes in by its time
do {
    var chat = Chat()
    chat.items.append(Item(id: "row-90", event: nil, text: "earlier", at: now.addingTimeInterval(-100)))
    chat.items.append(Item(id: "row-94", event: nil, text: "later", at: now))
    chat.rows([(92, peer, nil, now.addingTimeInterval(-50))])
    check(chat.order == "row-90 row-92 row-94", "9. a row nothing stood for goes in by its time: \(chat.order)")
}

// R18: what a notice still says of its card once the board no longer lists it
do {
    let read = Notices.read(done, kind: nil, display: nil)
    check(read.count == 1 && read[0].cardId == "t_ab12" && read[0].assignee == "study", "R18. the notice names its card and whose it was")
    check(read[0].cardTitle == "Finish the paper", "R18. a card done says its title: \(read[0].cardTitle ?? "nil")")
    let outcome = Notices.kanbanOutcome(done)
    check(outcome.words == "做完了" && outcome.detail == "Ready to read", "R18. and what was handed in")
    let blocked = Notices.read("⏸ @study Kanban t_9 blocked: needs a password", kind: nil, display: nil)
    check(blocked.first?.cardId == "t_9" && blocked.first?.cardTitle == nil, "R18. a card stopped says no title: its id is what is left")
    let untitled = Notices.read("✔ Kanban t_7 done — t_7", kind: nil, display: nil)
    check(untitled.first?.cardTitle == nil, "R18. Hermes's stand-in for a missing title (the id) is no title")
    let wrapped = Notices.read(done + "\n\n[INTERNAL NOTIFICATION — not written by a person]", kind: "internal_notification", display: nil)
    check(wrapped.first?.cardTitle == "Finish the paper", "R18. with Hermes's footer for the model: \(wrapped.first?.cardTitle ?? "nil")")
    let dashed = Notices.read("✔ [life] Kanban t_3 done — 报销 done — 第二季度", kind: nil, display: nil)
    check(dashed.first?.cardTitle == "报销 done — 第二季度", "R18. a title that itself says done: \(dashed.first?.cardTitle ?? "nil")")
}

// The gateway's board wake: no frame says what started the turn, only its row. The row's card goes
// where the transcript has it among the rows around it, whatever the clocks say.
do {
    let wake = "[kanban] Task t_ci_gone completed.\nTitle: 归档旧发票\nAssignee: @study\nBoard: study\n\nCheck the result or decide the next step.\nResult: 发票都归好了。"
    func said(_ id: String, _ role: String, _ text: String, _ at: Date) -> Item {
        Item(id: id, event: nil, text: text, at: at, role: role, stored: id.hasPrefix("row-"), row: number(id))
    }
    func card(_ id: String, at: Date) -> Item {
        let notice = Notices.read(wake, kind: "internal_notification", display: nil)[0]
        return Item(id: id, event: notice.event, text: notice.text, at: at, role: "card", stored: id.hasPrefix("row-"), row: number(id))
    }
    func order(_ items: [Item]) -> String { items.map(\.id).joined(separator: " ") }

    // W1. run 197: you asked, 好 came, then while away the wake's turn and its reply (replayed).
    // The live 好 is dated after the row here, as if the Mac took its frame late.
    var chat = [said("row-1", "assistant", "before", now.addingTimeInterval(-600)),
                said("live-u", "user", "断线：回传", now),
                said("live-a", "assistant", "好（CI）。", now.addingTimeInterval(2)),
                said("live-b", "assistant", "课程把旧发票归好了（CI）。", now.addingTimeInterval(3))]
    let page = [said("row-1", "assistant", "before", now.addingTimeInterval(-600)),
                said("row-2", "user", "断线：回传", now), said("row-3", "assistant", "好（CI）。", now.addingTimeInterval(0.5)),
                card("row-4", at: now.addingTimeInterval(1)),
                said("row-5", "assistant", "课程把旧发票归好了（CI）。", now.addingTimeInterval(6))]
    NoticeCards.put(page: page, in: &chat) { $0 }
    check(order(chat) == "row-1 live-u live-a row-4 live-b", "W1. under the reply before it, though that is dated later: \(order(chat))")
    var byTime = Array(chat.filter { $0.id != "row-4" })
    NoticeCards.put(page: [page[3]], in: &byTime) { $0 }
    check(order(byTime) == "row-1 live-u row-4 live-a live-b", "W1. by time alone it went above that reply (what run 197 showed): \(order(byTime))")
    NoticeCards.put(page: page, in: &chat) { $0 }
    check(chat.count == 5, "W1. read again: still one card")

    // W2. live, the server's clock ahead: the row is dated after the reply bubble its turn opened
    chat = [said("row-3", "assistant", "好（CI）。", now), said("live-s", "assistant", "", now.addingTimeInterval(1))]
    NoticeCards.put(page: [said("row-3", "assistant", "好（CI）。", now), card("row-4", at: now.addingTimeInterval(5))], in: &chat) { $0 }
    check(order(chat) == "row-3 row-4 live-s", "W2. ahead of the reply it started, with the server's clock ahead: \(order(chat))")

    // W3. the same words before and after it
    chat = [said("live-1", "assistant", "好", now), said("live-2", "assistant", "好", now.addingTimeInterval(3))]
    NoticeCards.put(page: [said("row-3", "assistant", "好", now), card("row-4", at: now.addingTimeInterval(9)),
                           said("row-5", "assistant", "好", now.addingTimeInterval(3))], in: &chat) { $0 }
    check(order(chat) == "live-1 row-4 live-2", "W3. between two replies that say the same: \(order(chat))")

    // W4. a row after it the chat does not have, with the words of something old: not up there
    chat = [said("row-0", "assistant", "收到", now.addingTimeInterval(-900)), said("row-3", "assistant", "好（CI）。", now)]
    NoticeCards.put(page: [said("row-3", "assistant", "好（CI）。", now), card("row-4", at: now.addingTimeInterval(-950)),
                           said("row-5", "assistant", "收到", now.addingTimeInterval(4))], in: &chat) { $0 }
    check(order(chat) == "row-0 row-3 row-4", "W4. old words like a later row's do not pull it up: \(order(chat))")

    // W5. what it stands before is yours (the next thing was a message of yours), not the assistant's
    chat = [said("row-3", "assistant", "好（CI）。", now), said("live-u", "user", "好（CI）。", now.addingTimeInterval(4))]
    NoticeCards.put(page: [said("row-3", "assistant", "好（CI）。", now), card("row-4", at: now.addingTimeInterval(9)),
                           said("row-5", "user", "好（CI）。", now.addingTimeInterval(4))], in: &chat) { $0 }
    check(order(chat) == "row-3 row-4 live-u", "W5. the same words from the other side are another item: \(order(chat))")

    // W6. none of its neighbours in the chat: by time, as before
    chat = [said("row-1", "assistant", "a", now), said("row-2", "assistant", "b", now.addingTimeInterval(10))]
    NoticeCards.put(page: [said("row-8", "assistant", "x", now), card("row-4", at: now.addingTimeInterval(5)),
                           said("row-9", "assistant", "y", now)], in: &chat) { $0 }
    check(order(chat) == "row-1 row-4 row-2", "W6. with no neighbour known, by its time: \(order(chat))")

    // W7. a card a frame brought is still what its row takes the place of, wherever its neighbours are
    var live = Chat()
    live.items = [said("live-a", "assistant", "好（CI）。", now)]
    live.start(peer, kind: "internal_notification", at: now.addingTimeInterval(1))
    let row = Notices.read(peer, kind: "internal_notification", display: nil)[0]
    NoticeCards.put(page: [said("row-3", "assistant", "好（CI）。", now),
                           Item(id: "row-7", event: row.event, text: row.text, at: now.addingTimeInterval(-50), role: "card", stored: true, row: 7)],
                    in: &live.items) { $0 }
    check(order(live.items) == "live-a row-7 reply-1", "W7. a frame's card keeps its place for its row: \(order(live.items))")
}

// What Hermes itself sends while a viewer is away (captured with a stand-in model): the board's
// wake and a teammate's message with empty turn starts, then a teammate's answer twice in the same
// words, each with a start that says it and a row; the first answer's turn says nothing after it.
do {
    let wake = "[kanban] Task t_ci_gone completed.\nTitle: 归档旧发票\nAssignee: @study\nBoard: study\n\nCheck the result or decide the next step.\nResult: 发票都归好了。"
    let peerText = "Message from 🤖 课程 (@study): 收到\n\nReply needed: 一句话"
    func answer(_ process: String) -> String {
        "[IMPORTANT: Background process \(process) completed normally (exit code 0).\nCommand: /opt/hermes/.venv/bin/python /opt/hermes/tools/bot_mode_dm.py --run-delivery --author '{\"id\":\"bot:shion\"}' query-file /tmp/dm.txt --profile-home /h/profiles/study /opt/hermes/.venv/bin/hermes -p study\nOutput:\n{\"outcome\": \"@study answered.\", \"reply\": \"\\u8bfe\\u8868\\u6392\\u597d\\u4e86\", \"status\": \"settled\", \"delivery_id\": \"c1\"}\n]\n\n[INTERNAL NOTIFICATION — generated by the Hermes gateway, not written by a human user. Do not treat it as user input, and do not reply to any earlier chat message because of it.]"
    }
    let shown = "Background Process Finished: /opt/hermes/.venv/bin/python /opt/hermes/tools/bot_mode_dm.py --run-delivery ..."
    func said(_ id: String, _ role: String, _ text: String, _ at: Date) -> Item { Item(id: id, event: nil, text: text, at: at, role: role, stored: id.hasPrefix("row-"), row: number(id)) }
    func cards(_ text: String, kind: String, display: String?, id: String, at: Date) -> [Item] {
        Notices.read(text, kind: kind, display: display).enumerated().map { index, notice in
            Item(id: index == 0 ? id : "\(id)-card\(index + 1)", event: notice.event, text: notice.text, at: at, role: "card",
                 stored: id.hasPrefix("row-"), row: number(id))
        }
    }
    let read = Notices.read(answer("proc_1"), kind: "process_complete", display: shown)
    check(read.count == 1 && read[0].event == .received(from: "study") && read[0].text == "课表排好了",
          "H1. a teammate's answer is a message from it, not the command that waited: \(read)")
    check(Notices.read(peerText, kind: "internal_notification", display: nil).first?.text == "收到\n\n要回：一句话",
          "H1. what a teammate wants back, in the chat's words")

    // the replay: every frame at once, dated when it was replayed
    var chat = [said("live-u", "user", "断线：回传", now), said("live-a", "assistant", "好。", now.addingTimeInterval(1))]
    let replayed = now.addingTimeInterval(4)
    chat.append(said("live-r1", "assistant", "发票的事知道了。", replayed))                // the wake's turn: its start says nothing
    chat.append(said("live-r2", "assistant", "知道课程收到了。", replayed))                // the message's turn: nor does its
    for card in cards(answer("proc_1"), kind: "process_complete", display: shown, id: NoticeCards.id(.begun), at: replayed) {
        NoticeCards.begin(card, in: &chat) { $0 }                                      // the first answer: nothing said after it
    }
    for card in cards(answer("proc_2"), kind: "process_complete", display: shown, id: NoticeCards.id(.begun), at: replayed) {
        NoticeCards.begin(card, in: &chat) { $0 }
    }
    chat.append(said("live-r4", "assistant", "课表的事知道了。", replayed))
    check(chat.filter { $0.event != nil }.count == 2, "H2. the same answer twice, as frames: two cards")

    // the page read after it: rows in the transcript's order, each dated as Hermes stored it
    let page: [Item] = [said("row-1", "user", "断线：回传", now), said("row-2", "assistant", "好。", now.addingTimeInterval(1))]
        + cards(wake, kind: "internal_notification", display: nil, id: "row-3", at: now.addingTimeInterval(2))
        + [said("row-4", "assistant", "发票的事知道了。", now.addingTimeInterval(7))]
        + cards(peerText, kind: "internal_notification", display: nil, id: "row-5", at: now.addingTimeInterval(-130))
        + [said("row-6", "assistant", "知道课程收到了。", now.addingTimeInterval(-125))]
        + cards(answer("proc_1"), kind: "process_complete", display: shown, id: "row-7", at: now.addingTimeInterval(-3600))
        + cards(answer("proc_2"), kind: "process_complete", display: shown, id: "row-9", at: now.addingTimeInterval(-5))
        + [said("row-10", "assistant", "课表的事知道了。", now)]
    for _ in 0..<2 {
        NoticeCards.put(page: page, in: &chat) { $0 }
    }
    let order = chat.map(\.id).joined(separator: " ")
    check(order == "live-u live-a row-3 live-r1 row-5 live-r2 row-7 row-9 live-r4",
          "H3. each card where the transcript has it, the rows in place of the frames' cards: \(order)")
    check(chat.first { $0.id == "row-7" }?.at == now.addingTimeInterval(-3600), "H3. an answer's card has its row's time, an hour before")
}

// The second review's findings on rows and cards (RR08–RR11), as it gave them.
do {
    func said(_ id: String, _ role: String, _ text: String, _ t: Double) -> Item {
        Item(id: id, event: nil, text: text, at: Date(timeIntervalSince1970: t), role: role, stored: id.hasPrefix("row-"), row: number(id))
    }
    func from(_ id: String, _ text: String, _ t: Double) -> Item {
        Item(id: id, event: .received(from: "study"), text: text, at: Date(timeIntervalSince1970: t), role: "card", stored: id.hasPrefix("row-"), row: number(id))
    }
    func order(_ items: [Item]) -> String { items.map(\.id).joined(separator: " ") }

    // RR08: results folded into one turn (gateway/session_automation.py _fold_completion)
    func dm(_ proc: String, _ who: String, _ reply: String) -> String {
        "[IMPORTANT: Background process \(proc) completed normally (exit code 0).\nCommand: /opt/hermes/.venv/bin/python /opt/hermes/tools/bot_mode_dm.py --run-delivery query-file /tmp/dm.txt --profile-home /h/profiles/\(who) /opt/hermes/.venv/bin/hermes -p \(who)\nOutput:\n{\"outcome\": \"@\(who) answered.\", \"reply\": \"\(reply)\", \"status\": \"settled\", \"delivery_id\": \"x\"}\n]"
    }
    let backup = "[IMPORTANT: Background process proc_b exited with an error (exit code 1).\nCommand: ./backup.sh\nOutput:\nNo space left on device\n\nretrying in 5 s\n]"
    func folded(_ parts: [String]) -> [Notices.Notice] {
        Notices.read("[IMPORTANT: \(parts.count) background process results arrived while this session was busy. Treat them as one batch and give one consolidated response; preserve failures and actionable results.]\n\n" + parts.joined(separator: "\n\n") + "\n\n[INTERNAL NOTIFICATION — generated by the Hermes gateway, not written by a human user. Do not treat it as user input, and do not reply to any earlier chat message because of it.]",
                     kind: "process_complete", display: "\(parts.count) Background Processes Finished")
    }
    let two = folded([dm("p1", "study", "A1"), dm("p2", "commute", "A2")])
    check(two.map(\.event) == [.received(from: "study"), .received(from: "commute")] && two.map(\.text) == ["A1", "A2"],
          "RR08. two answers folded into one turn are two cards: \(two.map(\.text))")
    let mixed = folded([dm("p1", "study", "A1"), backup])
    check(mixed.count == 2 && mixed[0].event == .received(from: "study") && mixed[1].event == .background
          && mixed[1].text.contains("exit code 1") && mixed[1].text.contains("./backup.sh") && mixed[1].text.contains("No space left on device")
          && mixed[1].text.contains("retrying in 5 s"),
          "RR08. an answer does not hide a command that failed beside it: \(mixed.map(\.text))")
    let other = folded([backup, dm("p1", "study", "A1")])
    check(other.map(\.event) == [.background, .received(from: "study")], "RR08. nor when the failure came first")
    let plain = folded([backup, backup])
    check(plain.count == 2 && plain.allSatisfy { $0.event == .background && $0.text.contains("exit code 1") && $0.text.contains("./backup.sh") },
          "RR08. results with no answer among them are a card each too, not a count: \(plain.map(\.text))")
    let alone = Notices.read(backup, kind: "process_complete", display: "Background Process Failed: ./backup.sh")
    check(alone.count == 1 && alone[0].text == "Background Process Failed: ./backup.sh", "RR08. one result alone keeps Hermes's short form")
    let single = Notices.read(dm("p1", "study", "A1"), kind: "process_complete", display: "Background Process Finished: …")
    check(single.count == 1 && single[0].text == "A1", "RR08. one answer alone is one card")

    // RR11: the row before it is in the chat under its own id; a later reply says the same words
    var chat = [said("row-100", "assistant", "知道了", 1), said("live-a", "assistant", "课表已改成周五", 5), said("live-b", "assistant", "知道了", 9)]
    NoticeCards.put(page: [said("row-100", "assistant", "知道了", 1), from("row-101", "把课换到周五", 2),
                           said("row-102", "assistant", "课表已改成周五", 3), said("row-104", "assistant", "知道了", 7)], in: &chat) { $0 }
    check(order(chat) == "row-100 row-101 live-a live-b", "RR11. ahead of the reply it started, a later reply in an earlier row's words notwithstanding: \(order(chat))")
    // and with the later row not on the page: the row's own id still holds the place
    chat = [said("row-100", "assistant", "知道了", 1), said("live-a", "assistant", "课表已改成周五", 5), said("live-b", "assistant", "知道了", 9)]
    NoticeCards.put(page: [said("row-100", "assistant", "知道了", 1), from("row-101", "把课换到周五", 2)], in: &chat) { $0 }
    check(order(chat) == "row-100 row-101 live-a live-b", "RR11. behind the row before it by that row's id: \(order(chat))")

    // RR10: eight turns in the same words came as frames; the newest page has the last six, a page further up the rest
    chat = []
    for n in 1...8 {
        NoticeCards.begin(from(NoticeCards.id(.begun), "收到", 100), in: &chat) { $0 }
        chat.append(said("reply-\(n)", "assistant", "回复\(n)", 100))
    }
    func rows(_ range: ClosedRange<Int>) -> [Item] {
        range.flatMap { n in [from("row-\(2 * n - 1)", "收到", Double(2 * n)), said("row-\(2 * n)", "assistant", "回复\(n)", Double(2 * n) + 0.5)] }
    }
    let newest = NoticeCards.put(page: rows(3...8), in: &chat) { $0 }
    check(newest.settled == 6 && newest.added == 0, "RR10. the newest page's six rows are six of the cards: \(newest)")
    check(chat.filter { $0.stage == .begun }.count == 2 && chat.prefix(4).filter { $0.stage == .begun }.count == 2,
          "RR10. the two cards left without a row are the oldest two")
    let older = NoticeCards.put(page: rows(1...2), in: &chat, above: newest.top) { $0 }
    let cards = chat.filter { $0.event != nil }
    check(cards.map(\.id) == ["row-1", "row-3", "row-5", "row-7", "row-9", "row-11", "row-13", "row-15"],
          "RR10. every card is the row of its own turn: \(cards.map(\.id))")
    check(cards.map { Int($0.at.timeIntervalSince1970) } == [2, 4, 6, 8, 10, 12, 14, 16], "RR10. and has that row's time")
    check(older.settled == 2 && order(chat).hasPrefix("row-1 reply-1 row-3 reply-2 row-5 reply-3"), "RR10. each ahead of its own reply: \(order(chat))")
    // the whole page again changes nothing
    let again = NoticeCards.put(page: rows(1...8), in: &chat) { $0 }
    check(again.added == 0 && again.settled == 0 && chat.count == 16, "RR10. read again, nothing moves")

    // RR09: eight turns whose starts said nothing (a teammate's messages): only rows say them
    chat = [said("row-90", "assistant", "之前", 0)]
    for n in 1...8 { chat.append(said("reply-\(n)", "assistant", "回复\(n)", 100)) }
    var read: [Int] = []
    let first = NoticeCards.put(page: rows(3...8), in: &chat) { $0 }
    read += Array(5...16)
    check(first.added == 6, "RR09. the newest twelve rows give six cards")
    check(NoticeCards.readsFurther(for: 1, read: read, pages: 1, awaiting: false), "RR09. the row the first turn began with is not among them: read further up")
    check(!NoticeCards.readsFurther(for: 15, read: read, pages: 1, awaiting: false), "RR09. the last turn's row is: nothing more to read for it")
    let rest = NoticeCards.put(page: [said("row-90", "assistant", "之前", 0)] + rows(1...2), in: &chat, above: first.top) { $0 }
    read += [90, 1, 2, 3, 4]
    check(rest.added == 2 && !NoticeCards.readsFurther(for: 1, read: read, pages: 2, awaiting: false), "RR09. a page further up has the rest, and the row was read")
    check(order(chat) == "row-90 row-1 reply-1 row-3 reply-2 row-5 reply-3 row-7 reply-4 row-9 reply-5 row-11 reply-6 row-13 reply-7 row-15 reply-8",
          "RR09. all eight notices, each ahead of the reply it started: \(order(chat))")
    check(!NoticeCards.readsFurther(for: nil, read: read, pages: 1, awaiting: false) && NoticeCards.readsFurther(for: nil, read: read, pages: 1, awaiting: true)
          && !NoticeCards.readsFurther(for: nil, read: read, pages: 2, awaiting: true), "RR09. a card without a row is worth one more page, no more")
    check(NoticeCards.readsFurther(for: 1, read: Array(700...1000), pages: 40, awaiting: false), "RR09. however many pages it takes: the row is looked for until it was read")

    // words said long before are not a row of this page: beyond what the page can reach
    chat = [said("old", "assistant", "收到", 0)] + (1...30).map { said("mid-\($0)", "assistant", "别的\($0)", 1) } + [said("live-p", "assistant", "好", 50)]
    NoticeCards.put(page: [said("row-3", "assistant", "好", 50), from("row-4", "带个话", 51), said("row-5", "assistant", "收到", 52)], in: &chat) { $0 }
    check(order(chat).hasSuffix("live-p row-4") && chat.first?.id == "old", "reach. a later row's words said long before do not pull the card up there: …\(order(chat).suffix(22))")
}

// What came live is the row its turn's end named, whatever it says (ChatControl.storedRows).
do {
    func live(_ id: String, _ role: String, _ text: String, _ t: Double, row: Int? = nil) -> Item {
        Item(id: id, event: nil, text: text, at: Date(timeIntervalSince1970: t), role: role, row: row)
    }
    func page(_ n: Int, _ role: String, _ text: String, _ t: Double) -> Item {
        Item(id: "row-\(n)", event: nil, text: text, at: Date(timeIntervalSince1970: t), role: role, stored: true, row: n)
    }
    func card(_ id: String, _ text: String, _ t: Double, row: Int? = nil) -> Item {
        Item(id: id, event: .received(from: "study"), text: text, at: Date(timeIntervalSince1970: t), role: "card",
             stored: id.hasPrefix("row-"), row: row ?? number(id))
    }
    func order(_ items: [Item]) -> String { items.map { $0.stage == nil ? $0.id : "frame" }.joined(separator: " ") }

    // two cards in the same words came as frames; the first turn is over (its end named row 1) and said nothing
    // after it, the second is under way. The page has only the first one's row
    let first = NoticeCards.id(.begun), second = NoticeCards.id(.begun)
    var chat = [card(first, "收到", 100, row: 1), card(second, "收到", 101)]
    NoticeCards.put(page: [card("row-1", "收到", 1)], in: &chat) { $0 }
    check(chat.map(\.id) == ["row-1", second], "ID1. the row is the card its own turn made, not the newer one in the same words: \(chat.map(\.id))")

    // eight turns in the same words, all over: any page gives each row to its own card
    chat = []
    var frames: [String] = []
    for n in 1...8 {
        frames.append(NoticeCards.id(.begun))
        chat.append(card(frames[n - 1], "收到", 100, row: 2 * n - 1))
        chat.append(live("reply-\(n)", "assistant", "好", 100, row: 2 * n))
    }
    NoticeCards.put(page: [card("row-5", "收到", 6), page(6, "assistant", "好", 6.5), card("row-7", "收到", 8), page(8, "assistant", "好", 8.5)], in: &chat) { $0 }
    check(chat[4].id == "row-5" && chat[6].id == "row-7" && chat.filter { $0.stage != nil }.count == 6,
          "ID2. rows from the middle of the transcript go to the third and fourth cards: \(order(chat))")
    NoticeCards.put(page: (1...8).flatMap { [card("row-\(2 * $0 - 1)", "收到", Double(2 * $0)), page(2 * $0, "assistant", "好", Double(2 * $0) + 0.5)] }, in: &chat) { $0 }
    check(chat.filter { $0.event != nil }.map(\.id) == (1...8).map { "row-\(2 * $0 - 1)" } && chat.count == 16,
          "ID2. and the whole page leaves each card its own row, the replies all saying the same: \(order(chat))")

    // a notice only its row says, between replies that all say the same and are known rows
    chat = [live("a", "assistant", "知道了", 1, row: 100), live("b", "assistant", "知道了", 5, row: 102), live("c", "assistant", "知道了", 9, row: 104)]
    NoticeCards.put(page: [page(100, "assistant", "知道了", 1), card("row-101", "带个话", 2), page(102, "assistant", "知道了", 3),
                           card("row-103", "再带个话", 4), page(104, "assistant", "知道了", 7)], in: &chat) { $0 }
    check(chat.map(\.id) == ["a", "row-101", "b", "row-103", "c"], "ID3. each ahead of the reply it started, though every reply says the same: \(chat.map(\.id))")

    // an item known to be another row is not this row, whatever it says
    chat = [live("a", "assistant", "好", 1, row: 50), live("u", "user", "继续", 2), live("s", "assistant", "", 3)]
    NoticeCards.put(page: [page(60, "assistant", "好", 1), card("row-61", "带个话", 2)], in: &chat) { $0 }
    check(chat.map(\.id) == ["a", "u", "row-61", "s"],
          "ID4. a reply known to be row 50 does not stand for row 60: \(chat.map(\.id))")
}

// R3-05: a turn Hermes started itself has the store read the transcript for what started it
// (AppStore.followNotices): the newest 12 rows, then 50 at a time further up until the row the
// turn's end names was read or passed. Hermes gives a tool call's row its call's id and no row_id,
// so a page can hold rows and no row number: that is not the top.

let bot = "shion", session = "sess-shion"
let peerDM = "Message from 🤖 课程 (@study): 收到（CI）"

/// A transcript as Hermes stores it, oldest first, and pages it newest first
/// (gateway/session_stored_reads.py read_page): `limit` stored rows a page, and more while the
/// oldest of them is a tool's result, which stays on the page of the call that made it. A page
/// shows what tui_gateway/session_history.py _history_to_messages makes of its rows: a tool's
/// result under its call's id with no row_id, nothing of an assistant's row with no words (one that
/// only made calls). A stretch that shows nothing is read past, so only the top can be empty; past
/// the oldest page there is no cursor.
final class Transcript {
    struct Row {
        var id: Int
        var role: String
        var text = ""
        var kind: String?
        var display: String?
        /// a tool's result: the call it answers
        var call: String?

        var shown: JSONValue? {
            let at = JSONValue.number(Double(1_800_000_000 + id))
            if role == "tool" {
                return ["row_kind": "message", "role": "tool", "name": "terminal", "context": "make",
                        "tool_call_id": .string(call ?? ""), "timestamp": at]
            }
            guard !text.isEmpty else { return nil }
            var row: [String: JSONValue] = ["row_kind": "message", "role": .string(role), "text": .string(text),
                                            "row_id": .number(Double(id)), "timestamp": at]
            if let kind { row["display_kind"] = .string(kind) }
            if let display { row["display_metadata"] = ["display_text": .string(display)] }
            return .object(row)
        }
    }

    var rows: [Row] = []
    /// The row of what started the turn, as the turn's end names it (stored or not).
    let notice: Int
    /// The turn's tool calls, oldest first, and its reply.
    var calls: [String] = []
    let replied: String
    /// The pages it gave, in order.
    var given: [JSONValue] = []

    /// `before` rows of conversation, then a turn Hermes started itself with `text` (stored as a
    /// row unless `kept` is false: gone since), which made `tools` tool calls and then replied
    /// `reply` (no words: a row that shows nothing).
    init(before: Int = 0, text: String = peerDM, kind: String = "internal_notification", display: String? = nil,
         kept: Bool = true, tools: Int, reply: String) {
        notice = before + 1
        replied = reply
        for n in 1..<notice {
            rows.append(Row(id: n, role: n % 2 == 1 ? "user" : "assistant", text: "第 \(n) 条"))
        }
        if kept {
            rows.append(Row(id: notice, role: "user", text: text, kind: kind, display: display))
        }
        for k in 0..<tools {
            calls.append("call-\(k + 1)")
            rows.append(Row(id: notice + 2 * k + 1, role: "assistant"))
            rows.append(Row(id: notice + 2 * k + 2, role: "tool", call: calls[k]))
        }
        rows.append(Row(id: notice + 2 * tools + 1, role: "assistant", text: reply))
    }

    /// The reply's row.
    var reply: Int { notice + 2 * calls.count + 1 }

    /// The chat at the turn's end, as it came live: a line for each tool call, under the id the
    /// transcript gives its row, and the reply's bubble, which the end named as its row.
    var chat: [ChatItem] {
        let at = Date(timeIntervalSince1970: 1_900_000_000)
        return calls.map { ChatItem(id: "tool-\($0)", role: .tool, at: at, text: "terminal") }
            + (replied.isEmpty ? [] : [ChatItem(id: "live-reply", role: .assistant, at: at, text: replied)])
    }

    /// `session.transcript` with `order: latest`: one page.
    func page(_ params: JSONValue) -> JSONValue {
        let limit = params["limit"]?.int ?? 100
        // a cursor says where the page before it began
        var end = params["cursor"]?.string.flatMap { Int($0.dropFirst("before-".count)) } ?? rows.count
        while true {
            var start = max(0, end - limit)
            while start > 0, rows[start].role == "tool" { start -= 1 }
            let shown = rows[start..<end].compactMap(\.shown)
            if !shown.isEmpty || start == 0 {
                given.append(["rows": .array(shown), "next_cursor": start > 0 ? .string("before-\(start)") : .null])
                return given[given.count - 1]
            }
            end = start
        }
    }

    /// The pages it gave: how many rows each showed, how many of them with a row_id, and whether
    /// it had a cursor.
    var shapes: [String] {
        given.map { page in
            let rows = page["rows"]?.array ?? []
            return "\(rows.count) rows, \(rows.compactMap { $0["row_id"]?.int }.count) numbered, "
                + (page["next_cursor"]?.string == nil ? "the top" : "a cursor")
        }
    }
}

/// Rows of conversation as a page shows them, under these row ids.
func numbered(_ ids: ClosedRange<Int>) -> JSONValue {
    .array(ids.map { ["row_kind": "message", "role": "assistant", "text": .string("第 \($0) 条"), "row_id": .number(Double($0))] })
}

/// Tool calls' results as a page shows them: their call's id, no row_id.
func toolResults(_ calls: ClosedRange<Int>) -> JSONValue {
    .array(calls.map { ["row_kind": "message", "role": "tool", "name": "terminal", "tool_call_id": .string("call-\($0)")] })
}

/// A server that answers each cursor (none: the newest rows) with the page given for it, and
/// anything else with nothing.
func script(_ pages: [String?: JSONValue]) -> (JSONValue) -> JSONValue {
    { params in pages[params["cursor"]?.string] ?? ["rows": [], "next_cursor": nil] }
}

struct GaveUp: Error {}

/// 詩音's chat open on `chat` and attached, `rows` what came live is known to be, and the reads
/// answered by `answer`, on a server that gives up after 40 of them (a reading that would not end
/// shows as one that went on).
func store(_ chat: [ChatItem], rows: [String: Int] = [:], answer: @escaping (JSONValue) -> JSONValue) -> AppStore {
    let store = AppStore()
    store.sessions[bot] = session
    store.loadedChats = [bot]
    store.chats[bot] = chat
    store.control.storedRows = rows
    let gateway = store.gateway
    gateway.answer = { params in
        guard gateway.asked.count <= 40 else { throw GaveUp() }
        return answer(params)
    }
    return store
}

/// A turn's end (or start) as AppStore.apply has the store read for its notice, waited out: until
/// a read has come, and then none for a while (a reading that goes on asks again at once). What
/// the reads asked for: the limit of each.
func follow(_ store: AppStore, row: Int?, atStart: Bool = false) async -> [Int] {
    store.followNotices(bot, atStart: atStart, row: row)
    for _ in 0..<150 where store.gateway.asked.isEmpty {
        try? await Task.sleep(for: .milliseconds(20))
    }
    var seen = -1
    while seen != store.gateway.asked.count {
        seen = store.gateway.asked.count
        try? await Task.sleep(for: .milliseconds(100))
    }
    return store.gateway.asked.map { $0["limit"]?.int ?? 0 }
}

/// The reads as a check says them: one that would not end by how many there were.
func reads(_ limits: [Int]) -> String {
    limits.count > 8 ? "\(limits.count) reads" : "\(limits)"
}

/// The chat's notice cards, in its order: a row's under its id, one that came as a frame and still
/// has no row as "frame".
func cards(_ store: AppStore) -> [String] {
    (store.chats[bot] ?? []).filter { $0.event != nil }.map { NoticeCards.stage(of: $0.id) == nil ? $0.id : "frame" }
}

func order(_ store: AppStore) -> String {
    (store.chats[bot] ?? []).map(\.id).joined(separator: " ")
}

do {
    // the review's: a teammate's message (its turn's start says nothing; only the row does), 35
    // tool calls and the reply: rows 1, 2 to 71 and 72
    let hermes = Transcript(tools: 35, reply: "知道了（CI）。")
    let s = store(hermes.chat, rows: ["live-reply": hermes.reply], answer: hermes.page)
    let asked = await follow(s, row: hermes.notice)
    check(hermes.shapes.prefix(2) == ["7 rows, 1 numbered, a cursor", "25 rows, 0 numbered, a cursor"],
          "R3-05. as the review read them: six results and the reply, then 25 results, none with a row_id: \(hermes.shapes)")
    check(asked == [12, 50, 50], "R3-05. a page of tool calls alone is not the top: read on to the row: \(reads(asked))")
    check(cards(s) == ["row-1"], "R3-05. the message has its card: \(cards(s))")
    check(order(s).hasPrefix("row-1 tool-call-1 tool-call-2 "), "R3-05. ahead of its turn's first tool call: \(order(s).prefix(60))")
}

do {
    // the reply has no words (its row shows nothing): the newest twelve rows show six results alone
    let hermes = Transcript(tools: 35, reply: "")
    let s = store(hermes.chat, answer: hermes.page)
    let asked = await follow(s, row: hermes.notice)
    check(hermes.shapes.first == "6 rows, 0 numbered, a cursor", "R3-05. the newest rows: tool calls alone: \(hermes.shapes)")
    check(asked == [12, 50, 50], "R3-05. read on from there to the row: \(reads(asked))")
    check(cards(s) == ["row-1"], "R3-05. and the message has its card: \(cards(s))")
}

do {
    // sixty rows of conversation above the message: the page that has it has a cursor
    let hermes = Transcript(before: 60, tools: 35, reply: "知道了（CI）。")
    let s = store(hermes.chat, rows: ["live-reply": hermes.reply], answer: hermes.page)
    let asked = await follow(s, row: hermes.notice)
    check(hermes.shapes.last == "46 rows, 42 numbered, a cursor" && asked == [12, 50, 50],
          "R3-05. the row read, nothing more is read, though there is more above: \(reads(asked)), \(hermes.shapes)")
    check(cards(s) == ["row-61"], "R3-05. the card is its row's: \(cards(s))")
}

do {
    // the row is gone (rewound since, say): the third page has the rows before it
    let hermes = Transcript(before: 60, kept: false, tools: 35, reply: "知道了（CI）。")
    let s = store(hermes.chat, rows: ["live-reply": hermes.reply], answer: hermes.page)
    let asked = await follow(s, row: hermes.notice)
    check(asked == [12, 50, 50] && hermes.shapes.last?.hasSuffix("a cursor") == true,
          "R3-05. a row older than it read: the row was passed, nothing more is read: \(reads(asked))")
    // the row is gone and nothing older is stored: the reading ends at the top, a page of tool calls
    let top = Transcript(kept: false, tools: 35, reply: "知道了（CI）。")
    let t = store(top.chat, rows: ["live-reply": top.reply], answer: top.page)
    let up = await follow(t, row: top.notice)
    check(up == [12, 50, 50] && top.shapes.last == "4 rows, 0 numbered, the top",
          "R3-05. a row read nowhere: the top ends the reading: \(reads(up)), \(top.shapes)")
}

do {
    // an empty transcript: one read
    let none = store([], answer: script([nil: ["rows": [], "next_cursor": nil]]))
    check(await follow(none, row: 1) == [12], "R3-05. an empty transcript is read once")
    // a page with no row on it is the top, whatever its cursor says
    let empty = store([], answer: script([nil: ["rows": numbered(100...111), "next_cursor": "c1"],
                                          "c1": ["rows": [], "next_cursor": "c2"], "c2": ["rows": numbered(1...50), "next_cursor": nil]]))
    let asked = await follow(empty, row: 1)
    check(asked == [12, 50], "R3-05. an empty page with a cursor is the top: \(reads(asked))")
    // a cursor that keeps coming back: the same page again, the row never reached
    let again = store([], answer: script([nil: ["rows": numbered(100...111), "next_cursor": "again"],
                                          "again": ["rows": numbered(50...99), "next_cursor": "again"]]))
    let twice = await follow(again, row: 1)
    check(twice == [12, 50], "R3-05. a cursor read once is not read again: \(reads(twice))")
    let results = store([], answer: script([nil: ["rows": toolResults(30...35), "next_cursor": "again"],
                                            "again": ["rows": toolResults(5...29), "next_cursor": "again"]]))
    let tools = await follow(results, row: 1)
    check(tools == [12, 50], "R3-05. nor when its page is tool calls alone: \(reads(tools))")
}

do {
    // the row among the newest twelve: nothing more
    let near = Transcript(before: 60, tools: 2, reply: "知道了（CI）。")
    let s = store(near.chat, rows: ["live-reply": near.reply], answer: near.page)
    let asked = await follow(s, row: near.notice)
    check(asked == [12] && cards(s) == ["row-61"], "R3-05. the row among the newest: one read: \(reads(asked)), \(cards(s))")
    // a turn's start: the newest rows, whatever they hold
    let started = Transcript(tools: 35, reply: "")
    let t = store(started.chat, answer: started.page)
    let first = await follow(t, row: nil, atStart: true)
    check(first == [12], "R3-05. at a turn's start, the newest rows alone: \(reads(first))")
}

do {
    // a turn that names no row (one that failed): one more page, only for a card its start made
    // that still has no row; the newest twelve rows, tool calls alone, are not the top
    let failed = "[IMPORTANT: Background process proc_9 exited with an error (exit code 1).\nCommand: ./backup.sh\nOutput:\nNo space left on device\n]"
    let shown = "Background Process Failed: ./backup.sh"
    func frame() -> ChatItem {
        ChatItem(id: NoticeCards.id(.begun), role: .card, at: Date(timeIntervalSince1970: 1_900_000_000), text: shown,
                 event: .background)
    }
    let plain = Transcript(tools: 35, reply: "")
    let s = store(plain.chat, answer: plain.page)
    let asked = await follow(s, row: nil)
    check(asked == [12], "R3-05. no row named and no card waiting: one read: \(reads(asked))")
    let near = Transcript(text: failed, kind: "process_complete", display: shown, tools: 20, reply: "")
    let t = store([frame()] + near.chat, answer: near.page)
    let more = await follow(t, row: nil)
    check(more == [12, 50] && cards(t) == ["row-1"], "R3-05. a card waiting: one more page, which has its row: \(reads(more)), \(cards(t))")
    let far = Transcript(text: failed, kind: "process_complete", display: shown, tools: 35, reply: "")
    let u = store([frame()] + far.chat, answer: far.page)
    let most = await follow(u, row: nil)
    check(most == [12, 50] && cards(u) == ["frame"], "R3-05. and no more than one: \(reads(most)), \(cards(u))")
}

// A compaction: which card a row read before it is under its new number. The same card of a row at
// the same time, whatever its words
do {
    func card(_ id: String, at: Double) -> Item {
        Item(id: id, event: .background, text: "Background Process Finished: ./backup.sh", at: Date(timeIntervalSince1970: at),
             role: "card", stored: true, row: number(id))
    }
    var chat = [card("row-80", at: 5), card("row-80-card2", at: 5)]
    let copied = NoticeCards.put(page: [card("row-90", at: 5), card("row-90-card2", at: 5)], in: &chat) { $0 }
    check(copied.added == 0 && chat.map(\.id) == ["row-80", "row-80-card2"],
          "compacted. a row of two notices in the same words, numbered anew: the same two cards: \(chat.map(\.id))")
    let later = NoticeCards.put(page: [card("row-90", at: 5), card("row-90-card2", at: 5), card("row-95", at: 9)], in: &chat) { $0 }
    check(later.added == 1 && chat.map(\.id) == ["row-80", "row-80-card2", "row-95"],
          "compacted. …and the same words at another time another card: \(chat.map(\.id))")
}

// A compaction keeps a notice's row as a new row, its time and words as they were
// (compaction.json: pages Hermes gave, ../../real stage compact, in place and into a new session).
// A command's result started a turn (row 38) and the chat read it; the session was compacted, the
// row is row 48 now; a second command's result, in the same words, started a turn (row 54), whose
// end has the store read the newest rows. The notice the chat shows is the same card, once; the new
// one is a card of its own, though it says the same.

let compaction = try JSONValue.parse(String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))

/// The newest `limit` rows of `rows` (oldest first), or the `limit` before a cursor, as Hermes pages
/// a transcript newest first.
func pages(_ rows: [JSONValue]) -> (JSONValue) -> JSONValue {
    { params in
        let limit = params["limit"]?.int ?? 100
        let end = params["cursor"]?.string.flatMap { Int($0.dropFirst("before-".count)) } ?? rows.count
        let start = max(0, end - limit)
        return ["rows": .array(Array(rows[start..<end])), "next_cursor": start > 0 ? .string("before-\(start)") : .null]
    }
}

for path in ["in place", "rotation"] {
    let captured = compaction[path]
    let start = captured?["start"]
    let turn = captured?["persisted_turn"]
    let read = AppStore().transcriptItems(["rows": captured?["before3"]?["rows"] ?? []])
    func followed(from chat: [ChatItem]) async -> AppStore {
        // the second result's turn as it came: the card its start made, and its reply, the rows its end named
        var chat = chat
        let rows = ["live-reply": turn?["final_assistant_row_id"]?.int ?? 0]
        for card in Notices.read(start?["text"]?.string ?? "", kind: start?["display_kind"]?.string,
                                 display: start?["display_text"]?.string).enumerated().map({ index, notice in
            ChatItem(id: index == 0 ? NoticeCards.id(.begun) : "card-\(index)", role: .card, at: Date(), text: notice.text,
                     event: notice.event)
        }) {
            NoticeCards.begin(card, in: &chat) { AppStore.notice($0, rows: rows) }
        }
        chat.append(ChatItem(id: "live-reply", role: .assistant, at: Date(), text: "后台的事有结果了（mock）。"))
        var known = rows
        for card in chat where NoticeCards.stage(of: card.id) == .begun { known[card.id] = turn?["user_row_id"]?.int }
        let s = store(chat, rows: known, answer: pages(captured?["after3b"]?["rows"]?.array ?? []))
        _ = await follow(s, row: turn?["user_row_id"]?.int)
        return s
    }
    let s = await followed(from: read)
    check(cards(s) == ["row-38", "row-54"],
          "compacted. (\(path)) read before the compaction, the notice is its card still, once, and the new one in its words its own: \(cards(s))")
    check(order(s).hasSuffix("row-37 row-38 row-39 row-54 live-reply"),
          "compacted. (\(path)) …each where it was, ahead of its reply: …\(order(s).suffix(60))")
    // read after the compaction: nothing of it to tell apart
    let after = await followed(from: AppStore().transcriptItems(["rows": captured?["after3"]?["rows"] ?? []]))
    check(cards(after) == ["row-48", "row-54"], "compacted. (\(path)) the chat read after the compaction: the same two cards: \(cards(after))")
}

// Hermes compacting the session by itself (autocompaction.json: ../../real, stage auto, in place and
// into a new session), at a turn's start and in a turn after a tool's result. Its copy of a
// background result's row names no kind and no display_text: it is Hermes's text for the model at
// the result's time, no notice for a chat at all. In place its copies of replies are timed at the
// compaction, later than the rows of yours after them on the page, so NoticeCards.put cannot tell
// them; in a new session they keep their time. A result whose row was kept (row 16, then the
// second result's row) and the next result's turn: the chat that read the result before has its
// card still, once; the next is a card of its own, where its turn began; nothing else of the page
// comes in.

let auto = try JSONValue.parse(String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8))

/// The chat `chat`, then the turn a result began as it came (`turn`: its start's card, its reply),
/// followed at its end over `rows`, paged as Hermes pages them.
func followed(_ chat: [ChatItem], turn: JSONValue?, rows: [JSONValue]) async -> AppStore {
    var chat = chat
    let ended = turn?["persisted_turn"]
    let replied = ["live-reply": ended?["final_assistant_row_id"]?.int ?? 0]
    let start = turn?["start"]
    for card in Notices.read(start?["text"]?.string ?? "", kind: start?["display_kind"]?.string,
                             display: start?["display_text"]?.string).enumerated().map({ index, notice in
        ChatItem(id: index == 0 ? NoticeCards.id(.begun) : "card-\(index)", role: .card, at: Date(), text: notice.text,
                 event: notice.event)
    }) {
        NoticeCards.begin(card, in: &chat) { AppStore.notice($0, rows: replied) }
    }
    chat.append(ChatItem(id: "live-reply", role: .assistant, at: Date(), text: "后台的事有结果了（mock）。"))
    var known = replied
    for card in chat where NoticeCards.stage(of: card.id) == .begun { known[card.id] = ended?["user_row_id"]?.int }
    let s = store(chat, rows: known, answer: pages(rows))
    _ = await follow(s, row: ended?["user_row_id"]?.int)
    return s
}

for path in ["in place", "rotation"] {
    let data = auto[path]
    func rows(_ page: String) -> [JSONValue] { data?[page]?["rows"]?.array ?? [] }
    func numbered(_ number: Int, _ page: String) -> JSONValue? { rows(page).first { $0["row_id"]?.int == number } }
    let result = numbered(16, "before"), reply = numbered(17, "before")
    let keptAt = rows("after3").firstIndex { $0["role"] == "user" && $0["timestamp"] == result?["timestamp"] }
    let kept = keptAt.map { rows("after3")[$0] }
    // the reply's copy is the row after the result's
    let replyKept = keptAt.flatMap { $0 + 1 < rows("after3").count ? rows("after3")[$0 + 1] : nil }
    let second = data?["second"]?["persisted_turn"]?["user_row_id"]?.int ?? 0
    let third = data?["third"]?["persisted_turn"]?["user_row_id"]?.int ?? 0
    check(result?["display_kind"] == "process_complete" && kept != nil && kept?["row_id"] != result?["row_id"]
            && kept?["display_kind"] == nil && kept?["display_metadata"] == nil
            && kept?["text"]?.string?.hasPrefix("[IMPORTANT: Background process") == true
            && (path == "rotation") == (replyKept?["timestamp"] == reply?["timestamp"]),
          "auto. (\(path)) Hermes's pages: the result's row 16 is row \(kept?["row_id"]?.int ?? 0) once compacted, at its time, with no kind and no display_text; its reply's copy is \(path == "rotation" ? "at its time" : "timed at the compaction")")
    // at the start of the turn after it: the chat that read the result before
    let before = AppStore().transcriptItems(["rows": .array(rows("before"))])
    let s = await followed(before, turn: data?["second"], rows: rows("after3"))
    check(cards(s) == ["row-16", "row-\(second)"],
          "auto. (\(path)) compacted at a turn's start since the chat read it: the result is its card still, once, and the next result's its own: \(cards(s))")
    check(order(s) == before.map(\.id).joined(separator: " ") + " row-\(second) live-reply",
          "auto. (\(path)) …and nothing else of the page comes in, the next result's card where its turn began: …\(order(s).suffix(60))")
    // in the turn whose command's result came into a full context: the chat that read the page before
    let read = AppStore().transcriptItems(["rows": .array(rows("after3"))])
    let t = await followed(read, turn: data?["third"], rows: rows("after4"))
    check(cards(t) == ["row-\(second)", "row-\(third)"],
          "auto. (\(path)) compacted in a turn since the chat read it: the second result is its card still, once, and the third result's its own: \(cards(t))")
    check(order(t) == read.map(\.id).joined(separator: " ") + " row-\(third) live-reply",
          "auto. (\(path)) …and nothing else of the page comes in: …\(order(t).suffix(60))")
}

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
