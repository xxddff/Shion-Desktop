import AppKit
import XCTest

/// The board against ci/fake_hermes.py (its kanban routes are in ci/fake_kanban.py): sign in,
/// open 看板, see the server's cards with what each waits on, open one, drag one to 完成, make a
/// new one, switch boards. A picture at each step (`board-*.png`).
final class BoardTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"

    @MainActor
    func testServerBoard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "board",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch
        keep(window.screenshot(), "board-0-demo")

        // sign in as SignInTests does
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings window")
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        settings.buttons["sign-in"].click()
        let state = element("connection-state", in: settings)
        let online = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "已连接", "已连接")
        let connected = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: online, object: state)], timeout: 45)
        guard connected == .completed else {
            keep(XCUIScreen.main.screenshot(), "board-1-not-connected")
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }
        app.typeKey("w", modifierFlags: .command)

        // the server's cards, each saying what it waits on: its assistant's own limit (课程 has one
        // running and may have 1), a parent, the dispatcher's next tick, and a block's reason
        let shown = waitForText("整理第8回录音（CI）", in: app, timeout: 15)
        Thread.sleep(forTimeInterval: 1)
        keep(window.screenshot(), "board-2-server")
        XCTAssertTrue(shown, "the server's cards did not show")
        XCTAssertFalse(waitForText("整理「数据结构与算法 第7回」录音", in: app, timeout: 0.5), "demo cards still showing")
        XCTAssertTrue(waitForText("手上还有一件", in: app, timeout: 5), "no per-assistant wait")
        XCTAssertTrue(waitForText("等「下载第8回课件（CI）」做完", in: app, timeout: 5), "no parent wait")
        XCTAssertTrue(waitForText("等下一轮派发", in: app, timeout: 5), "no dispatcher wait")
        XCTAssertTrue(waitForText("门户要两步验证码，等你把验证码发过来", in: app, timeout: 5), "no block reason")

        // the blocked card's detail: comments and runs
        let blocked = element("card-t_grades", in: app)
        XCTAssertTrue(blocked.waitForExistence(timeout: 5))
        blocked.click()
        let detail = waitForText("门户要两步验证码，发到你的手机了。", in: app, timeout: 10)
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "board-3-detail")
        XCTAssertTrue(detail, "the card's comments did not show")
        // its runs are folded under 经过, which says how the last one ended; a click lists them
        let runs = element("card-runs", in: app)
        XCTAssertTrue(runs.waitForExistence(timeout: 3), "no runs")
        runs.click()
        XCTAssertTrue(waitForText("停下了", in: app, timeout: 3), "the runs did not open")

        // over the whole page, for a card with much to read: the columns give way and the runs are
        // all there without a click; Esc puts it back beside the board, still open
        let resize = element("card-resize", in: app)
        XCTAssertTrue(resize.waitForExistence(timeout: 3), "no way to open the detail over the page")
        resize.click()
        let column = element("board-column-running", in: app)
        let tookPage = waitUntil(timeout: 5) { !column.exists }
        let wholeRuns = waitForText("停下了", in: app, timeout: 3)
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "board-3b-detail-wide")
        XCTAssertTrue(tookPage, "the detail did not take the page")
        XCTAssertTrue(wholeRuns && !element("card-runs", in: app).exists, "over the page the runs are not all open")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(column.waitForExistence(timeout: 5), "Esc did not bring the board back")
        XCTAssertTrue(element("card-comment", in: app).waitForExistence(timeout: 5), "the detail did not stay open beside the board")

        // you answer it: the comment goes out under the name you signed in with (the stand-in
        // keeps the author it is sent) and shows as yours; 让它继续 puts the card back in the queue
        let field = element("card-comment", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no comment field")
        field.click()
        field.typeText("验证码是 246810（CI）")
        element("card-comment-send", in: app).click()
        let commented = waitForText("验证码是 246810（CI）", in: app, timeout: 10)
        // the stand-in numbers comments per board: 课程's is 1, this one 2
        let author = element("comment-author-2", in: app)
        let yours = author.waitForExistence(timeout: 5) && says(author, "你")
        keep(window.screenshot(), "board-3a-commented")
        XCTAssertTrue(commented, "the comment did not show")
        XCTAssertTrue(yours, "the comment is not shown as yours: \(author.label) / \(String(describing: author.value))")

        // the detail is put away from its own button, and the five columns are all in the window
        // again (with it open the board scrolls sideways under what is left)
        let close = element("card-close", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 3), "no way to put the detail away")
        close.click()
        let card = element("card-t_dl8", in: app)
        let done = element("board-column-done", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5) && done.exists)
        let allInView = waitUntil(timeout: 5) { !self.element("card-comment", in: app).exists && done.isHittable }
        XCTAssertTrue(allInView, "with the detail away the five columns are not all in view: 完成 at \(done.frame), the window \(window.frame)")

        // drag 「下载第8回课件」 from 排队 to 完成; its child then queues behind 课程's running card
        var moved = false
        if done.isHittable {
            card.click(forDuration: 0.6, thenDragTo: done)
            moved = waitUntil(timeout: 8) { done.frame.contains(CGPoint(x: card.frame.midX, y: card.frame.midY)) }
        }
        var how = moved ? "drag" : "none"
        if !moved {
            // the context menu does the same move
            card.rightClick()
            let item = app.menuItems["完成"].firstMatch
            if item.waitForExistence(timeout: 3) {
                item.click()
                moved = waitUntil(timeout: 8) { done.frame.contains(CGPoint(x: card.frame.midX, y: card.frame.midY)) }
                how = moved ? "menu" : "none"
            }
        }
        let promoted = waitUntil(timeout: 10) { self.findText("等「下载第8回课件（CI）」做完", in: app) == nil }
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "board-4-moved-by-\(how)")
        XCTAssertTrue(moved, "the card did not move to 完成")
        XCTAssertTrue(promoted, "the child card still waits on its parent")

        // a new card for 课程
        element("new-card", in: app).click()
        let title = element("new-card-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 5), "no new-card sheet")
        title.click()
        title.typeText("CI 新建的卡")
        let body = element("new-card-body", in: app)
        body.click()
        body.typeText("从 BoardTests 建的。")
        keep(window.screenshot(), "board-5-new")
        element("new-card-create", in: app).click()
        let created = waitForText("CI 新建的卡", in: app, timeout: 10)
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "board-6-created")
        XCTAssertTrue(created, "the new card did not show")

        // a card 詩音 hands over in her chat shows there as the board's card: at once from the call's
        // result, then with its status as the board moves; 课程 finishes it a few seconds later
        // and the board's notice comes in as a card, not as words in your name
        element("bot-shion", in: app).click()
        let composer = element("composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "詩音's chat did not open")
        Thread.sleep(forTimeInterval: 1)
        composer.click()
        composer.typeText("派一张卡（CI）")
        element("send", in: app).click()
        let handed = waitForText("整理第8回笔记（CI）", in: app, timeout: 10)
        keep(window.screenshot(), "board-8-card-in-chat")
        XCTAssertTrue(handed, "the card 詩音 made did not show in her chat")
        let finished = waitForText("课程把笔记整理好了。", in: app, timeout: 15)
        let shownDone = waitUntil(timeout: 10) { self.chatCards("整理第8回笔记（CI）", saying: "完成", in: app) >= 1 }
        keep(window.screenshot(), "board-9-card-done")
        XCTAssertTrue(finished, "no turn after the board's notice")
        XCTAssertTrue(shownDone, "the card in the chat does not show it is done")
        XCTAssertFalse(waitForText("[kanban]", in: app, timeout: 1), "the board's notice shows as text")
        // read again from the transcript, which keeps the call but not the card's id: a chat stays
        // loaded while connected, so disconnect and connect, and the chat starts over from the server
        app.typeKey(",", modifierFlags: .command)
        let prefs = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(prefs.waitForExistence(timeout: 5), "no Settings window")
        let link = element("connection-state", in: prefs)
        func phase(_ prefix: String) -> XCTNSPredicateExpectation {
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix),
                                      object: link)
        }
        prefs.buttons["断开"].click()
        XCTAssertEqual(XCTWaiter().wait(for: [phase("未连接")], timeout: 10), .completed, "did not disconnect")
        prefs.buttons["连接"].click()
        XCTAssertEqual(XCTWaiter().wait(for: [phase("已连接")], timeout: 30), .completed, "did not connect again")
        app.typeKey("w", modifierFlags: .command)
        element("bot-shion", in: app).click()
        let reread = waitUntil(timeout: 20) { self.chatCards("整理第8回笔记（CI）", saying: "完成", in: app) >= 2 }
        keep(window.screenshot(), "board-10-chat-reread")
        if !reread {
            noteRereadChat(in: app, window: window)
        }
        XCTAssertTrue(reread, "after reading the chat again, the call and the notice are not both the card")
        XCTAssertFalse(waitForText("[kanban]", in: app, timeout: 1), "the board's notice shows as text after reading again")
        element("nav-board", in: app).click()
        XCTAssertTrue(waitForText("整理第8回录音（CI）", in: app, timeout: 10), "back on the board")

        // the other board
        let picker = element("board-picker", in: app)
        if picker.waitForExistence(timeout: 5) {
            picker.click()
            let other = app.menuItems["副业（CI）"].firstMatch
            XCTAssertTrue(other.waitForExistence(timeout: 3), "no other board in the menu")
            other.click()
            let switched = waitForText("整理副业发票（CI）", in: app, timeout: 10)
            Thread.sleep(forTimeInterval: 0.5)
            keep(window.screenshot(), "board-7-other-board")
            XCTAssertTrue(switched, "the other board did not show")
        } else {
            keep(window.screenshot(), "board-7-no-picker")
            XCTFail("no board picker")
        }

        // 今天's 助手在做 is the server's: what runs on either board, not the demo cards
        element("nav-today", in: app).click()
        let both = waitUntil(timeout: 15) {
            self.findText("整理副业发票（CI）", in: app) != nil && self.findText("整理第8回录音（CI）", in: app) != nil
        }
        keep(window.screenshot(), "board-11-today")
        XCTAssertTrue(both, "助手在做 does not list the cards running on both boards")
        XCTAssertFalse(waitForText("整理「数据结构与算法 第7回」录音", in: app, timeout: 0.5), "demo cards on 今天")

        // back in 詩音's chat, a turn of three tool calls and then a reply with two tables: the
        // calls show while the turn runs and fold into one line once the reply is in; the tables
        // are laid out, so a cell is a text of its own, not a line with pipes
        element("bot-shion", in: app).click()
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "詩音's chat did not open again")
        Thread.sleep(forTimeInterval: 1)
        let transcript = element("transcript", in: app)
        // it opens at its newest message
        let newest = findText("课程把笔记整理好了", in: app)
        XCTAssertTrue(newest.map { inView($0, of: transcript) } ?? false,
                      "詩音's chat did not open at its newest message: \(say(newest.flatMap { self.minY($0) })) in \(transcript.frame)")
        composer.click()
        composer.typeText("列一下这周的作业（CI）")
        element("send", in: app).click()
        let running = waitForText("web_search · 这周的作业（CI）", in: app, timeout: 8)
        keep(window.screenshot(), "board-12-chat-tools-running")
        print("a tool call showed while the turn ran: \(running)")
        let cell = waitUntil(timeout: 15) { self.exactText("周三 17:00（CI）", in: app) != nil }
        let folded = waitUntil(timeout: 10) {
            self.labelled("用了 3 个工具", in: app) && self.findText("read_file · syllabus（CI）", in: app) == nil
        }
        keep(window.screenshot(), "board-13-chat-folded")
        XCTAssertTrue(cell, "the reply's table is not laid out: no text is just 周三 17:00（CI）")
        XCTAssertTrue(element("markdown-table", in: app).exists, "no table in the reply")
        XCTAssertTrue(folded, "the turn's tool calls did not fold into one line once the reply was in")

        // the rest of the reply's checks all report, one failing or not
        continueAfterFailure = true

        // the turn was followed down as it came: the reply's last words are in view
        let end = findText("周三前交", in: app)
        XCTAssertTrue(end.map { inView($0, of: transcript) } ?? false,
                      "the reply's end is not in view: \(String(describing: end?.frame)) in \(transcript.frame)")

        // the second table is wider than the reply even with its cells wrapped: it scrolls sideways
        // in its own box until its last column shows, and the words before it stay where they are
        var positions: [String] = []
        let wide = element("markdown-table-scroll", in: app)
        if wide.waitForExistence(timeout: 5), let edge = exactText("最右这列的格子（CI）", in: app),
           let words = findText("各门课这周的情况", in: app) {
            let past = edge.frame.maxX > wide.frame.maxX + 1
            let wordsX = words.frame.minX
            let (revealed, how) = scrollSideways(wide, revealing: edge)
            positions.append("the wide table: \(how)")
            keep(window.screenshot(), "board-13a-wide-table-scrolled")
            XCTAssertTrue(past, "the wide table's last column fits already: \(edge.frame) in \(wide.frame)")
            XCTAssertTrue(revealed, "scrolling the wide table did not bring its last column into view: \(edge.frame) in \(wide.frame); \(how)")
            XCTAssertEqual(words.frame.minX, wordsX, accuracy: 1, "the words before the wide table moved with it")
        } else {
            keep(window.screenshot(), "board-13a-no-wide-table")
            XCTFail("the wide table does not scroll on its own, or its last column or the words before it are missing")
        }

        // a code line longer than the reply scrolls sideways in its block, the same way
        let code = element("markdown-code", in: app)
        let either = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "BinaryHeap", "BinaryHeap")
        let source = code.staticTexts.matching(either).firstMatch.exists
            ? code.staticTexts.matching(either).firstMatch : code.textViews.matching(either).firstMatch
        if code.waitForExistence(timeout: 5), source.exists, let words = findText("先把这一行跑通", in: app) {
            let past = source.frame.maxX > code.frame.maxX + 1
            let wordsX = words.frame.minX
            let (revealed, how) = scrollSideways(code, revealing: source)
            positions.append("the code block: \(how)")
            keep(window.screenshot(), "board-13b-code-scrolled")
            XCTAssertTrue(past, "the long code line fits already: \(source.frame) in \(code.frame)")
            XCTAssertTrue(revealed, "scrolling the code block did not bring the line's end into view: \(source.frame) in \(code.frame); \(how)")
            XCTAssertEqual(words.frame.minX, wordsX, accuracy: 1, "the words before the code block moved with it")
        } else {
            keep(window.screenshot(), "board-13b-no-code")
            XCTFail("no code block with the long line, or the words before it are missing")
        }

        // a click opens the folded calls below the line, which stays under the pointer while the
        // reply below moves down by as much as they take; a second click closes them, and both are
        // back. At the end of the chat, then scrolled back from it a little.
        let run = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "用了 3 个工具")).firstMatch
        guard run.waitForExistence(timeout: 3), let reply = findText("这周要交的有两项", in: app) else {
            return XCTFail("no button for the folded tool calls, or no reply below it")
        }
        let measured = openAndClose(run, above: reply, in: app, window: window, "at the end",
                                    shots: ("board-14-chat-tools-opened", "board-15-chat-tools-closed"), positions: &positions)
        if measured {
            let back = scrollBack(watching: run, at: run.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), by: 120).moved
            positions.append("scrolled back from the end: the line moved \(back)")
            if back >= 90 {
                openAndClose(run, above: reply, in: app, window: window, "scrolled back",
                             shots: ("board-16-chat-tools-opened-midway", "board-17-chat-tools-closed-midway"), positions: &positions)
            } else {
                keep(window.screenshot(), "board-16-not-scrolled-back")
                XCTFail("the chat did not scroll back from its end: the line moved \(back)")
            }
        }
        stillWhileFurtherUp(in: app, window: window, transcript: transcript, positions: &positions)
        longReplyStays(in: app, window: window, transcript: transcript, positions: &positions)
        note(positions.joined(separator: "\n"), "board-positions")
        app.terminate()
    }

    /// Sent from wherever one is, a message and its reply are followed down to the end. Read
    /// further up, a message nobody asked for (the stand-in sends it when told, POST /ci/later)
    /// leaves what shows where it is; back at the end, it is there.
    @MainActor
    private func stillWhileFurtherUp(in app: XCUIApplication, window: XCUIElement, transcript: XCUIElement,
                                     positions: inout [String]) {
        let composer = element("composer", in: app)
        composer.click()
        composer.typeText("等一会儿再说一句（CI）")
        element("send", in: app).click()
        let replied = waitUntil(timeout: 10) { self.findText("好，过一会儿再说一句（CI）", in: app) != nil }
        Thread.sleep(forTimeInterval: 0.8)
        let reply = findText("好，过一会儿再说一句（CI）", in: app)
        let followed = reply.map { inView($0, of: transcript) } ?? false
        keep(window.screenshot(), "board-18-sent-followed")
        XCTAssertTrue(replied, "no reply to 等一会儿再说一句（CI）")
        XCTAssertTrue(followed, "the message sent and its reply were not followed down: "
                      + "\(String(describing: reply?.frame)) in \(transcript.frame)")
        guard let reply else { return }

        // further up: the wheel at the transcript's left margin, clear of the blocks that scroll sideways
        let margin = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3))
        let (back, step) = scrollBack(watching: reply, at: margin, by: 200, from: 40)
        let watched = ["各门课这周的情况", "先把这一行跑通", "周三前交", "等一会儿再说一句（CI）"]
            .compactMap { findText($0, in: app) }
            .first { inView($0, of: transcript) }
        let before = watched.flatMap { self.minY($0) }
        // the message nobody asked for, now that the chat is read further up: the stand-in answers
        // once it has gone out, and Shion has it a moment later
        let sent = StandIn.later("further up")
        Thread.sleep(forTimeInterval: 1.5)
        let after = watched.flatMap { self.minY($0) }
        keep(window.screenshot(), "board-19-further-up-message-came")

        // back down to the end, where it is
        var arrived = false
        for _ in 0..<15 where step != 0 {
            if let came = findText("又想起一件事（CI）", in: app), inView(came, of: transcript) {
                arrived = true
                break
            }
            margin.scroll(byDeltaX: 0, deltaY: -step * 3)
            Thread.sleep(forTimeInterval: 0.4)
        }
        keep(window.screenshot(), "board-20-back-at-the-end")
        let name = watched.map { $0.label.isEmpty ? String(describing: $0.value ?? "") : $0.label } ?? "nothing"
        let numbers = "further up: scrolled back \(back) from the end; \(name) at \(say(before)) before the message came, "
            + "\(say(after)) after (the stand-in \(sent ? "sent it" : "did not send it")); at the end it \(arrived ? "is" : "is not") there"
        positions.append(numbers)
        XCTAssertGreaterThan(back, 150, "the chat did not scroll back from its end. \(numbers)")
        XCTAssertNotNil(before, "nothing in view to watch. \(numbers)")
        XCTAssertEqual(after ?? .nan, before ?? .nan, accuracy: 2, "a message that came moved what shows further up. \(numbers)")
        XCTAssertTrue(arrived, "the message nobody asked for is not at the end. \(numbers)")
    }

    /// 詩音's 第 120 条 on the stand-in is a reply some screens tall. The find bar goes to it, and
    /// it fills what shows; then, for words found nowhere, 上一个 reads the older pages (the second,
    /// then the third): as they come in above, the reply stays where it was. The wheel can't stop
    /// on it as a page lands: a page is asked for as the top comes near, when a long reply leading
    /// the page is only just laid out, and the page comes with its foot and the rows below in view.
    @MainActor
    private func longReplyStays(in app: XCUIApplication, window: XCUIElement, transcript: XCUIElement,
                                positions: inout [String]) {
        app.typeKey("f", modifierFlags: .command)
        let field = element("find-field", in: app)
        if !field.waitForExistence(timeout: 5) {
            element("find", in: app).click()
        }
        guard field.waitForExistence(timeout: 5) else {
            positions.append("the long reply: no find bar")
            return XCTFail("neither ⌘F nor the toolbar's find button opened the find bar")
        }
        field.click()
        // from the end it is gone to through rows not laid out yet, and may only just show; gone
        // to again from there, it comes to the middle of what shows
        field.typeText("很长的回复")
        Thread.sleep(forTimeInterval: 2)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        field.typeText("很长的回复")
        Thread.sleep(forTimeInterval: 1.5)
        // words found nowhere (its paragraphs go to 48): nothing to go to, and what shows stays
        field.typeText("，段落 99")
        Thread.sleep(forTimeInterval: 0.5)
        let area = transcript.frame
        let before = longReply(in: transcript)
        let top = before.paragraphs["第 120 条（詩音）"]?.minY
        let foot = before.paragraphs.first { $0.key.hasPrefix("很长的回复，段落 48：") }?.value.maxY
        let fills = (top.map { $0 < area.minY } ?? false) && (foot.map { $0 > area.maxY } ?? false)
        keep(window.screenshot(), "board-21-long-reply")

        element("find-older", in: app).click()
        // the third page is asked for as the second comes in: it can be in by the next reading
        let came = landed(in: transcript, from: before.bar)
        let withSecond = longReply(in: transcript)
        let thenThird = landed(in: transcript, from: withSecond.bar)
        let withThird = longReply(in: transcript)
        keep(window.screenshot(), "board-22-long-reply-pages-in")
        app.typeKey(.escape, modifierFlags: [])

        // by its topmost paragraph read each time
        let held = before.paragraphs
            .filter { withSecond.paragraphs[$0.key] != nil && withThird.paragraphs[$0.key] != nil }
            .min { $0.value.minY < $1.value.minY }
        let name = held.map { $0.key.components(separatedBy: "：").first ?? $0.key } ?? "no paragraph read each time"
        let (was, second, third) = (held?.value.minY, held.flatMap { withSecond.paragraphs[$0.key]?.minY },
                                    held.flatMap { withThird.paragraphs[$0.key]?.minY })
        func bar(_ reading: (paragraphs: [String: CGRect], bar: Double?)) -> String {
            reading.bar.map { String(format: "%.3f", $0) } ?? "not there"
        }
        let numbers = "the long reply (第 120 条, its top at \(say(top)), its foot at \(say(foot)) in \(area)): "
            + "「\(name)」 at \(say(was)) before 上一个, \(say(second)) once the scroll bar moved, \(say(third)) "
            + "\(thenThird ? "once it moved again" : "a moment later"); the scroll bar \(bar(before)), \(bar(withSecond)), \(bar(withThird))"
        positions.append(numbers)
        XCTAssertTrue(fills, "the long reply does not fill what shows. \(numbers)")
        XCTAssertTrue(came, "no older page came in. \(numbers)")
        XCTAssertEqual(second ?? .nan, was ?? .nan, accuracy: 4, "the long reply moved as an older page came in. \(numbers)")
        XCTAssertEqual(third ?? .nan, was ?? .nan, accuracy: 4, "the long reply moved as the older pages came in. \(numbers)")
    }

    /// From one snapshot of the transcript: the paragraphs of the stand-in's long 第 120 条 laid
    /// out, by their words, and where the transcript's own scroll bar is.
    @MainActor
    private func longReply(in transcript: XCUIElement) -> (paragraphs: [String: CGRect], bar: Double?) {
        guard let root = try? transcript.snapshot() else { return ([:], nil) }
        var paragraphs: [String: CGRect] = [:]
        func visit(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText || node.elementType == .textView,
               let text = [node.label, node.value as? String ?? ""]
                .first(where: { $0.hasPrefix("第 120 条（") || $0.hasPrefix("很长的回复，段落 ") }),
               paragraphs[text] == nil {
                paragraphs[text] = node.frame
            }
            node.children.forEach(visit)
        }
        visit(root)
        // not a wide table's inside a row
        let bar = root.children.first { $0.elementType == .scrollBar && $0.frame.height > $0.frame.width }
        let value = bar?.value
        return (paragraphs, (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init))
    }

    /// Waits up to 6 s for the transcript's scroll bar to move, as a page comes in above, then a
    /// moment for the row put back; false when it did not, or there is no bar to read.
    @MainActor
    private func landed(in transcript: XCUIElement, from bar: Double?) -> Bool {
        guard let bar else {
            Thread.sleep(forTimeInterval: 2.3)
            return false
        }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            if let now = longReply(in: transcript).bar, abs(now - bar) > 0.005 {
                Thread.sleep(forTimeInterval: 0.3)
                return true
            }
        }
        return false
    }

    /// The chat read again shows no cards (run 146: the transcript went blank as it was read again,
    /// with a reply taller than what shows a little above its end): what the transcript holds,
    /// read three times half a second apart, and again after a turn of the wheel, in
    /// board-reread.txt.
    @MainActor
    private func noteRereadChat(in app: XCUIApplication, window: XCUIElement) {
        let transcript = element("transcript", in: app)
        var readings: [String] = []
        for _ in 0..<3 {
            readings.append(described(transcript))
            Thread.sleep(forTimeInterval: 0.5)
        }
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.4)).scroll(byDeltaX: 0, deltaY: 40)
        Thread.sleep(forTimeInterval: 1)
        let cards = chatCards("整理第8回笔记（CI）", saying: "完成", in: app)
        readings.append("after a turn of the wheel: \(described(transcript)); \(cards) of the two cards")
        keep(window.screenshot(), "board-10a-chat-reread-wheel")
        note(readings.joined(separator: "\n"), "board-reread")
    }

    /// The transcript from one snapshot: where it is, its scroll bar, and the texts laid out in
    /// it, how many and the first few in view.
    @MainActor
    private func described(_ transcript: XCUIElement) -> String {
        guard let root = try? transcript.snapshot() else { return "no transcript" }
        var texts: [(text: String, frame: CGRect)] = []
        func visit(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText || node.elementType == .textView {
                texts.append((node.label.isEmpty ? node.value as? String ?? "" : node.label, node.frame))
            }
            node.children.forEach(visit)
        }
        visit(root)
        let area = root.frame
        let value = root.children.first { $0.elementType == .scrollBar && $0.frame.height > $0.frame.width }?.value
        let bar = ((value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)).map { String(format: "%.3f", $0) }
        let shown = texts.filter { $0.frame.maxY > area.minY && $0.frame.minY < area.maxY }
        let first = shown.prefix(3).map { "「\($0.text.prefix(16))」 at \($0.frame.minY)" }.joined(separator: ", ")
        return "the transcript at \(area), its scroll bar \(bar ?? "not there"); \(texts.count) texts laid out, "
            + "\(shown.count) in view: \(first.isEmpty ? "none" : first)"
    }

    /// In the transcript's visible part, not above or below it.
    @MainActor
    private func inView(_ element: XCUIElement, of transcript: XCUIElement) -> Bool {
        guard element.exists, transcript.exists else { return false }
        let frame = element.frame, area = transcript.frame
        return frame.minY >= area.minY - 2 && frame.maxY <= area.maxY + 2
    }

    /// Opens the folded calls with a click and closes them with another, measuring the line and
    /// the reply below it each time: the line stays put, and the reply moves down by as much as
    /// the calls take, then back. The numbers go in the failures and in `positions`; false when
    /// the line was gone after a click, and nothing more can be measured.
    @MainActor
    @discardableResult
    private func openAndClose(_ run: XCUIElement, above reply: XCUIElement, in app: XCUIApplication, window: XCUIElement,
                              _ place: String, shots: (opened: String, closed: String), positions: inout [String]) -> Bool {
        let last = "web_extract · moodle.example（CI）"
        guard let line = minY(run), let below = minY(reply) else {
            positions.append("\(place): the line (\(run.exists)) or the reply below it (\(reply.exists)) is not there")
            XCTFail("\(place): the line or the reply below it is not there")
            return false
        }
        // where the line shows: the second click goes there, as a person would click it again
        let spot = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: run.frame.midX - window.frame.minX, dy: run.frame.midY - window.frame.minY))
        run.click()
        let opened = waitUntil(timeout: 5) { self.findText(last, in: app) != nil }
        settle { self.minY(run).map { abs($0 - line) <= 2 } ?? true }
        let openedLine = minY(run)
        let openedBelow = minY(reply)
        // from the line's foot to the last call's: what opening added
        var calls: CGFloat?
        if let call = findText(last, in: app), run.exists {
            calls = call.frame.maxY - run.frame.maxY
        }
        keep(window.screenshot(), shots.opened)
        guard openedLine != nil else {
            let numbers = "\(place): the line at \(line), the reply below at \(below); after the click the line is gone "
                + "(the chat moved elsewhere), the reply \(say(openedBelow))"
            positions.append(numbers)
            XCTFail(numbers)
            return false
        }
        spot.click()
        let closed = waitUntil(timeout: 5) { self.findText("read_file · syllabus（CI）", in: app) == nil }
        settle { self.minY(run).map { abs($0 - line) <= 2 } ?? true }
        let closedLine = minY(run)
        let closedBelow = minY(reply)
        keep(window.screenshot(), shots.closed)
        let numbers = "\(place): the line at \(line), opened \(say(openedLine)), closed \(say(closedLine)); "
            + "the reply below at \(below), opened \(say(openedBelow)), closed \(say(closedBelow)); the calls take \(say(calls))"
        positions.append(numbers)
        print("positions: \(numbers)")
        XCTAssertTrue(opened, "\(place): the folded tool calls did not open on a click")
        XCTAssertTrue(closed, "\(place): the opened tool calls did not close on a second click where the line showed")
        XCTAssertEqual(openedLine ?? .nan, line, accuracy: 4, "\(place): the line moved as the calls opened. \(numbers)")
        XCTAssertGreaterThan(calls ?? 0, 30, "\(place): the opened calls take no room. \(numbers)")
        XCTAssertEqual((openedBelow ?? .nan) - below, calls ?? .nan, accuracy: 6,
                       "\(place): the reply did not move down by as much as the calls take. \(numbers)")
        XCTAssertEqual(closedLine ?? .nan, line, accuracy: 4, "\(place): the line moved as the calls closed. \(numbers)")
        XCTAssertEqual(closedBelow ?? .nan, below, accuracy: 4, "\(place): the reply did not come back as the calls closed. \(numbers)")
        return closedLine != nil
    }

    /// Where `element` starts, or nil when it is not there (asking a missing element ends the test).
    @MainActor
    private func minY(_ element: XCUIElement) -> CGFloat? {
        element.exists ? element.frame.minY : nil
    }

    private func say(_ value: CGFloat?) -> String {
        value.map { "\($0)" } ?? "gone"
    }

    /// Scrolls the chat back from its end by about `distance` with the wheel at `point` (on the
    /// chat, not on a block that scrolls sideways): how far `handle` moved down, and the wheel
    /// delta that scrolls back. Which sign that is, and how far a delta goes, is the runner's
    /// business: nudges both ways, growing until one moves the chat back (at the end, the other
    /// way moves nothing).
    @MainActor
    private func scrollBack(watching handle: XCUIElement, at point: XCUICoordinate, by distance: CGFloat,
                            from size: CGFloat = 10) -> (moved: CGFloat, step: CGFloat) {
        guard let start = minY(handle) else { return (0, 0) }
        let moved = { (self.minY(handle) ?? start) - start }
        var step: CGFloat = 0
        var size = size
        while step == 0, size <= 160, handle.exists {
            for sign: CGFloat in [1, -1] {
                let before = moved()
                point.scroll(byDeltaX: 0, deltaY: sign * size)
                Thread.sleep(forTimeInterval: 0.3)
                if moved() > before + 1 {
                    step = sign * size
                    break
                }
            }
            size *= 2
        }
        for _ in 0..<20 where step != 0 && handle.exists && moved() < distance {
            point.scroll(byDeltaX: 0, deltaY: step)
            Thread.sleep(forTimeInterval: 0.3)
        }
        Thread.sleep(forTimeInterval: 0.5)
        return (moved(), step)
    }

    /// Waits a little at a time for `condition`, up to `timeout`, then a moment more for what
    /// moves to come to rest.
    @MainActor
    private func settle(timeout: TimeInterval = 1.5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Scrolls `area` sideways until `target`'s right edge is inside it, as a person would: the
    /// pointer rests on the block, then the wheel turns sideways. Which sign moves the content left
    /// is the runner's business, and a turn now and then moves nothing (run 144: ten turns at the
    /// block's middle, none moved it, as the first one's sign was taken for the wrong one): a turn
    /// that moves nothing is tried with the other sign too, and once a sign has moved it, it keeps
    /// it; a point where nothing moves at all is left for another one along the block. Failing
    /// that, the block's own scroll bar is dragged to its end. Whether the edge came in, and how.
    @MainActor
    private func scrollSideways(_ area: XCUIElement, revealing target: XCUIElement) -> (Bool, String) {
        let inside = { target.frame.maxX <= area.frame.maxX + 2 }
        guard !inside() else { return (true, "in view already") }
        var sign: CGFloat?
        var turns = 0
        for point: CGFloat in [0.5, 0.2, 0.8] {
            let spot = area.coordinate(withNormalizedOffset: CGVector(dx: point, dy: 0.5))
            spot.hover()
            Thread.sleep(forTimeInterval: 0.4)
            var still = 0
            while still < 3, turns < 24, !inside() {
                var moved = false
                for tried in sign.map({ [$0] }) ?? [-1, 1] {
                    let was = target.frame.minX
                    spot.scroll(byDeltaX: tried * 300, deltaY: 0)
                    turns += 1
                    Thread.sleep(forTimeInterval: 0.4)
                    if target.frame.minX < was - 1 {
                        sign = tried
                        moved = true
                        break
                    }
                }
                still = moved ? 0 : still + 1
            }
            if inside() {
                return (true, "\(turns) turns of the wheel, the last ones at \(point) of the block (sign \(sign ?? 0))")
            }
        }
        // the block's own bar, along its bottom edge, dragged from its start to its end
        let bar = area.scrollBars.allElementsBoundByIndex.first { $0.frame.width > $0.frame.height }
        if let bar {
            area.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            Thread.sleep(forTimeInterval: 0.3)
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
                .press(forDuration: 0.2, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)))
            Thread.sleep(forTimeInterval: 0.5)
        }
        let how = "\(turns) turns of the wheel moved it \(sign == nil ? "not at all" : "only so far")"
            + (bar == nil ? ", and no scroll bar of its own to drag" : ", then its scroll bar was dragged")
        return (inside(), how)
    }

    /// Anything labelled with `text`, a button among them.
    @MainActor
    private func labelled(_ text: String, in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
    }

    /// A text element showing just `text`, plain or selectable: a table's cell, where Markdown
    /// left as written would be one text with the pipes in it.
    @MainActor
    private func exactText(_ text: String, in app: XCUIApplication) -> XCUIElement? {
        let exact = NSPredicate(format: "label == %@ OR value == %@", text, text)
        return [app.staticTexts.matching(exact).firstMatch, app.textViews.matching(exact).firstMatch]
            .first { $0.exists }
    }

    @MainActor
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field \(field)")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    @MainActor
    private func says(_ element: XCUIElement, _ text: String) -> Bool {
        element.label == text || (element.value as? String) == text
    }

    /// How many cards in the chat show `title` and say `status`. A text's string is its label or
    /// its value; values are read on texts only (a control's can be a number, which a string
    /// predicate throws on), and a label with an icon carries its title as its label.
    @MainActor
    private func chatCards(_ title: String, saying status: String, in app: XCUIApplication) -> Int {
        let chips = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-card-"))
        var count = 0
        for index in 0..<chips.count {
            let chip = chips.element(boundBy: index)
            let titled = chip.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title))
                .firstMatch.exists
            let said = chip.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", status, status)).firstMatch.exists
                || chip.descendants(matching: .any).matching(NSPredicate(format: "label == %@", status)).firstMatch.exists
            if titled && said {
                count += 1
            }
        }
        return count
    }

    @MainActor
    private func element(_ identifier: String, in root: XCUIElement) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    /// The first text element showing `text`, plain or selectable; nil when none is there.
    @MainActor
    private func findText(_ text: String, in app: XCUIApplication) -> XCUIElement? {
        let either = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        return [app.staticTexts.matching(either).firstMatch, app.textViews.matching(either).firstMatch]
            .first { $0.exists }
    }

    /// Text anywhere in the app, plain or selectable; `value` only on text elements.
    @MainActor
    private func waitForText(_ text: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let either = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        let queries = [
            app.staticTexts.matching(either),
            app.textViews.matching(either),
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)),
        ]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if queries.contains(where: { $0.firstMatch.exists }) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    private func keep(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Numbers worth reading after the run, kept as a text beside the pictures (`name.txt`).
    private func note(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
