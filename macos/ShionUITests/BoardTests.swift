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
        XCTAssertTrue(waitForText("停下来等你", in: app, timeout: 3), "no runs")

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

        // drag 「下载第8回课件」 from 排队 to 完成; its child then queues behind 课程's running card
        let card = element("card-t_dl8", in: app)
        let done = element("board-column-done", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5) && done.exists)
        card.click(forDuration: 0.6, thenDragTo: done)
        var moved = waitUntil(timeout: 8) { done.frame.contains(CGPoint(x: card.frame.midX, y: card.frame.midY)) }
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
        XCTAssertFalse(waitForText("Kanban t_", in: app, timeout: 1), "the board's notice shows as text")
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
        XCTAssertTrue(reread, "after reading the chat again, the call and the notice are not both the card")
        XCTAssertFalse(waitForText("Kanban t_", in: app, timeout: 1), "the board's notice shows as text after reading again")
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

        // the second table is wider than the reply even with its cells wrapped: it scrolls sideways
        // in its own box until its last column shows, and the words before it stay where they are
        let wide = element("markdown-table-scroll", in: app)
        if wide.waitForExistence(timeout: 5), let edge = exactText("最右这列的格子（CI）", in: app),
           let words = findText("各门课这周的情况", in: app) {
            let past = edge.frame.maxX > wide.frame.maxX + 1
            let wordsX = words.frame.minX
            let revealed = scrollSideways(wide, revealing: edge)
            keep(window.screenshot(), "board-13a-wide-table-scrolled")
            XCTAssertTrue(past, "the wide table's last column fits already: \(edge.frame) in \(wide.frame)")
            XCTAssertTrue(revealed, "scrolling the wide table did not bring its last column into view: \(edge.frame) in \(wide.frame)")
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
            let revealed = scrollSideways(code, revealing: source)
            keep(window.screenshot(), "board-13b-code-scrolled")
            XCTAssertTrue(past, "the long code line fits already: \(source.frame) in \(code.frame)")
            XCTAssertTrue(revealed, "scrolling the code block did not bring the line's end into view: \(source.frame) in \(code.frame)")
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
        var positions: [String] = []
        openAndClose(run, above: reply, in: app, window: window, "at the end",
                     shots: ("board-14-chat-tools-opened", "board-15-chat-tools-closed"), positions: &positions)
        let back = scrollBack(over: run, by: 120)
        positions.append("scrolled back from the end: the line moved \(back)")
        if back >= 90 {
            openAndClose(run, above: reply, in: app, window: window, "scrolled back",
                         shots: ("board-16-chat-tools-opened-midway", "board-17-chat-tools-closed-midway"), positions: &positions)
        } else {
            keep(window.screenshot(), "board-16-not-scrolled-back")
            XCTFail("the chat did not scroll back from its end: the line moved \(back)")
        }
        note(positions.joined(separator: "\n"), "board-positions")
        app.terminate()
    }

    /// Opens the folded calls with a click and closes them with another, measuring the line and
    /// the reply below it each time: the line stays put, and the reply moves down by as much as
    /// the calls take, then back. The numbers go in the failures and in `positions`.
    @MainActor
    private func openAndClose(_ run: XCUIElement, above reply: XCUIElement, in app: XCUIApplication, window: XCUIElement,
                              _ place: String, shots: (opened: String, closed: String), positions: inout [String]) {
        let line = run.frame.minY
        let below = reply.frame.minY
        run.click()
        let opened = waitUntil(timeout: 5) { self.findText("web_extract · moodle.example（CI）", in: app) != nil }
        settle { abs(run.frame.minY - line) <= 2 }
        let openedLine = run.frame.minY
        let openedBelow = reply.frame.minY
        // from the line's foot to the last call's: what opening added
        let calls = (findText("web_extract · moodle.example（CI）", in: app)?.frame.maxY ?? run.frame.maxY) - run.frame.maxY
        keep(window.screenshot(), shots.opened)
        run.click()
        let closed = waitUntil(timeout: 5) { self.findText("read_file · syllabus（CI）", in: app) == nil }
        settle { abs(run.frame.minY - line) <= 2 }
        let closedLine = run.frame.minY
        let closedBelow = reply.frame.minY
        keep(window.screenshot(), shots.closed)
        let numbers = "\(place): the line at \(line), opened \(openedLine), closed \(closedLine); "
            + "the reply below at \(below), opened \(openedBelow), closed \(closedBelow); the calls take \(calls)"
        positions.append(numbers)
        print("positions: \(numbers)")
        XCTAssertTrue(opened, "\(place): the folded tool calls did not open on a click")
        XCTAssertTrue(closed, "\(place): the opened tool calls did not close on a second click")
        XCTAssertEqual(openedLine, line, accuracy: 4, "\(place): the line moved as the calls opened. \(numbers)")
        XCTAssertGreaterThan(calls, 30, "\(place): the opened calls take no room. \(numbers)")
        XCTAssertEqual(openedBelow - below, calls, accuracy: 6, "\(place): the reply did not move down by as much as the calls take. \(numbers)")
        XCTAssertEqual(closedLine, line, accuracy: 4, "\(place): the line moved as the calls closed. \(numbers)")
        XCTAssertEqual(closedBelow, below, accuracy: 4, "\(place): the reply did not come back as the calls closed. \(numbers)")
    }

    /// Scrolls the chat back from its end by about `distance` with the wheel over `handle` (a line
    /// of the chat, not a block that scrolls sideways); how far `handle` moved down. Which sign of
    /// a wheel delta scrolls back, and how far a delta goes, is the runner's business: nudges both
    /// ways, growing until one moves the chat back (at the end, the other way moves nothing).
    @MainActor
    private func scrollBack(over handle: XCUIElement, by distance: CGFloat) -> CGFloat {
        let start = handle.frame.minY
        let moved = { handle.frame.minY - start }
        var step: CGFloat = 0
        var size: CGFloat = 10
        while step == 0, size <= 160 {
            for sign: CGFloat in [1, -1] {
                let before = handle.frame.minY
                handle.scroll(byDeltaX: 0, deltaY: sign * size)
                Thread.sleep(forTimeInterval: 0.3)
                if handle.frame.minY > before + 1 {
                    step = sign * size
                    break
                }
            }
            size *= 2
        }
        for _ in 0..<20 where step != 0 && moved() < distance {
            handle.scroll(byDeltaX: 0, deltaY: step)
            Thread.sleep(forTimeInterval: 0.3)
        }
        Thread.sleep(forTimeInterval: 0.5)
        return moved()
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

    /// Scrolls `area` sideways until `target`'s right edge is inside it. Which sign of a wheel
    /// delta moves content left is the runner's business: at the leading edge a nudge the other
    /// way moves nothing, so the first nudge tells.
    @MainActor
    private func scrollSideways(_ area: XCUIElement, revealing target: XCUIElement) -> Bool {
        let inside = { target.frame.maxX <= area.frame.maxX + 2 }
        let start = target.frame.minX
        var step: CGFloat = -300
        for attempt in 0..<10 {
            if inside() { return true }
            area.scroll(byDeltaX: step, deltaY: 0)
            Thread.sleep(forTimeInterval: 0.4)
            if attempt == 0, target.frame.minX >= start - 1 {
                step = -step
            }
        }
        return inside()
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
