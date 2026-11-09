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
        // read again from the transcript, which keeps the call but not the card's id
        element("nav-todos", in: app).click()
        Thread.sleep(forTimeInterval: 1)
        element("bot-shion", in: app).click()
        let reread = waitUntil(timeout: 10) { self.chatCards("整理第8回笔记（CI）", saying: "完成", in: app) >= 2 }
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
        app.terminate()
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
}
