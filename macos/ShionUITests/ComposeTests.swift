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
///    is marked as part of the turn, and the reply says it heard it; a message the turn does not
///    take says so (not 没发出去) and goes again only on 再发一次, as a message of its own; and
///    what is said in 今天's field waits for the turn to end, though the composer is set to 引导;
/// 4. a turn that wrote to another assistant and then failed: the message is a card, and 重试 asks
///    first, naming it;
/// 5. a turn with nothing to say (`[SILENT]`) leaves no bubble; what its review kept is a card,
///    and the skill it wrote is a card to look at, approved from 待你处理;
/// 6. a second change to the skill is talked over in a session of its own, and rejected there.
///    Hermes cannot make that session the first time (`reviewWaitsForItsSession`): nothing can be
///    sent, what is typed stays typed, and 再试一次 makes it; then the words go and are answered;
/// 7. that session holds whatever becomes of a message or a turn (`reviewTalkHolds`): a message
///    Hermes refused stays where it was said, with 重发, and what was typed meanwhile stays in the
///    composer; a turn that failed is asked again by 再试一次; a reply goes on after this socket
///    lost the session's events (`session.replay_gap`), and stays, the talk not left answering,
///    when the turn ends behind every snapshot asked for meanwhile; a message sent as the
///    connection went is settled by the session once it is back, sent again only when Hermes does
///    not have it.
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

        // 3b. another long reply, the composer still on 引导. A message the turn does not take
        // (Hermes answers `rejected` and does not say no assistant saw it): it says so, not
        // 没发出去, is not sent again by itself, and 再发一次 sends it as a message of its own
        composer.click()
        composer.typeText("讲一个长故事")
        send.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the second story did not start")
        composer.click()
        composer.typeText("别接这一句（CI）")
        send.click()
        let declined = element("declined", in: app)
        let saysDeclined = declined.waitForExistence(timeout: 10)
        keep(window.screenshot(), "compose-4b-declined")
        XCTAssertTrue(saysDeclined, "a message the turn did not take does not say so")
        XCTAssertFalse(element("unsent", in: app).exists, "it says 没发出去, though the assistant may have seen it")
        XCTAssertFalse(waitForText("听到了：别接这一句", in: app, timeout: 1), "the stand-in took the message it declines")
        XCTAssertFalse(waitForText("收到：别接这一句", in: app, timeout: 1), "the declined message was sent again by itself")
        let again = element("resend", in: app)
        // in view, not under the composer: the chat follows the line that came under the message
        // (run 195: the click went to the composer, and nothing was sent again)
        if again.waitForExistence(timeout: 5), waitUntil(timeout: 5, { again.isEnabled && again.isHittable }) {
            XCTAssertTrue(again.label.contains("再发一次") || app.buttons["再发一次"].exists,
                          "the way to send a declined message again is not 再发一次: \(again.label)")
            // the reply above is still arriving, and each new line of it moves this one for a
            // moment: a press that falls in that moment lands beside it (run 199), so press again
            var pressed = false
            for _ in 0..<3 where !pressed {
                if again.exists, again.isHittable { again.click() }
                pressed = waitUntil(timeout: 4) { !declined.exists }
            }
            XCTAssertTrue(pressed, "it still says the turn did not take it after 再发一次")
        } else {
            XCTFail("no 再发一次 to press under the declined message (there: \(again.exists), in view: \(again.exists && again.isHittable))")
        }
        // 今天's field: a turn of its own behind the story, not put into it, whatever the composer says
        element("nav-today", in: app).click()
        let todayField = app.textFields["today-ask"]
        if todayField.waitForExistence(timeout: 5) {
            todayField.click()
            todayField.typeText("今天页的话（CI）")
            app.typeKey(.return, modifierFlags: [])
        } else {
            XCTFail("no field on 今天 to say something to 詩音")
            chief.click()
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "今天's field did not open 詩音's chat")
        XCTAssertFalse(waitForText("听到了：今天页的话", in: app, timeout: 3), "what 今天's field said went into the running turn")
        // the story is stopped (unless it ran out meanwhile), and what waited behind it is answered, in order
        if stop.exists {
            stop.click()
        }
        XCTAssertTrue(waitUntil(timeout: 20) { !stop.exists }, "the second story did not end")
        let resentAnswered = waitForText("收到：别接这一句（CI）", in: app, timeout: 20)
        let todayAnswered = waitForText("收到：今天页的话（CI）", in: app, timeout: 20)
        keep(window.screenshot(), "compose-4c-behind-the-turn")
        XCTAssertTrue(resentAnswered, "再发一次 did not send the declined message as one of its own")
        XCTAssertTrue(todayAnswered, "what 今天's field said was not answered once the turn ended")

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
        let asked = text("学一个技能（CI）", in: app)
        if filed && asked.exists {
            XCTAssertGreaterThan(card.frame.minY, asked.frame.minY, "the skill's card is above the message that led to it")
        }
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
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the review did not open")
        // Hermes cannot make the session the first time it is asked (ci/fake_skills.py)
        let typed = reviewWaitsForItsSession(app, sheet: sheet, window: window)
        let talked = waitForText("审核意见（CI）", in: app, timeout: 20)
        keep(window.screenshot(), "compose-8-review")
        XCTAssertTrue(talked, "the assistant did not give its opinion in the review")
        XCTAssertTrue(element("skill-review-material", in: app).exists, "what the assistant was given is not there to open")
        XCTAssertFalse(waitForText("收到：", in: sheet, timeout: 1), "the review went to the Bot Chat's script")
        if let typed {
            // what was typed with no session to send it to is still there, and goes now
            let words = element("composer", in: sheet)
            let go = element("send", in: sheet)
            XCTAssertEqual(words.value as? String, typed, "making the session took what was typed before there was one")
            XCTAssertTrue(waitUntil(timeout: 10) { go.isEnabled }, "it cannot be sent though the session is there")
            go.click()
            XCTAssertTrue(waitForText("审核回复（CI）：\(typed)", in: sheet, timeout: 15),
                          "what was typed before the session was made was not answered once it went")
        }
        // the card in the review, not the one in the chat under it
        element("skill-review-reject-sr_ci2", in: sheet).click()
        // the dialog's button in the window, by its identifier if the dialog kept it, else by its
        // name: the Touch Bar has one of the same name, which takes no click (run 179)
        let confirm = app.windows.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                               "skill-review-reject-confirm", "拒绝并撤销")).firstMatch
        if confirm.waitForExistence(timeout: 5) {
            confirm.click()
        } else {
            XCTFail("拒绝 did not ask first")
        }
        let rejected = waitForText("已拒绝 · 已撤销", in: app, timeout: 10)
        keep(window.screenshot(), "compose-9-rejected")
        XCTAssertTrue(rejected, "the rejected card does not say so")

        // 7. the review's session, still open: what becomes of a message or a turn in it
        reviewTalkHolds(app, sheet: sheet, window: window)
        element("skill-review-close", in: app).click()
        XCTAssertTrue(waitUntil(timeout: 5) { !sheet.exists }, "the review did not close")
        // the Bot Chat was not written to
        XCTAssertFalse(waitForText("审核意见（CI）", in: app, timeout: 1), "the review's talk is in the Bot Chat")
        app.terminate()
    }

    // MARK: the review's session

    /// Step 6, as the review opens: the stand-in refuses to make a card's session the first time
    /// (ci/fake_skills.py: `storage_unavailable`, as Hermes answers when its store is busy). That
    /// is said over the composer, with 再试一次; until there is a session nothing can be sent, by
    /// the button or by Return, and what is typed stays typed. 再试一次 makes the session. Returns
    /// what it left in the composer, nil where it could not type.
    @MainActor
    private func reviewWaitsForItsSession(_ app: XCUIApplication, sheet: XCUIElement, window: XCUIElement) -> String? {
        let failure = element("skill-review-talk-failure", in: sheet)
        let again = element("skill-review-talk-retry", in: sheet)
        let said = failure.waitForExistence(timeout: 15)
        XCTAssertTrue(said, "a session Hermes could not make is not said")
        XCTAssertFalse(waitForText("审核意见（CI）", in: sheet, timeout: 1), "the review went on with no session")
        let composer = element("composer", in: sheet)
        let send = element("send", in: sheet)
        var typed: String?
        if said, composer.waitForExistence(timeout: 5) {
            let words = "先等一下（CI）"
            composer.click()
            composer.typeText(words)
            XCTAssertFalse(send.isEnabled, "it can be sent with no session to send it to")
            app.typeKey(.return, modifierFlags: [])
            // (a moment, in which a send would have emptied the composer)
            Thread.sleep(forTimeInterval: 1)
            let stays = (composer.value as? String) == words
            keep(window.screenshot(), "compose-8-review-no-session")
            XCTAssertTrue(stays, "what was typed with no session is gone: \(String(describing: composer.value))")
            typed = stays ? words : nil
        } else {
            keep(window.screenshot(), "compose-8-review-no-session")
        }
        if again.waitForExistence(timeout: 3) {
            again.click()
        } else {
            XCTFail("no 再试一次 beside the session that could not be made")
        }
        return typed
    }

    /// Step 7, in the review's sheet (ci/fake_skills.py scripts each sentence; the 「断线：」 ones are
    /// ci/fake_reconnect.py's, as in a Bot Chat). A message is never taken out of the talk nor put
    /// back in the composer, and never sent under a second id: the stand-in refuses 「排队满了（CI）」
    /// for good under another id, and drops the socket again for a 「断线：」 sentence it has not seen.
    @MainActor
    private func reviewTalkHolds(_ app: XCUIApplication, sheet: XCUIElement, window: XCUIElement) {
        let composer = element("composer", in: sheet)
        let send = element("send", in: sheet)
        guard composer.waitForExistence(timeout: 5) else { return XCTFail("no composer in the review") }
        let unsent = element("review-unsent", in: sheet)
        let unsure = element("review-unsure", in: sheet)
        let resend = element("review-resend", in: sheet)

        // a. refused, a moment after it was sent: it stays, saying so, and what was typed in the
        // meantime is still what the composer holds; 重发 sends it again under its own id
        composer.click()
        composer.typeText("排队满了（CI）")
        send.click()
        composer.click()
        composer.typeText("审核出错（CI）")
        let refused = unsent.waitForExistence(timeout: 20)
        keep(window.screenshot(), "compose-10-review-unsent")
        // (what a message says under it is part of its row: there, the message is still in the talk)
        XCTAssertTrue(refused, "a message Hermes refused is gone, or does not say it did not go")
        XCTAssertTrue(waitForText("排队的消息太多了", in: sheet, timeout: 2), "it does not say why, in Hermes's reason")
        XCTAssertEqual(composer.value as? String, "审核出错（CI）", "the composer does not hold what was typed while it was on its way")
        if resend.waitForExistence(timeout: 3) {
            resend.click()
        } else {
            XCTFail("no 重发 under the refused message")
        }
        XCTAssertTrue(waitForText("审核回复（CI）：排队满了（CI）", in: sheet, timeout: 15), "重发 did not get it answered")
        XCTAssertTrue(waitUntil(timeout: 5) { !unsent.exists }, "it still says it did not go")
        XCTAssertEqual(composer.value as? String, "审核出错（CI）", "重发 changed what the composer holds")

        // b. the sentence typed meanwhile: its turn fails, which is said until 再试一次 has asked
        // it again; the turn that failed is taken back, so the question is there once
        XCTAssertTrue(waitUntil(timeout: 10) { send.isEnabled }, "the review still answers after the reply ended")
        send.click()
        let failure = element("skill-review-talk-failure", in: sheet)
        let failed = failure.waitForExistence(timeout: 15) && waitForText("这一轮出错了", in: sheet, timeout: 5)
        keep(window.screenshot(), "compose-11-review-failed")
        XCTAssertTrue(failed, "a turn that failed in the review does not say so")
        XCTAssertFalse(waitForText("rate-limited", in: sheet, timeout: 1), "Hermes's words about the failure show as a reply")
        let again = element("skill-review-talk-retry", in: sheet)
        if again.waitForExistence(timeout: 3) {
            again.click()
        } else {
            XCTFail("no 再试一次 beside the failure")
        }
        XCTAssertTrue(waitForText("（重试）审核回复（CI）：审核出错（CI）", in: sheet, timeout: 20), "再试一次 did not ask the failed turn again")
        XCTAssertTrue(waitUntil(timeout: 5) { !failure.exists }, "the failure is still said after the turn was answered")

        // c. a reply during which this socket loses the session's events, the socket kept: the
        // session is attached again, the reply is whole, and the talk is not left answering
        composer.click()
        composer.typeText("订阅断了（CI）")
        XCTAssertTrue(waitUntil(timeout: 10) { send.isEnabled }, "the review still answers after the retried turn ended")
        send.click()
        let whole = waitForText("第2节。第3节。第4节。", in: sheet, timeout: 20) && waitForText("第8节。", in: sheet, timeout: 20)
        keep(window.screenshot(), "compose-12-review-gap")
        XCTAssertTrue(whole, "the reply did not go on after the session's events stopped on this socket")

        // d. the same loss, and from there the session's frames overtake every snapshot asked for
        // (Hermes answers `session.resume` a moment after reading the session, behind what it
        // published meanwhile): each still calls the turn running and has no row of the reply,
        // and the turn ends behind the last one asked for. What the frames brought stands: the
        // reply is whole and stays, and the talk is not left answering
        let behind = "第1段。第2段。第3段。第4段。第5段。第6段。"
        composer.click()
        composer.typeText("快照迟到（CI）")
        XCTAssertTrue(waitUntil(timeout: 15) { send.isEnabled }, "the review is left answering after the reply that lost its events")
        send.click()
        let ended = waitForText("第6段。", in: sheet, timeout: 30)
        keep(window.screenshot(), "compose-12-review-behind")
        XCTAssertTrue(ended, "the turn did not end behind the snapshots asked for (see the stand-in's log)")
        XCTAssertFalse(waitForText("没按剧本", in: sheet, timeout: 1),
                       "the snapshot was not asked for as often as ci/fake_skills.py scripts (BEHIND_ASKS)")

        // e. sent as the connection goes, before Hermes has it: unsure while away; back, the
        // session does not have it, so it says 没发出去, and 重发 sends it under its own id
        composer.click()
        composer.typeText("断线：没收到")
        XCTAssertTrue(waitUntil(timeout: 15) { send.isEnabled }, "the review is left answering by a snapshot older than the turn's end")
        // (the last snapshot has come by now: typing takes longer than its answer)
        XCTAssertTrue(waitForText(behind, in: sheet, timeout: 3), "a snapshot older than the reply took it away, or part of it")
        send.click()
        let doubted = unsure.waitForExistence(timeout: 15)
        keep(window.screenshot(), "compose-13-review-unsure")
        XCTAssertTrue(doubted, "a message whose receipt did not come is gone, or does not say it is not known yet")
        // (an empty field's value is its placeholder)
        XCTAssertNotEqual(composer.value as? String, "断线：没收到", "its words were put back in the composer")
        StandIn.tunnelUp("the review's message that never got there")
        let notThere = unsent.waitForExistence(timeout: 45)
        keep(window.screenshot(), "compose-14-review-not-there")
        XCTAssertTrue(notThere, "back, the session does not have it, and the message does not say 没发出去")
        if notThere, resend.waitForExistence(timeout: 3) {
            XCTAssertTrue(waitUntil(timeout: 20) { resend.isEnabled }, "重发 cannot be clicked once connected")
            resend.click()
        }
        let answered = waitForText("审核回复（CI）：断线：没收到", in: sheet, timeout: 20)
        XCTAssertTrue(answered, "重发 after the connection came back did not get it answered")
        if !answered {
            // sent under another id, the stand-in dropped the socket again: back, for what follows
            StandIn.tunnelUp("the review's message sent again under another id")
        }
        XCTAssertTrue(waitUntil(timeout: 5) { !unsent.exists && !unsure.exists }, "it still says it is not there")
        // the session read again on the new socket, a snapshot that has the row of d's reply
        XCTAssertTrue(waitForText(behind, in: sheet, timeout: 3), "d's reply is gone once the session was read again")

        // f. admitted, its receipt lost with the connection, and answered while away: back, the
        // session has it and the answer, and nothing is sent again
        composer.click()
        composer.typeText("断线：还没回执")
        XCTAssertTrue(waitUntil(timeout: 15) { send.isEnabled }, "the review still answers after the message sent again")
        send.click()
        XCTAssertTrue(unsure.waitForExistence(timeout: 15), "a message admitted without a receipt does not say it is not known yet")
        StandIn.tunnelUp("the review's message admitted without its receipt")
        let settled = waitForText("收到：断线：还没回执", in: sheet, timeout: 45)
        keep(window.screenshot(), "compose-15-review-settled")
        XCTAssertTrue(settled, "the answer that came while away is not in the review")
        XCTAssertTrue(waitUntil(timeout: 10) { !unsure.exists && !unsent.exists },
                      "the message Hermes has still says it is not known, or that it did not go")
        XCTAssertFalse(resend.exists, "重发 under a message Hermes has")
        // the card still answers to the server: the connection is whole again
        XCTAssertTrue(waitUntil(timeout: 20) { send.exists && composer.isEnabled }, "the review cannot be written in after reconnecting")
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
