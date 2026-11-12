import AppKit
import XCTest

/// Writing to an assistant, and what the chat shows around its messages, end to end against
/// ci/fake_hermes.py (fake_control.py and fake_skills.py play Hermes's parts). Signs in as
/// SignInTests does, then in 詩音's chat:
/// 1. what is typed stays in the composer while another page is looked at, and ⇧Return breaks the
///    line instead of sending;
/// 2. a turn that answered has no 重试; a message is answered from the buttons over it, and goes
///    out as Hermes words a reply, shown back as a quote;
/// 3. while a long reply streams, 引导 puts the next message into that turn (`session.steer`): it
///    is marked as part of the turn, and the reply says it heard it;
/// 4. a turn that wrote to another assistant and then failed: the message is a card, and 重试 asks
///    first, naming it;
/// 5. a turn with nothing to say (`[SILENT]`) leaves no bubble; what its review kept is a card,
///    and the skill it wrote is a card to look at, approved from 待你处理;
/// 6. a second change to the skill is talked over in a session of its own, and rejected there.
/// A picture at each step (compose-*.png).
final class ComposeTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"

    @MainActor
    func testComposerRepliesBusyAndSkillReviews() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "today",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))

        // signed in through the stand-in's browser sheet, as SignInTests does
        app.typeKey(",", modifierFlags: .command)
        let settings = settingsWindow(app)
        guard settings.waitForExistence(timeout: 5) else {
            keep(XCUIScreen.main.screenshot(), "compose-0-no-settings")
            return XCTFail("No Settings window")
        }
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        settings.buttons["sign-in"].click()
        let state = element("connection-state", in: settings)
        guard XCTWaiter().wait(for: [phase("已连接 ·", of: state)], timeout: 60) == .completed else {
            keep(XCUIScreen.main.screenshot(), "compose-0-not-connected")
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }
        // how a message sent during a turn reaches the assistant is a setting too
        XCTAssertTrue(element("busy-mode-setting", in: settings).waitForExistence(timeout: 5), "no 助手还在忙时 in Settings")
        app.typeKey("w", modifierFlags: .command)

        let chief = element("bot-shion", in: app)
        XCTAssertTrue(chief.waitForExistence(timeout: 10), "no assistants from the server")
        chief.click()
        XCTAssertTrue(waitForText("CI 替身服务器连上了", in: app, timeout: 15), "詩音's chat did not open")
        let composer = element("composer", in: app)
        let send = element("send", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))

        // 1. the draft stays while another page is looked at; ⇧Return breaks the line, sends nothing
        composer.click()
        composer.typeText("draft one")
        element("nav-todos", in: app).click()
        chief.click()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "draft one", "the draft did not stay while another page was open")
        composer.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.return, modifierFlags: .shift)
        composer.typeText("line two")
        let broken = waitUntil(timeout: 3) { (composer.value as? String) == "draft one\nline two" }
        keep(window.screenshot(), "compose-1-draft")
        XCTAssertTrue(broken, "⇧Return did not break the line: \(String(describing: composer.value))")
        XCTAssertFalse(waitForText("收到：draft", in: app, timeout: 1), "⇧Return sent the draft")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])

        // 2. a turn that answered has nothing to try again, though it called a tool
        composer.typeText("查一下明天的天气")
        send.click()
        XCTAssertTrue(waitForText("明天晴，最高 18 度", in: app, timeout: 15), "the weather turn did not reply")
        XCTAssertFalse(element("retry", in: app).waitForExistence(timeout: 2), "a turn that answered offers 重试")
        // answered from the buttons over it: the mark shows over the composer, and the message
        // goes out as a reply, the quote over its words
        let weather = text("明天晴，最高 18 度", in: app)
        weather.hover()
        let reply = element("message-reply", in: app)
        if reply.waitForExistence(timeout: 3) {
            reply.click()
        } else {
            // the menu has it too
            weather.rightClick()
            app.menuItems["回复"].firstMatch.click()
        }
        let marked = element("reply-target", in: app).waitForExistence(timeout: 5)
        keep(window.screenshot(), "compose-2-replying")
        XCTAssertTrue(marked, "no message marked to answer over the composer")
        composer.click()
        composer.typeText("那周末呢")
        send.click()
        let quoted = element("reply-quote", in: app).waitForExistence(timeout: 10)
        XCTAssertTrue(quoted, "the reply does not show the message it answers")
        XCTAssertTrue(waitForText("收到：[Replying to your previous message: \"明天晴，最高 18 度。\"]", in: app, timeout: 10),
                      "the reply did not go out as Hermes words one")
        XCTAssertFalse(element("reply-target", in: app).exists, "the mark stayed after the reply went")
        keep(window.screenshot(), "compose-3-replied")

        // 3. during a long reply, 引导 puts the next message into the turn that is running
        composer.click()
        composer.typeText("讲一个长故事")
        send.click()
        let stop = element("stop", in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 10) && waitForText("山里有座庙", in: app, timeout: 10), "the story did not start")
        let busy = element("busy-mode", in: app)
        XCTAssertTrue(busy.waitForExistence(timeout: 5), "no way to say how a message reaches a busy assistant")
        XCTAssertTrue(send.exists, "no send button while the turn runs")
        busy.click()
        let steer = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "引导")).firstMatch
        XCTAssertTrue(steer.waitForExistence(timeout: 5), "no 引导 in the menu")
        steer.click()
        composer.click()
        composer.typeText("讲短一点")
        send.click()
        let heard = waitForText("听到了：讲短一点", in: app, timeout: 15)
        let midTurn = element("mid-turn", in: app).waitForExistence(timeout: 5)
        keep(window.screenshot(), "compose-4-steered")
        XCTAssertTrue(heard, "the message did not reach the running turn")
        XCTAssertTrue(midTurn, "the message is not marked as part of the turn")
        XCTAssertTrue(waitUntil(timeout: 15) { !stop.exists }, "the turn did not end")
        XCTAssertFalse(waitForText("收到：讲短一点", in: app, timeout: 2), "the message also went as a turn of its own")
        XCTAssertFalse(element("retry", in: app).exists, "重试 under a turn that answered")

        // 4. a message to another assistant, then a failure: the message is a card, and 重试 asks
        // first, since it would go out again; 取消 leaves the chat as it is, 重试 goes ahead
        composer.click()
        composer.typeText("带个话再出错（CI）")
        send.click()
        let sent = waitForText("把第 8 回的课件发我一份（CI）。", in: app, timeout: 15)
        XCTAssertTrue(sent, "the message to the other assistant is not in the chat")
        XCTAssertTrue(waitForText("发给课程（CI）的消息", in: app, timeout: 5), "the message is not a card naming who it went to")
        XCTAssertTrue(element("turn-failed", in: app).waitForExistence(timeout: 15), "the turn did not fail")
        keep(window.screenshot(), "compose-5-sent-then-failed")
        let retry = element("retry", in: app)
        if retry.waitForExistence(timeout: 5) {
            retry.click()
            if let ask = question(in: app, timeout: 5) {
                let says = ask.staticTexts.allElementsBoundByIndex.map { "\($0.label) \(($0.value as? String) ?? "")" }
                    .joined(separator: " ")
                XCTAssertTrue(says.contains("发消息") && says.contains("可能会再做一次"), "the question does not name the message: \(says)")
                button("retry-cancel", "取消", in: ask).click()
                XCTAssertTrue(waitUntil(timeout: 3) { !ask.exists }, "取消 did not close the question")
                XCTAssertTrue(element("turn-failed", in: app).exists, "取消 changed the chat")
                element("retry", in: app).click()
                if let ask = question(in: app, timeout: 5) {
                    button("retry-confirm", "重试", in: ask).click()
                    XCTAssertTrue(waitForText("（重试）这次没出错。", in: app, timeout: 20), "the confirmed 重试 did not reply")
                } else {
                    XCTFail("重试 did not ask the second time")
                }
            } else {
                XCTFail("重试 after a message went out did not ask first")
            }
        } else {
            XCTFail("no 重试 under the failed turn")
        }

        // 5. nothing to say: no bubble for the marker; what the review kept is a card; the skill it
        // wrote is a card to look at, counted in 待你处理
        composer.click()
        composer.typeText("学一个技能（CI）")
        send.click()
        let learned = waitForText("学会了技能 ci-notes", in: app, timeout: 15)
        let card = element("skill-review-sr_ci1", in: app)
        let filed = card.waitForExistence(timeout: 15)
        keep(window.screenshot(), "compose-6-learned")
        XCTAssertTrue(learned, "what the review kept is not in the chat")
        XCTAssertTrue(filed, "the skill it wrote has no card")
        XCTAssertTrue(waitForText("已生效 · 待审核", in: app, timeout: 5), "the card does not say the skill is in effect")
        XCTAssertFalse(waitForText("[SILENT]", in: app, timeout: 1), "the marker for nothing to say shows")
        element("nav-confirm", in: app).click()
        XCTAssertTrue(element("waiting-审核技能", in: app).waitForExistence(timeout: 5), "no 审核技能 in 待你处理")
        keep(window.screenshot(), "compose-7-waiting")
        let approve = element("skill-review-approve-sr_ci1", in: app)
        XCTAssertTrue(approve.waitForExistence(timeout: 5), "no 批准 on the card")
        approve.click()
        XCTAssertTrue(waitUntil(timeout: 10) { !approve.exists }, "the approved card still waits")
        chief.click()
        XCTAssertTrue(waitForText("已批准", in: app, timeout: 10), "the card in the chat does not say it was approved")

        // 6. another change, talked over in a session of its own and rejected there
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("再改一下技能（CI）")
        send.click()
        XCTAssertTrue(waitForText("改好了（CI）。", in: app, timeout: 15), "the second turn did not reply")
        let open = element("skill-review-open-sr_ci2", in: app)
        guard open.waitForExistence(timeout: 15) else {
            keep(window.screenshot(), "compose-8-no-second-card")
            return XCTFail("the second change has no card")
        }
        open.click()
        let sheet = element("skill-review-sheet", in: app)
        let talked = sheet.waitForExistence(timeout: 10) && waitForText("审核意见（CI）", in: app, timeout: 20)
        keep(window.screenshot(), "compose-8-review")
        XCTAssertTrue(talked, "the assistant did not give its opinion in the review")
        XCTAssertTrue(element("skill-review-material", in: app).exists, "what the assistant was given is not there to open")
        XCTAssertFalse(waitForText("收到：", in: sheet, timeout: 1), "the review went to the Bot Chat's script")
        // the card in the review, not the one in the chat under it
        element("skill-review-reject-sr_ci2", in: sheet).click()
        let confirm = app.buttons["拒绝并撤销"].firstMatch
        if confirm.waitForExistence(timeout: 5) {
            confirm.click()
        } else {
            XCTFail("拒绝 did not ask first")
        }
        let rejected = waitForText("已拒绝 · 已撤销", in: app, timeout: 10)
        keep(window.screenshot(), "compose-9-rejected")
        XCTAssertTrue(rejected, "the rejected card does not say so")
        element("skill-review-close", in: app).click()
        XCTAssertTrue(waitUntil(timeout: 5) { !sheet.exists }, "the review did not close")
        // the Bot Chat was not written to
        XCTAssertFalse(waitForText("审核意见（CI）", in: app, timeout: 1), "the review's talk is in the Bot Chat")
        app.terminate()
    }

    // MARK: helpers

    @MainActor
    private func settingsWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
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

    /// The first text that has `words`, plain or selectable.
    @MainActor
    private func text(_ words: String, in app: XCUIApplication) -> XCUIElement {
        let either = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)
        let plain = app.staticTexts.matching(either).firstMatch
        return plain.exists ? plain : app.textViews.matching(either).firstMatch
    }

    private func phase(_ prefix: String, of element: XCUIElement) -> XCTNSPredicateExpectation {
        XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix), object: element)
    }

    /// The question over the window (an alert sheet), if one comes up within `timeout`.
    @MainActor
    private func question(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let places = [app.windows.sheets.firstMatch, app.sheets.firstMatch, app.windows.dialogs.firstMatch,
                      app.dialogs.firstMatch]
        var found: XCUIElement?
        _ = waitUntil(timeout: timeout) {
            found = places.first { $0.exists }
            return found != nil
        }
        return found
    }

    /// A button in `container`, by its identifier if the alert kept it, else by its name.
    @MainActor
    private func button(_ identifier: String, _ name: String, in container: XCUIElement) -> XCUIElement {
        let byIdentifier = container.buttons[identifier]
        return byIdentifier.exists ? byIdentifier : container.buttons[name]
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return false
    }

    /// Text anywhere under `root`, plain or selectable (see SignInTests).
    @MainActor
    private func waitForText(_ text: String, in root: XCUIElement, timeout: TimeInterval) -> Bool {
        let either = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        let queries = [
            root.staticTexts.matching(either),
            root.textViews.matching(either),
            root.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)),
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
