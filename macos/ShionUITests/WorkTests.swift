import AppKit
import XCTest

/// What the board asks of you and tells you, against ci/fake_hermes.py (its cards are in
/// ci/fake_kanban.py): the cards that stopped on your answer come to 待你处理, where you answer and
/// let them go on; each assistant's 工作记录 lists the cards it ran today on every board; and the
/// card notifications, which a test run writes down in a file instead of posting
/// (`-ShionNotificationLog`) and answers with a distributed notification, as typing into the
/// notification would. A picture at each step (`work-*.png`).
final class WorkTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"
    private let notes = "/tmp/shion-work-notifications.jsonl"

    @MainActor
    func testWorkForYou() throws {
        continueAfterFailure = false
        try? FileManager.default.removeItem(atPath: notes)
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "confirm",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
            "-ShionNotificationLog", notes,
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch
        let demo = waitForText("下载上学期成绩单", in: app, timeout: 5)
        keep(window.screenshot(), "work-0-demo-confirm")
        XCTAssertTrue(demo, "the demo card waiting on you is not in 待你处理")

        // sign in as BoardTests does
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings window")
        serverTab(settings)
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        settings.buttons["sign-in"].click()
        let state = element("connection-state", in: settings)
        let online = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "已连接", "已连接")
        let connected = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: online, object: state)], timeout: 45)
        guard connected == .completed else {
            keep(XCUIScreen.main.screenshot(), "work-1-not-connected")
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }
        app.typeKey("w", modifierFlags: .command)

        // 待你处理: the cards stopped on you, on both boards: a code only you get (needs_input), an
        // account it does not have (capability); not the one stopped on a flaky site (transient)
        let grades = element("card-ask-t_grades", in: app)
        XCTAssertTrue(grades.waitForExistence(timeout: 20), "the card waiting on a code did not come to 待你处理")
        XCTAssertTrue(element("card-ask-t_moodle", in: app).waitForExistence(timeout: 5), "no card waiting on an account")
        XCTAssertTrue(element("card-ask-t_bank", in: app).waitForExistence(timeout: 15), "no card from the other board")
        XCTAssertTrue(waitForText("门户要两步验证码，等你把验证码发过来", in: app, timeout: 5), "no reason on the card")
        XCTAssertTrue(waitForText("缺少能力：Moodle 要学校的统一认证登录", in: app, timeout: 5), "no capability reason")
        XCTAssertTrue(waitForText("门户要两步验证码，发到你的手机了。", in: app, timeout: 5), "the assistant's note is not shown")
        XCTAssertFalse(element("card-ask-t_weather", in: app).exists, "a block a retry clears came to 待你处理")
        XCTAssertFalse(waitForText("下载上学期成绩单", in: app, timeout: 0.5), "the demo card is still there")
        Thread.sleep(forTimeInterval: 1)
        keep(window.screenshot(), "work-1-confirm")
        // what was waiting before Shion connected is not news
        XCTAssertTrue(cardNotes().isEmpty, "notified about cards that were waiting already: \(cardNotes())")

        // the code, and 让它继续: the card leaves; its worker runs, stops on the same thing again
        // (the code expired), and Hermes's loop breaker sends it to triage: it comes back. 待你处理
        // is in front, so that is no notification.
        answer("验证码是 135790（CI）", card: "t_grades", in: app)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.element("card-ask-t_grades", in: app).exists }, "the card stayed after 让它继续")
        let again = waitForText("又卡在同一处：验证码过期了，再发一个新的（CI）", in: app, timeout: 20)
        keep(window.screenshot(), "work-2-asks-again")
        XCTAssertTrue(again, "the card that stopped on the same thing again did not come back")
        XCTAssertFalse(cardNotes().contains { $0.card == "t_grades" }, "notified while 待你处理 was in front")

        // again: this time it hands the card in for review in a few seconds, while 整理第8回录音 is
        // done and 詩音's 把这周的日程排进日历 stops on a question for you
        answer("验证码是 864200（CI）", card: "t_grades", in: app)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.element("card-ask-t_grades", in: app).exists }, "the card stayed after 让它继续 again")

        // 课程's 工作记录: the cards it ran today, on both boards; not yesterday's, not 通勤's
        element("bot-study", in: app).click()
        let tab = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "工作记录")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no 工作记录 tab")
        tab.click()
        let other = element("work-t_receipt", in: app).waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "work-3-log")
        XCTAssertTrue(other, "the card it ran on the other board is not in its log")
        for card in ["t_rec8", "t_grades", "t_moodle"] {
            XCTAssertTrue(element("work-\(card)", in: app).exists, "\(card) is not in the log")
        }
        XCTAssertFalse(element("work-t_notes7", in: app).exists, "yesterday's card is in today's log")
        // archived since it was done today: read with include_archived for the log alone
        XCTAssertTrue(element("work-t_quiz", in: app).waitForExistence(timeout: 10), "the card archived since is not in the log")
        XCTAssertTrue(waitForText("已归档", in: app, timeout: 3), "the archived card does not say so")
        XCTAssertFalse(element("work-t_hw6", in: app).exists, "a card archived yesterday is in today's log")
        XCTAssertFalse(element("work-t_weather", in: app).exists, "通勤's card is in 课程's log")
        XCTAssertFalse(element("work-t_dl8", in: app).exists, "a card that never ran is in the log")
        XCTAssertTrue(waitForText("收据 12 张，记进了表格（CI）。", in: app, timeout: 3), "no handoff in the log")
        XCTAssertTrue(waitForText("中途出错", in: app, timeout: 3), "the run that crashed is not in the log")

        // the review, the done card and the question come as notifications: 课程's page is in front
        let told = waitUntil(timeout: 30) {
            let notes = self.cardNotes()
            return notes.contains { $0.card == "t_grades" && $0.title.contains("交去验收") }
                && notes.contains { $0.card == "t_rec8" && $0.title.hasSuffix("做完了") }
                && notes.contains { $0.card == "t_week" && $0.title.contains("卡住了") }
        }
        XCTAssertTrue(told, "missing notifications: \(cardNotes())")
        let review = cardNotes().first { $0.card == "t_grades" }
        XCTAssertEqual(review?.board, "study", "the notification does not say the card's board")
        XCTAssertTrue(review?.body.contains("成绩单下载好了") == true, "the handoff is not in the notification: \(String(describing: review))")
        XCTAssertTrue(cardNotes().first { $0.card == "t_week" }?.body.contains("你定一下") == true, "the question is not in its notification")
        // a card that stopped on you can be answered in its notification; one to check or done cannot
        let week = cardNotes().first { $0.card == "t_week" }
        XCTAssertEqual(week?.category, "card", "詩音's question cannot be answered in its notification")
        XCTAssertEqual(review?.category, "", "a card to check asks for an answer in its notification")
        XCTAssertEqual(cardNotes().first { $0.card == "t_rec8" }?.category, "", "a done card asks for an answer in its notification")
        // answered there, as typing into it would: the reply goes on the card, which goes on
        if let week {
            replyInNotification("排作业4（CI，从通知回复）", to: week.id)
            XCTAssertTrue(waitUntil(timeout: 10) { self.answered(week.id) }, "the app did not take the answer to the notification")
        }
        let handedIn = waitForText("交去验收", in: app, timeout: 10)
        keep(window.screenshot(), "work-4-log-updated")
        XCTAssertTrue(handedIn, "the log does not show the card handed in")

        // a card of the log opens on the side, from the other board too
        element("work-t_receipt", in: app).click()
        let detail = waitForText("原件在「副业」文件夹里（CI）。", in: app, timeout: 10)
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "work-5-log-detail")
        XCTAssertTrue(detail, "the card's comments did not show")
        XCTAssertTrue(waitForText("看板 side", in: app, timeout: 3), "the detail does not say the other board")

        // the archived card opens the same way: 已归档, what it handed in, its run
        let quiz = element("work-t_quiz", in: app)
        reveal(quiz, in: window, at: 0.45)
        quiz.click()
        let archivedDetail = waitForText("编号 t_quiz", in: app, timeout: 10)
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "work-5a-archived-detail")
        XCTAssertTrue(archivedDetail, "the archived card's detail did not open")

        // on the board page nothing is notified: a card made there runs and is done in front of you
        element("nav-board", in: app).click()
        XCTAssertTrue(waitForText("整理第8回录音（CI）", in: app, timeout: 10), "the board did not show")
        XCTAssertFalse(waitForText("核对第8回小测答案", in: app, timeout: 1), "an archived card is on the board page")

        // 詩音's card answered from its notification: in 排队 (ready) again, your reply on it
        let resumed = waitUntil(timeout: 10) { self.inColumn("把这周的日程排进日历（CI）", "queued", in: app) }
        element("card-t_week", in: app).click()
        let replied = waitForText("排作业4（CI，从通知回复）", in: app, timeout: 10)
        let authors = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "comment-author-"))
        let yours = waitUntil(timeout: 5) { (0..<authors.count).contains { self.says(authors.element(boundBy: $0), "你") } }
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "work-6a-answered-in-notification")
        XCTAssertTrue(resumed, "the card answered in its notification did not go on")
        XCTAssertTrue(replied, "the reply from the notification is not on the card")
        XCTAssertTrue(yours, "the reply from the notification is not shown as yours")
        XCTAssertFalse(cardNotes().contains { $0.title == "没能回复" }, "the reply did not go through: \(cardNotes())")
        make("在看板上做完的卡（CI 通知）", in: app)
        let doneHere = waitUntil(timeout: 20) { self.inColumn("在看板上做完的卡（CI 通知）", "done", in: app) }
        Thread.sleep(forTimeInterval: 1)
        keep(window.screenshot(), "work-6-done-on-board")
        XCTAssertTrue(doneHere, "the card made on the board was not done")
        XCTAssertFalse(cardNotes().contains { $0.body.contains("在看板上做完的卡") }, "notified while the board was in front")

        // done cards can be left out: Settings, then a card that is done while you are on 今天
        app.typeKey(",", modifierFlags: .command)
        let prefs = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(prefs.waitForExistence(timeout: 5), "no Settings window")
        serverTab(prefs)
        XCTAssertTrue(element("board-notify-done", in: prefs).waitForExistence(timeout: 5), "no setting for done cards")
        let toggle = switchOf("board-notify-done", in: prefs)
        reveal(toggle, in: prefs)
        let off = turnOff(toggle)
        // the switch slides over: the picture once it has
        Thread.sleep(forTimeInterval: 0.8)
        keep(prefs.screenshot(), "work-7-settings")
        XCTAssertNotEqual(off, false, "the setting did not turn off: \(toggle.elementType.rawValue) \(String(describing: toggle.value))")
        app.typeKey("w", modifierFlags: .command)
        make("离开看板后做完的卡（CI 通知）", in: app)
        element("nav-today", in: app).click()
        Thread.sleep(forTimeInterval: 9)
        element("nav-board", in: app).click()
        let doneAway = waitUntil(timeout: 15) { self.inColumn("离开看板后做完的卡（CI 通知）", "done", in: app) }
        XCTAssertTrue(doneAway, "the second card was not done")
        XCTAssertFalse(cardNotes().contains { $0.body.contains("离开看板后做完的卡") }, "notified about a done card with that turned off")

        // 打开卡片 in 待你处理 opens it on its board: the other board's card switches the board
        element("nav-confirm", in: app).click()
        let open = element("card-ask-open-t_bank", in: app)
        XCTAssertTrue(open.waitForExistence(timeout: 10), "no 打开卡片 on the other board's card")
        XCTAssertFalse(element("card-ask-t_week", in: app).exists, "the card answered in its notification still waits on you")
        reveal(open, in: window)
        open.click()
        let opened = waitForText("银行要你在手机上点一下确认", in: app, timeout: 10) && waitForText("看板 side", in: app, timeout: 5)
        let switched = waitForText("整理副业发票（CI）", in: app, timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "work-8-opened-on-its-board")
        XCTAssertTrue(opened, "the card did not open")
        XCTAssertTrue(switched, "the board did not switch to the card's")
        print("notifications written down:\n\(cardNotes().map { "\($0.card) \($0.title) | \($0.body)" }.joined(separator: "\n"))")
        app.terminate()
    }

    /// A notification about a card, as the test run wrote it down: what it says, what can be
    /// answered in it (its category), and where a click goes.
    private struct Note: CustomStringConvertible {
        let id: String
        let card: String
        let board: String
        let title: String
        let body: String
        let category: String

        var description: String { "\(card)@\(board): \(title) / \(body) [\(category)]" }
    }

    /// The card notifications so far (the others, replies and approvals, are left out).
    private func cardNotes() -> [Note] {
        guard let text = try? String(contentsOfFile: notes, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let info = row["info"] as? [String: Any], let card = info["card"] as? String
            else { return nil }
            return Note(id: row["id"] as? String ?? "", card: card, board: info["board"] as? String ?? "",
                        title: row["title"] as? String ?? "", body: row["body"] as? String ?? "",
                        category: row["category"] as? String ?? "")
        }
    }

    /// Answers a notification as typing into it and sending would: a distributed notification the
    /// app takes in test runs (the test runner may not write files the app can see).
    private func replyInNotification(_ text: String, to id: String) {
        guard let json = try? JSONSerialization.data(withJSONObject: ["id": id, "action": "card-reply", "text": text]) else {
            return XCTFail("the answer could not be written")
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("dev.shion.test.answer"), object: String(decoding: json, as: UTF8.self), userInfo: nil,
            deliverImmediately: true)
    }

    /// Whether the app noted, in its notification log, that it took the answer to `id`.
    private func answered(_ id: String) -> Bool {
        guard let text = try? String(contentsOfFile: notes, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
            return row["answered"] as? String == id
        }
    }

    @MainActor
    private func says(_ element: XCUIElement, _ text: String) -> Bool {
        element.exists && (element.label == text || (element.value as? String) == text)
    }

    /// Writes `text` on a card in 待你处理 and lets it go on.
    @MainActor
    private func answer(_ text: String, card: String, in app: XCUIApplication) {
        let field = element("card-ask-reply-\(card)", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no reply field on \(card)")
        field.click()
        field.typeText(text)
        element("card-ask-resume-\(card)", in: app).click()
    }

    /// A new card for 课程 from the board page's 「＋」.
    @MainActor
    private func make(_ title: String, in app: XCUIApplication) {
        element("new-card", in: app).click()
        let field = element("new-card-title", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no new-card sheet")
        field.click()
        field.typeText(title)
        element("new-card-create", in: app).click()
        XCTAssertTrue(waitForText(title, in: app, timeout: 10), "the new card did not show")
    }

    /// Whether a card titled `title` shows in one of the board page's columns: a text with its
    /// title inside the column's frame, as BoardTests checks a drag. A text's words are its value
    /// on macOS, its label mostly empty.
    @MainActor
    private func inColumn(_ title: String, _ column: String, in app: XCUIApplication) -> Bool {
        let box = element("board-column-\(column)", in: app)
        guard box.exists else { return false }
        let area = box.frame
        let texts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title))
        for index in 0..<texts.count {
            let text = texts.element(boundBy: index)
            if text.exists && area.contains(CGPoint(x: text.frame.midX, y: text.frame.midY)) {
                return true
            }
        }
        return false
    }

    /// A toggle's switch. Its identifier goes to its label's texts as well (a row's goes to each of
    /// its parts), so the switch is looked for first, as BotsTests does.
    @MainActor
    private func switchOf(_ identifier: String, in root: XCUIElement) -> XCUIElement {
        let control = root.switches.matching(identifier: identifier).firstMatch
        if control.exists { return control }
        let box = root.checkBoxes.matching(identifier: identifier).firstMatch
        return box.exists ? box : element(identifier, in: root)
    }

    /// A switch's state: its value is a number (or its text) on macOS. Nil when it is no switch:
    /// a text's value is its words.
    @MainActor
    private func isOn(_ toggle: XCUIElement) -> Bool? {
        guard toggle.exists else { return nil }
        if let number = toggle.value as? NSNumber { return number.boolValue }
        switch (toggle.value as? String)?.lowercased() {
        case "1", "on": return true
        case "0", "off": return false
        default: return nil
        }
    }

    /// Turns a switch off: true when it reads off then, nil when its state cannot be read (the
    /// notifications that follow tell then).
    @MainActor
    private func turnOff(_ toggle: XCUIElement) -> Bool? {
        print("the switch for done cards: \(toggle.elementType.rawValue), value \(String(describing: toggle.value))")
        if isOn(toggle) != false {
            toggle.click()
        }
        if waitUntil(timeout: 5, { self.isOn(toggle) == false }) { return true }
        return isOn(toggle) == nil ? nil : false
    }

    /// Settings opens on the tab it was last left on (BotsTests leaves 助手): 服务器.
    @MainActor
    private func serverTab(_ settings: XCUIElement) {
        guard !settings.textFields["server-address"].waitForExistence(timeout: 1) else { return }
        let tabs = [settings.toolbarButtons["服务器"], settings.toolbars.buttons["服务器"], settings.buttons["服务器"],
                    settings.radioButtons["服务器"]]
        if let tab = tabs.first(where: { $0.exists }) {
            tab.click()
        } else {
            settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "服务器")).firstMatch.click()
        }
        XCTAssertTrue(settings.textFields["server-address"].waitForExistence(timeout: 5), "no 服务器 tab in Settings")
    }

    /// Scrolls a window's page until `target` can be clicked, the wheel turning at `dx` across the
    /// window: its right margin, where no row takes it, unless an inspector is there. Which sign of
    /// a delta scrolls down is the runner's business, so one way a few times, then the other.
    @MainActor
    private func reveal(_ target: XCUIElement, in window: XCUIElement, at dx: CGFloat = 0.97) {
        let margin = window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.6))
        for delta: CGFloat in [-300, -300, -300, 300, 300, 300, 300, 300, 300] {
            if target.exists && target.isHittable { return }
            margin.hover()
            margin.scroll(byDeltaX: 0, deltaY: delta)
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    @MainActor
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field \(field)")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
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
}
