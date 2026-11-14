import AppKit
import XCTest

/// Dropped connections, end to end against ci/fake_hermes.py (fake_reconnect.py plays Hermes's side:
/// each session's frames numbered and kept, session.events.since, a resume that catches up what came
/// in between, a prompt admitted once per submission id). Signs in as SignInTests does, then in
/// 詩音's chat has the stand-in drop the socket at each moment that matters. The tunnel stays down
/// until the test has seen what it looks for while Shion is away and tells the stand-in so
/// (StandIn.tunnelUp); Shion is back at its next try:
/// 1. half way through a reply that goes on until Shion is back: the sidebar says 重新连接中… and
///    when it tries again; two sentences said meanwhile wait under the chat, saying when they were
///    written; once back, the rest of the reply streams into the same bubble, then the two go out,
///    in order, saying when they were written (the run counts them as written two hours before);
/// 2. into a reply that ends while the tunnel is down: once back, the bubble has all of it, and
///    nothing is still replying;
/// 2b. before turns Hermes starts by itself: the board's word that a card is done, as the gateway
///    wakes a session with it (only its row says so) and its card on no board any more, then the
///    same message from 课程 twice. Once back, each is one card (the replay's frames and the
///    transcript's row are the same notice), the board's saying which card it was and what was
///    handed in, not Hermes's words for the model, the two from 课程 both there, each ahead of the
///    reply it started;
/// 3. after a sentence was admitted, before its receipt: 等连上后确认 while down, then an ordinary
///    message with its answer, once;
/// 4. before a sentence was admitted: once back, 没发出去 with 重发, which sends it, once;
/// 5. while an approval waits: once back it is still in 待你处理, and answering it there lets the
///    turn finish in the same bubble;
/// 6. before a reply longer than the session keeps: the replay cannot reach back, the newest page
///    stands in, and the reply is there whole, once, with nothing still replying;
/// 7. not a drop: Hermes ends the subscription of a socket that cannot keep up (session.replay_gap)
///    and keeps the socket; what was missed comes back on it, and the reply is whole in one bubble;
/// 8. a picture and a file, before Hermes had them: once back, 没发出去 with 重发. The server
///    cleared the picture meanwhile, so the same submission is refused, and the picture goes up
///    again from the Mac under a new one; answered once, with both;
/// 9. as the same words are put into a running turn for the second time (引导), neither call
///    answered and one of the two stored: both say 不确定有没有送到 while down; once back the one
///    row confirms one of them, marked as part of the turn, and the other stays in doubt, also
///    after the two reconnects of the next step;
/// 10. after a reply, with the session's frames of another epoch once back (the replay cannot be
///    had, the newest page is read in the chat's place): the same words said again while the chat
///    is being attached again (the stand-in keeps that answer back until StandIn.attach), and that
///    request lost. The page's row in those words is the first saying's, so the message said again
///    stays under the page with 等连上后确认, then 没发出去 with 重发, which sends it, once;
/// 11. half way through a reply, and once back Hermes will not attach the chat again (its store
///    busy, the socket kept) until StandIn.attach: the chat keeps the reply it had, says what
///    failed with Hermes's reason and 再试一次 where both can be read and pressed, the rest of the
///    window where it was, and is not left replying; its own tries used up, 再试一次 attaches it
///    again, the reply is whole and what is said is answered.
/// A picture at each step (reconnect-*.png).
final class ReconnectTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"

    @MainActor
    func testDropsAndComingBack() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "today",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
            // what waits counts as written two hours before, to go out saying so
            "-ShionQuickWrittenAgo", "7200",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        guard signIn(app) else { return }

        // 课程's approval comes once its Bot Chat is attached: answered first, so that the one asked
        // later is the only one in 待你处理
        element("nav-confirm", in: app).click()
        if waitForText("要在课程的云桌面上登录 Moodle 吗？", in: app, timeout: 15) {
            app.buttons["拒绝"].firstMatch.click()
            XCTAssertTrue(waitUntil(timeout: 10) { !self.hasText("要在课程的云桌面上登录 Moodle 吗？", in: app) },
                          "课程's approval did not go once answered")
        } else {
            XCTFail("课程's approval did not come")
        }

        let chief = element("bot-shion", in: app)
        XCTAssertTrue(chief.waitForExistence(timeout: 10), "no assistants from the server")
        chief.click()
        XCTAssertTrue(waitForText("CI 替身服务器连上了", in: app, timeout: 15), "詩音's chat did not open")
        XCTAssertTrue(element("composer", in: app).waitForExistence(timeout: 5))

        // 1. half way through a reply
        say("断线：讲到一半", in: app)
        XCTAssertTrue(waitForText("第3段。", in: app, timeout: 10), "the reply did not start")
        let down = waitForText("重新连接中…", in: app, timeout: 10)
        let when = waitForText(" 再试", in: app, timeout: 5)
        keep(app.windows.firstMatch.screenshot(), "reconnect-1-reconnecting")
        XCTAssertTrue(down, "the sidebar does not say 重新连接中…")
        XCTAssertTrue(when, "the sidebar does not say when it tries again")
        XCTAssertFalse(element("stop", in: app).exists, "a turn can be stopped while not connected")
        say("排队的第一句", in: app)
        say("排队的第二句", in: app)
        let waits = element("waiting", in: app).waitForExistence(timeout: 5)
        keep(app.windows.firstMatch.screenshot(), "reconnect-2-waiting")
        XCTAssertTrue(waits, "what was said while not connected does not wait under the chat")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "waiting").count, 2, "not two sentences waiting")
        StandIn.tunnelUp("1. half way through a reply")
        XCTAssertTrue(waitUntil(timeout: 40) { !self.hasText("重新连接中…", in: app) }, "the connection did not come back")
        let rest = waitForText("第80段。", in: app, timeout: 40)
        keep(app.windows.firstMatch.screenshot(), "reconnect-3-back")
        XCTAssertTrue(rest, "the rest of the reply did not come")
        once("第1段。", whole: false, "the reply is not in one bubble", "reconnect-count-1", in: app)
        XCTAssertTrue(holds(["第1段。", "第6段。", "第80段。"], in: app), "the bubble does not have the whole reply")
        let first = waitForText("写的）排队的第一句", in: app, timeout: 20)
        let second = waitForText("写的）排队的第二句", in: app, timeout: 20)
        XCTAssertTrue(first && second, "what waited did not go out saying when it was written")
        XCTAssertTrue(waitForText("收到：（", in: app, timeout: 20), "what waited was not answered")
        XCTAssertTrue(waitUntil(timeout: 20) { self.hasText("排队的第二句", answered: true, in: app) },
                      "the second sentence was not answered")
        if let one = answer("排队的第一句", in: app), let two = answer("排队的第二句", in: app) {
            XCTAssertLessThan(one.frame.minY, two.frame.minY, "what waited went out out of order")
        }
        XCTAssertFalse(element("waiting", in: app).exists, "a sentence still waits once connected")
        keep(app.windows.firstMatch.screenshot(), "reconnect-3b-waited-sent")

        // 2. a reply that ends while the tunnel is down
        say("断线：讲完了", in: app)
        XCTAssertTrue(waitForText("第2句。", in: app, timeout: 10), "the short reply did not start")
        XCTAssertTrue(waitForText("重新连接中…", in: app, timeout: 10), "the socket did not drop")
        StandIn.tunnelUp("2. a reply that ends while the tunnel is down")
        XCTAssertTrue(waitUntil(timeout: 40) { !self.hasText("重新连接中…", in: app) }, "the connection did not come back")
        let ended = waitForText("第10句。", in: app, timeout: 15)
        keep(app.windows.firstMatch.screenshot(), "reconnect-4-ended-while-away")
        XCTAssertTrue(ended, "the end of a reply that ended while away did not come")
        once("第1句。", whole: false, "the short reply is not in one bubble", "reconnect-count-2", in: app)
        XCTAssertTrue(element("send", in: app).waitForExistence(timeout: 5), "a bubble is still replying")

        // 2b. what Hermes starts by itself while Shion is away, as Hermes itself gives each (tried
        // against a gateway with a stand-in model). The board's word on a card done (and on no
        // board any more) and a message from 课程: nothing of either in the turn's start, only in
        // the row. Then 课程's answer to a message of 詩音's, which Hermes hands back as the end of
        // a background process, twice in the same words: each as a frame from the replay (which
        // says neither when nor which row) and as a row. One card each
        say("断线：回传", in: app)
        XCTAssertTrue(waitForText("好（CI）。", in: app, timeout: 10), "the short reply did not come")
        XCTAssertTrue(waitForText("重新连接中…", in: app, timeout: 10), "the socket did not drop")
        StandIn.tunnelUp("2b. what Hermes started by itself while away")
        XCTAssertTrue(waitUntil(timeout: 40) { !self.hasText("重新连接中…", in: app) }, "the connection did not come back")
        XCTAssertTrue(waitForText("课表的事知道了（CI）。", in: app, timeout: 20), "the turns Hermes started while away did not come")
        let notice = element("board-notice", in: app)
        // the notice's row is read a moment after its turn's frames
        let rowRead = notice.waitForExistence(timeout: 15)
        let peer = waitUntil(timeout: 10) { self.cards("event-card", holding: "收到（CI）", in: app) == 1 }
        keep(app.windows.firstMatch.screenshot(), "reconnect-4b-notices-while-away")
        XCTAssertTrue(rowRead, "the board's word on the card is not a card of its own")
        XCTAssertEqual(cards("board-notice", holding: "归档旧发票（CI）", in: app), 1,
                       "the board's notice is not one card that still names its card, gone from the board")
        XCTAssertTrue(holds("做完了：发票都归好了（CI）。", whole: false, in: notice), "the notice does not say what was handed in")
        XCTAssertFalse(hasText("[kanban]", in: app), "the board's notice shows as Hermes worded it for the assistant")
        XCTAssertFalse(hasText("automatic task-status notification", in: app), "what Hermes tells the model shows in the chat")
        // 课程's message: a card from its row alone, Hermes's label on it in the chat's words
        XCTAssertTrue(peer, "课程's message, which only its row says, is not one card: "
                      + "\(cards("event-card", holding: "收到（CI）", in: app))")
        XCTAssertEqual(cards("event-card", holding: "要回：一句话", in: app), 1, "what 课程 wants back is not on its card")
        XCTAssertFalse(hasText("Reply needed", in: app), "Hermes's own label shows on 课程's message")
        // 课程's answers: its words on a card under its name, twice, not the command that waited
        // for them. Counted by where the words stand: run 199 found three elements for the two
        // cards in the window, both of which took the place of a frame's card
        let answered = waitUntil(timeout: 10) { self.places("下周的课表排好了（CI）。", in: app).count == 2 }
        note(eventCards(in: app), "reconnect-notices")
        XCTAssertTrue(answered, "the same answer from 课程 twice is not two cards: \(places("下周的课表排好了（CI）。", in: app))")
        XCTAssertEqual(places("课程（CI） 发来的消息", in: app).count, 2, "an answer is not said to be from 课程")
        XCTAssertFalse(hasText("Background Process Finished", in: app), "an answer shows as the process that waited for it")
        XCTAssertFalse(hasText("bot_mode_dm", in: app), "the command that waited for an answer shows in the chat")
        XCTAssertFalse(hasText("[SILENT]", in: app), "the marker of a turn with nothing to say shows")
        // each where it came: the board's card under the reply before it (run 197: placed by its
        // row's time, it went above that reply), every card ahead of the reply it started, and the
        // first answer, which started none, ahead of the second
        func tops(_ words: String) -> [CGFloat] {
            app.descendants(matching: .any).matching(identifier: "event-card").allElementsBoundByIndex
                .filter { self.holds(words, whole: false, in: $0) }.map { $0.frame.minY }.sorted()
        }
        let said = tops("收到（CI）"), answers = places("下周的课表排好了（CI）。", in: app)
        let replies = ["课程把旧发票归好了（CI）。", "知道课程收到了（CI）。", "课表的事知道了（CI）。"]
            .compactMap { texts($0, whole: false, in: app).first?.frame.minY }
        let earlier = replies.first.flatMap { first in
            texts("好（CI）。", whole: true, in: app).map { $0.frame.minY }.filter { $0 < first }.max()
        }
        if said.count == 1, answers.count == 2, replies.count == 3, let earlier {
            let order = [earlier, notice.frame.minY, replies[0], said[0], replies[1], answers[0], answers[1], replies[2]]
            XCTAssertEqual(order, order.sorted(), "the cards and the replies they started are out of order")
        } else {
            XCTFail("not the cards, the replies and the reply before them to tell the order of: "
                    + "\(said.count), \(answers.count), \(replies.count), \(earlier != nil)")
        }

        // 2c. more turns while away than the newest rows first read can show: eight messages from
        // 课程, each a turn whose start says nothing, then two results folded into one turn (课程's
        // answer and a command that failed). Each result has its card, neither hiding the other
        // under a count; and every one of the eight messages has its card, the transcript being
        // read further up for the ones the newest rows do not reach: the first four are above a
        // page of the fourth turn's tool calls alone, whose rows have no number
        say("断线：很多", in: app)
        XCTAssertTrue(waitForText("好的（CI）。", in: app, timeout: 10), "the short reply did not come")
        XCTAssertTrue(waitForText("重新连接中…", in: app, timeout: 10), "the socket did not drop")
        StandIn.tunnelUp("2c. many turns Hermes started by itself while away")
        XCTAssertTrue(waitUntil(timeout: 40) { !self.hasText("重新连接中…", in: app) }, "the connection did not come back")
        XCTAssertTrue(waitForText("两件事都知道了（CI）。", in: app, timeout: 20), "the turns Hermes started while away did not come")
        let both = waitUntil(timeout: 15) {
            self.places("周五有空（CI）。", in: app).count == 1
                && self.cards("event-card", holding: "No space left on device（CI）", in: app) >= 1
        }
        keep(app.windows.firstMatch.screenshot(), "reconnect-4c-many-while-away")
        XCTAssertTrue(both, "two results folded into one turn are not a card each: the answer "
                      + "\(places("周五有空（CI）。", in: app).count), the failed command "
                      + "\(cards("event-card", holding: "No space left on device（CI）", in: app))")
        XCTAssertTrue(cards("event-card", holding: "exit code 1", in: app) >= 1 && cards("event-card", holding: "./backup.sh", in: app) >= 1,
                      "the command that failed does not say which it was and how it ended")
        XCTAssertFalse(hasText("2 Background Processes Finished", in: app), "the two results show as a count")
        XCTAssertFalse(hasText("bot_mode_dm", in: app), "the command that waited for the answer shows in the chat")
        // the cards were read from their rows after the reply they led to was there, and put
        // before it: the chat, followed at its end, stays at its end, the newest reply in view and
        // not pushed under the composer by what came in above it
        let newest = "两件事都知道了（CI）。"
        XCTAssertTrue(waitUntil(timeout: 5) { self.inView(newest, in: app) },
                      "the newest reply is not in view once the cards came in above it: at \(places(newest, in: app))")
        // the first four messages' cards come later still, from two pages further up, each
        // answered a moment late by the stand-in: the newest reply is in view after those too
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(waitUntil(timeout: 3) { self.inView(newest, in: app) },
                      "the newest reply is not in view once the cards from further up came in: at \(places(newest, in: app))")
        // the find bar counts the lines of the whole chat, not only the rows in the window
        app.typeKey("f", modifierFlags: .command)
        let finding = element("find-field", in: app)
        if finding.waitForExistence(timeout: 5) {
            finding.click()
            finding.typeText("带话（CI）")
            let count = element("find-count", in: app)
            let all = waitUntil(timeout: 15) { self.total(count) == 8 }
            keep(app.windows.firstMatch.screenshot(), "reconnect-4d-all-found")
            XCTAssertTrue(all, "not every message that came while away has its card: \(count.exists ? count.label : "no count") of 8")
            finding.typeKey(.escape, modifierFlags: [])
        } else {
            XCTFail("⌘F did not open the find bar")
        }

        // 3. admitted, and the receipt lost with the connection
        say("断线：还没回执", in: app)
        let unsure = element("unsure", in: app).waitForExistence(timeout: 10)
        keep(app.windows.firstMatch.screenshot(), "reconnect-5-unsure")
        XCTAssertTrue(unsure, "the sentence whose receipt the connection took does not say 等连上后确认")
        StandIn.tunnelUp("3. admitted, and the receipt lost")
        XCTAssertTrue(waitForText("收到：断线：还没回执", in: app, timeout: 40), "its answer did not come")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("unsure", in: app).exists }, "it still says 等连上后确认")
        XCTAssertFalse(element("unsent", in: app).exists, "it says 没发出去, though Hermes had it")
        once("断线：还没回执", whole: true, "the sentence is not there once", "reconnect-count-3", in: app)

        // 4. never admitted: 没发出去, and 重发
        say("断线：没收到", in: app)
        XCTAssertTrue(waitForText("重新连接中…", in: app, timeout: 10), "the socket did not drop")
        StandIn.tunnelUp("4. never admitted")
        let unsent = element("unsent", in: app).waitForExistence(timeout: 40)
        keep(app.windows.firstMatch.screenshot(), "reconnect-6-unsent")
        XCTAssertTrue(unsent, "the sentence Hermes never got does not say 没发出去")
        let resend = element("resend", in: app)
        if resend.waitForExistence(timeout: 5), waitUntil(timeout: 10, { resend.isEnabled }) {
            resend.click()
            XCTAssertTrue(waitForText("收到：断线：没收到", in: app, timeout: 15), "重发 got no answer")
            XCTAssertTrue(waitUntil(timeout: 5) { !self.element("unsent", in: app).exists }, "it still says 没发出去")
            once("断线：没收到", whole: true, "the sentence is not there once after 重发", "reconnect-count-4", in: app)
        } else {
            XCTFail("no 重发 to press")
        }
        keep(app.windows.firstMatch.screenshot(), "reconnect-7-resent")

        // 5. while an approval waits
        say("断线：等你批准", in: app)
        XCTAssertTrue(waitForText("要先在服务器上跑一条命令。", in: app, timeout: 10), "the turn did not start")
        XCTAssertTrue(waitForText("重新连接中…", in: app, timeout: 10), "the socket did not drop")
        StandIn.tunnelUp("5. while an approval waits")
        XCTAssertTrue(waitUntil(timeout: 40) { !self.hasText("重新连接中…", in: app) }, "the connection did not come back")
        element("nav-confirm", in: app).click()
        let asked = waitForText("要看一下服务器的磁盘还剩多少吗？", in: app, timeout: 10)
        keep(app.windows.firstMatch.screenshot(), "reconnect-8-approval")
        if asked {
            let allow = app.buttons["允许这一次"].firstMatch
            XCTAssertTrue(waitUntil(timeout: 10) { allow.isEnabled }, "the approval cannot be answered once back")
            allow.click()
        } else {
            XCTFail("the approval did not wait through the drop")
        }
        chief.click()
        let finished = waitForText("还剩一半。", in: app, timeout: 20)
        keep(app.windows.firstMatch.screenshot(), "reconnect-9-approved")
        XCTAssertTrue(finished, "the turn did not finish once the approval was answered")
        XCTAssertTrue(holds(["要先在服务器上跑一条命令。", "还剩一半。"], in: app), "the turn's reply is not in one bubble")

        // 6. more than the session keeps: the newest page instead
        XCTAssertTrue(element("send", in: app).waitForExistence(timeout: 10), "the approved turn is still replying")
        say("断线：说很多", in: app)
        XCTAssertTrue(waitForText("重新连接中…", in: app, timeout: 10), "the socket did not drop")
        StandIn.tunnelUp("6. more than the session keeps")
        XCTAssertTrue(waitUntil(timeout: 40) { !self.hasText("重新连接中…", in: app) }, "the connection did not come back")
        let page = waitForText("长长的回复。长长的回复。", in: app, timeout: 20)
        keep(app.windows.firstMatch.screenshot(), "reconnect-10-page")
        XCTAssertTrue(page, "the reply longer than the session keeps did not come from the page")
        once("长长的回复。长长的回复。", whole: false, "the long reply is not there once", "reconnect-count-6", in: app)
        XCTAssertTrue(element("send", in: app).waitForExistence(timeout: 5), "a bubble is still replying after the page")

        // 7. the subscription goes, the socket stays (session.replay_gap): caught up on the same socket
        say("断线：跟不上", in: app)
        XCTAssertTrue(waitForText("第3节。", in: app, timeout: 10), "the reply did not start")
        var dropped = false
        let caught = waitUntil(timeout: 40) {
            if self.hasText("重新连接中…", in: app) { dropped = true }
            return self.hasText("第40节。", in: app)
        }
        keep(app.windows.firstMatch.screenshot(), "reconnect-11-gap")
        XCTAssertTrue(caught, "the reply did not go on after the gap")
        XCTAssertFalse(dropped, "a gap is not a drop: the sidebar said 重新连接中…")
        once("第1节。", whole: false, "the reply is not in one bubble across the gap", "reconnect-count-7", in: app)
        XCTAssertTrue(holds(["第1节。", "第6节。", "第40节。"], in: app), "the bubble does not have the whole reply")
        XCTAssertTrue(element("send", in: app).waitForExistence(timeout: 10), "a bubble is still replying after the gap")

        // 8. a picture and a file, dropped before Hermes had them: 没发出去, and 重发, which finds the
        // picture cleared and sends it up again under a new submission
        let composer = element("composer", in: app)
        putPicture()
        composer.click()
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("draft-picture", in: app).waitForExistence(timeout: 10), "the pasted picture is not in the composer")
        putFiles(["ci-报告（CI）.pdf"])
        composer.click()
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("draft-file", in: app).waitForExistence(timeout: 10), "the pasted file is not in the composer")
        let send = element("send", in: app)
        XCTAssertTrue(waitUntil(timeout: 30) { send.isEnabled }, "the picture and the file did not go up")
        say("断线：图和文件", in: app)
        XCTAssertTrue(waitForText("重新连接中…", in: app, timeout: 10), "the socket did not drop")
        StandIn.tunnelUp("8. a picture and a file")
        let notSent = element("unsent", in: app).waitForExistence(timeout: 40)
        keep(app.windows.firstMatch.screenshot(), "reconnect-12-media-unsent")
        XCTAssertTrue(notSent, "the picture and the file Hermes never got do not say 没发出去")
        let again = element("resend", in: app)
        if again.waitForExistence(timeout: 5), waitUntil(timeout: 10, { again.isEnabled }) {
            again.click()
            let answered = waitForText("你说：断线：图和文件", in: app, timeout: 30)
            keep(app.windows.firstMatch.screenshot(), "reconnect-13-media-resent")
            XCTAssertTrue(answered, "重发 got no answer")
            XCTAssertTrue(hasText("收到 1 张图", in: app), "the picture did not go with 重发")
            XCTAssertTrue(hasText("收到文件：ci-报告（CI）.pdf", in: app), "the file did not go with 重发")
            XCTAssertTrue(waitUntil(timeout: 5) { !self.element("unsent", in: app).exists }, "it still says 没发出去")
            once("断线：图和文件", whole: true, "the message is not there once after 重发", "reconnect-count-8", in: app)
        } else {
            XCTFail("no 重发 to press")
        }

        // 9. the same words put into the running turn twice (引导) as the connection goes: neither
        // call is answered, and Hermes stored one of them. Once back, its one row says that one
        // got there, and never that both did, however often the transcript is looked at again
        XCTAssertTrue(waitUntil(timeout: 20) { !self.element("stop", in: app).exists }, "the turn before is still replying")
        say("断线：引导两遍", in: app)
        XCTAssertTrue(waitForText("听着呢（CI）。", in: app, timeout: 10), "the turn did not start")
        let busyMenu = element("busy-mode", in: app)
        if busyMenu.waitForExistence(timeout: 5) {
            busyMenu.click()
            let intoTurn = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "引导")).firstMatch
            if intoTurn.waitForExistence(timeout: 5) {
                intoTurn.click()
            } else {
                XCTFail("no 引导 in the menu")
            }
        } else {
            XCTFail("no way to say how a message reaches a busy assistant")
        }
        let correction = "改到五点（CI）"
        say(correction, in: app)
        say(correction, in: app)
        XCTAssertTrue(waitForText("重新连接中…", in: app, timeout: 10), "the socket did not drop under the second message")
        let bothInDoubt = waitUntil(timeout: 10) { self.marks("unconfirmed", in: app) == 2 }
        keep(app.windows.firstMatch.screenshot(), "reconnect-14-both-in-doubt")
        XCTAssertTrue(bothInDoubt, "the two messages put into the turn do not both say 不确定有没有送到: \(marks("unconfirmed", in: app))")
        StandIn.tunnelUp("9. the same words into a turn, twice")
        XCTAssertTrue(waitUntil(timeout: 40) { !self.hasText("重新连接中…", in: app) }, "the connection did not come back")
        let oneConfirmed = waitUntil(timeout: 20) {
            self.marks("unconfirmed", in: app) == 1 && self.marks("mid-turn", in: app) == 1
        }
        keep(app.windows.firstMatch.screenshot(), "reconnect-15-one-confirmed")
        XCTAssertTrue(oneConfirmed, "one row did not confirm just one of the two messages: "
                      + "\(marks("unconfirmed", in: app)) in doubt, \(marks("mid-turn", in: app)) in the turn")
        XCTAssertEqual(places(correction, in: app).count, 2, "the two messages are not both in the chat")
        XCTAssertTrue(waitForText("按新的时间来（CI）。", in: app, timeout: 15), "the reply did not end")

        // 10. said again in the words of a message just stored, while the chat is being attached
        // again (the replay cannot be had, so the newest page is read in the chat's place), and
        // that request lost. The page's row in those words is the first saying's: the message said
        // again stays under the page, says 等连上后确认, and once back 没发出去 with 重发
        XCTAssertTrue(waitUntil(timeout: 20) { !self.element("stop", in: app).exists }, "the turn before is still replying")
        let repeated = "断线：又说一遍"
        say(repeated, in: app)
        XCTAssertTrue(waitForText("头一遍听到了（CI）。", in: app, timeout: 10), "the first saying got no answer")
        XCTAssertTrue(waitForText("重新连接中…", in: app, timeout: 10), "the socket did not drop")
        StandIn.tunnelUp("10. said again: the first saying")
        XCTAssertTrue(waitUntil(timeout: 40) { !self.hasText("重新连接中…", in: app) }, "the connection did not come back")
        // connected, and 詩音's chat not attached on the new socket: the stand-in keeps that answer
        // back until the test says so, which is after the same words are said again
        say(repeated, in: app)
        XCTAssertTrue(waitUntil(timeout: 5) { self.places(repeated, in: app).count == 2 },
                      "said again, the message is not in the chat under the first")
        StandIn.attach("10. said again: the chat attached")
        XCTAssertTrue(waitForText("重新连接中…", in: app, timeout: 15), "the socket did not drop under the message said again")
        let stays = waitUntil(timeout: 10) { self.element("unsure", in: app).exists }
        keep(app.windows.firstMatch.screenshot(), "reconnect-16-said-again")
        XCTAssertTrue(stays, "the message said again does not say 等连上后确认 under the page read in the chat's place")
        XCTAssertEqual(places(repeated, in: app).count, 2, "the first saying's row was taken for the message said again")
        StandIn.tunnelUp("10. said again: lost")
        let lost = element("unsent", in: app).waitForExistence(timeout: 40)
        keep(app.windows.firstMatch.screenshot(), "reconnect-17-said-again-unsent")
        XCTAssertTrue(lost, "the message Hermes never got does not say 没发出去")
        XCTAssertEqual(places(repeated, in: app).count, 2, "the message said again is not in the chat once back")
        // two more looks at the transcript since step 9, one of them a page read in the chat's place
        XCTAssertEqual(marks("unconfirmed", in: app), 1, "the message no row confirmed is not the one still in doubt")
        let sendAgain = element("resend", in: app)
        if sendAgain.waitForExistence(timeout: 5), waitUntil(timeout: 10, { sendAgain.isEnabled }) {
            sendAgain.click()
            XCTAssertTrue(waitForText("收到：断线：又说一遍", in: app, timeout: 15), "重发 got no answer")
            XCTAssertTrue(waitUntil(timeout: 5) { !self.element("unsent", in: app).exists }, "it still says 没发出去")
            XCTAssertEqual(places(repeated, in: app).count, 2, "the two sayings are not there once each after 重发")
        } else {
            XCTFail("no 重发 to press")
        }
        keep(app.windows.firstMatch.screenshot(), "reconnect-18-said-again-resent")

        // 11. half way through a reply, and once back every session.resume of the chat is refused
        // (storage_unavailable, as Hermes answers when its store is busy; the socket kept) until
        // StandIn.attach. The frames replayed as Shion is back say a turn runs; not attached, the
        // chat keeps the reply it had, says what failed with Hermes's reason and 再试一次, and is
        // not left replying. The line, 再试一次 and the composer are in what the window shows, and
        // the window's own parts are where they were before the step (run 220: with the line, the
        // window's content stood 132 points higher, the sidebar's first rows and the chat's tabs
        // above the window, the line and the composer below it; the test asked only whether they
        // were there). Once the chat's own tries are used up, the line naming no time for the
        // next, Hermes would, and 再试一次, pressed once, attaches it again: the reply is whole and
        // what is said is answered
        XCTAssertTrue(waitUntil(timeout: 20) { !self.element("stop", in: app).exists }, "the turn before is still replying")
        let window = app.windows.firstMatch
        let refused = element("rejoin-failure", in: app)
        let tryAgain = element("rejoin-retry", in: app)
        // what is measured, by name: the window's own parts, which the line must not move, then the
        // line's (the tab bar by its 工作记录, as WorkTests finds it)
        let fixed = ["window", "今天", "工作记录"]
        let names = fixed + ["line", "再试一次", "composer"]
        let parts: [String: XCUIElement] = [
            "window": window,
            "今天": element("nav-today", in: app),
            "工作记录": app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "工作记录")).firstMatch,
            "line": refused,
            "再试一次": tryAgain,
            "composer": composer,
        ]
        let before = frames(of: parts)
        say("断线：接不上", in: app)
        XCTAssertTrue(waitForText("第3拍。", in: app, timeout: 10), "the reply did not start")
        XCTAssertTrue(waitForText("重新连接中…", in: app, timeout: 10), "the socket did not drop")
        StandIn.tunnelUp("11. back, and not attached again")
        XCTAssertTrue(waitUntil(timeout: 40) { !self.hasText("重新连接中…", in: app) }, "the connection did not come back")
        let saysSo = refused.waitForExistence(timeout: 20)
        let came = Date()
        keep(window.screenshot(), "reconnect-19-not-attached")
        XCTAssertTrue(saysSo, "a chat Hermes would not attach again does not say so")
        // in what the window shows (under its toolbar, above its bottom edge and the Dock): the line
        // over the composer, 再试一次 on it, and the composer; the window, its sidebar's first row
        // and the chat's tabs where they were. A moment to settle as the line comes in
        var shown = CGRect.null
        var during: [String: CGRect] = [:]
        let usable = waitUntil(timeout: 5) {
            shown = self.showing(window)
            during = self.frames(of: parts)
            guard let line = during["line"], let button = during["再试一次"], let field = during["composer"] else { return false }
            let area = shown.insetBy(dx: -1, dy: -1)
            return area.contains(line) && area.contains(button) && area.contains(field) && line.maxY <= field.minY
                && fixed.allSatisfy { self.same(during[$0], before[$0]) }
        }
        // the numbers, whatever comes of them (reconnect-19-frames.txt), and beside them whether XCUI
        // finds the three hittable: kept, not asserted; the frames are what is held to
        var measured = names.map { "\($0): \(self.described(before[$0])) before, \(self.described(during[$0])) with the line" }
        measured.append("shown: \(shown)")
        measured.append("hittable: the line \(refused.exists && refused.isHittable), 再试一次 \(tryAgain.exists && tryAgain.isHittable), "
                        + "the composer \(composer.exists && composer.isHittable) (enabled: \(composer.exists && composer.isEnabled))")
        measured.append("the line says: \(words(in: refused))")
        note(measured.joined(separator: "\n"), "reconnect-19-frames")
        XCTAssertTrue(usable, "the line, 再试一次 or the composer is not where it can be used, or the window's own parts moved "
                      + "with it:\n" + measured.joined(separator: "\n"))
        XCTAssertTrue(holds("没能重新接上这个对话", whole: false, in: refused) && holds("storage_unavailable", whole: false, in: refused),
                      "it does not say what could not be done, in Hermes's words")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.element("stop", in: app).exists }, "the chat is still shown as replying")
        XCTAssertTrue(holds(["第1拍。", "第15拍。"], in: app), "the chat lost the reply it had")
        XCTAssertTrue(tryAgain.exists, "no 再试一次 beside it")
        // the chat's own tries used up (four, 1, 2, 4 and 8 s after each refusal: Rejoin.swift): the
        // line names no time for the next, and 再试一次 can be pressed. Only now may Hermes attach
        // the chat, so that 再试一次, pressed once, is what attaches it again
        let usedUp = waitUntil(timeout: 30) {
            !refused.exists || (!self.holds(" 再试", whole: false, in: refused) && tryAgain.isEnabled)
        }
        let tried = Date().timeIntervalSince(came)
        let saidThen = words(in: refused)
        XCTAssertTrue(usedUp, "\(Int(tried)) s after the line came, the chat's own tries are not used up or 再试一次 cannot be "
                      + "pressed: the line says \(saidThen); 再试一次 enabled: \(tryAgain.exists && tryAgain.isEnabled)")
        XCTAssertTrue(refused.exists, "the line went before 再试一次 was pressed: the chat was attached again by a try of its own")
        StandIn.attach("11. Hermes attaches the chat again")
        let pressed = Date()
        if tryAgain.exists {
            tryAgain.click()
        }
        let back = waitUntil(timeout: 15) { !refused.exists }
        let took = Date().timeIntervalSince(pressed)
        note("the chat's own tries used up \(String(format: "%.1f", tried)) s after the line came; it said then: \(saidThen)\n"
             + "再试一次 pressed once: " + (back ? "attached again \(String(format: "%.1f", took)) s later" : "not attached 15 s later"),
             "reconnect-20-tried-again")
        keep(window.screenshot(), "reconnect-20-attached-again")
        XCTAssertTrue(back, "再试一次 did not attach the chat again once Hermes would")
        XCTAssertTrue(waitForText("第30拍。", in: app, timeout: 20), "the rest of the reply did not come")
        once("第1拍。", whole: false, "the reply is not in one bubble", "reconnect-count-11", in: app)
        XCTAssertTrue(waitUntil(timeout: 20) { !self.element("stop", in: app).exists }, "a bubble is still replying")
        say("接上了吗（CI）", in: app)
        XCTAssertTrue(waitForText("收到：接上了吗（CI）", in: app, timeout: 15), "what was said once attached again got no answer")
        keep(window.screenshot(), "reconnect-21-attached-said")
        app.terminate()
    }

    // MARK: helpers

    /// Through the stand-in's browser sheet, as SignInTests does; Settings then closed.
    @MainActor
    private func signIn(_ app: XCUIApplication) -> Bool {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        guard settings.waitForExistence(timeout: 5) else {
            keep(XCUIScreen.main.screenshot(), "reconnect-0-no-settings")
            XCTFail("No Settings window")
            return false
        }
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        settings.buttons["sign-in"].click()
        let state = element("connection-state", in: settings)
        let prefix = "已连接 ·"
        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix), object: state)
        guard XCTWaiter().wait(for: [connected], timeout: 60) == .completed else {
            keep(XCUIScreen.main.screenshot(), "reconnect-0-not-connected")
            XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
            return false
        }
        app.typeKey("w", modifierFlags: .command)
        return true
    }

    @MainActor
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field \(field)")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    /// A small picture on the pasteboard, as a screenshot copies one.
    @MainActor
    private func putPicture() {
        guard let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return XCTFail("no bitmap for the picture") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: picture)
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 48)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = picture.representation(using: .png, properties: [:]) else { return XCTFail("no PNG for the picture") }
        let board = NSPasteboard.general
        _ = board.clearContents()
        XCTAssertTrue(board.setData(data, forType: .png))
    }

    /// Files as Finder copies them: their addresses, in the folder the stand-in fills (fake_media.py).
    @MainActor
    private func putFiles(_ names: [String]) {
        let folder = URL(fileURLWithPath: "/tmp/shion-media-ci", isDirectory: true)
        let board = NSPasteboard.general
        _ = board.clearContents()
        XCTAssertTrue(board.writeObjects(names.map { folder.appendingPathComponent($0) as NSURL }))
    }

    /// Typed into the chat's field and sent with its button.
    @MainActor
    private func say(_ text: String, in app: XCUIApplication) {
        let composer = element("composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "no composer")
        XCTAssertTrue(waitUntil(timeout: 10) { composer.isEnabled }, "the composer takes nothing")
        composer.click()
        composer.typeText(text)
        let send = element("send", in: app)
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no send button")
        send.click()
        XCTAssertTrue(waitUntil(timeout: 5) { !(composer.value as? String ?? "").contains(text) }, "\(text) did not go")
    }

    @MainActor
    private func element(_ identifier: String, in root: XCUIElement) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Plain or selectable text holding `text` (selectable text is a text view, its words its value).
    private func matching(_ text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
    }

    @MainActor
    private func hasText(_ text: String, in app: XCUIApplication) -> Bool {
        app.staticTexts.matching(matching(text)).firstMatch.exists
            || app.textViews.matching(matching(text)).firstMatch.exists
            || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
    }

    /// Whether the answer to a sentence that waited (「收到：…」 with its words) is in the chat.
    @MainActor
    private func hasText(_ words: String, answered: Bool, in app: XCUIApplication) -> Bool {
        answer(words, in: app) != nil
    }

    /// The answer to a sentence that waited: 「收到：（… 写的）」 and its words.
    @MainActor
    private func answer(_ words: String, in app: XCUIApplication) -> XCUIElement? {
        let both = NSPredicate(format: "(label CONTAINS %@ AND label CONTAINS %@) OR (value CONTAINS %@ AND value CONTAINS %@)",
                               "收到：", words, "收到：", words)
        for query in [app.textViews.matching(both), app.staticTexts.matching(both)] where query.firstMatch.exists {
            return query.firstMatch
        }
        return nil
    }

    /// Texts holding `text`, or (`whole`) just it: a message's words are a static text's value
    /// (or label), a selectable text view's value.
    @MainActor
    private func texts(_ text: String, whole: Bool, in app: XCUIApplication) -> [XCUIElement] {
        let predicate = whole ? NSPredicate(format: "label == %@ OR value == %@", text, text) : matching(text)
        return app.staticTexts.matching(predicate).allElementsBoundByIndex
            + app.textViews.matching(predicate).allElementsBoundByIndex
    }

    /// One message holds `text` (or, `whole`, is just it), within a few seconds: a reply that has
    /// just ended can show to accessibility for a moment both as it streamed and as laid out. When
    /// not, what holds it is noted (`name.txt`) beside the pictures.
    @MainActor
    private func once(_ text: String, whole: Bool, _ message: String, _ name: String, in app: XCUIApplication) {
        var found: [XCUIElement] = []
        // a text and a text view are the same message where they are in the same place
        func messages() -> Int {
            found = texts(text, whole: whole, in: app)
            var places: [CGRect] = []
            for frame in found.map({ $0.frame }) where !places.contains(where: { $0.intersects(frame) }) {
                places.append(frame)
            }
            return places.count
        }
        guard !waitUntil(timeout: 5, { messages() == 1 }) else { return }
        let lines = found.map { "\($0.elementType.rawValue) \($0.frame) label: \($0.label.prefix(40)) value: \(String(describing: $0.value).prefix(60))" }
        note("\(text): \(found.count) texts\n" + lines.joined(separator: "\n"), name)
        XCTFail("\(message): \(messages()) messages, \(found.count) texts")
    }

    /// One message holds all of them.
    @MainActor
    private func holds(_ texts: [String], in app: XCUIApplication) -> Bool {
        let all = NSCompoundPredicate(andPredicateWithSubpredicates: texts.map { matching($0) })
        return app.textViews.matching(all).firstMatch.exists || app.staticTexts.matching(all).firstMatch.exists
    }

    /// A text inside `root` holds `text`, or (`whole`) is just it.
    @MainActor
    private func holds(_ text: String, whole: Bool, in root: XCUIElement) -> Bool {
        let predicate = whole ? NSPredicate(format: "label == %@ OR value == %@", text, text) : matching(text)
        return root.staticTexts.matching(predicate).firstMatch.exists || root.textViews.matching(predicate).firstMatch.exists
    }

    /// Where the texts that are just `text` stand, top to bottom: one place each, however many
    /// elements accessibility has there.
    @MainActor
    private func places(_ text: String, in app: XCUIApplication) -> [CGFloat] {
        var tops: [CGFloat] = []
        for element in texts(text, whole: true, in: app) where element.exists {
            let frame = element.frame
            if frame.height > 0, !tops.contains(where: { abs($0 - frame.minY) < 2 }) {
                tops.append(frame.minY)
            }
        }
        return tops.sorted()
    }

    /// Whether the lowest text that is just `text` stands within what the chat's transcript shows.
    @MainActor
    private func inView(_ text: String, in app: XCUIApplication) -> Bool {
        let shown = element("transcript", in: app).frame
        guard let top = places(text, in: app).last else { return false }
        return top >= shown.minY && top + 14 <= shown.maxY
    }

    /// The part of `window` that shows what it holds, in screen points with the origin top left
    /// (XCUI's): under its toolbar, above its bottom edge and the runner's Dock, as
    /// ScrollIntoView.swift reckons it.
    @MainActor
    private func showing(_ window: XCUIElement) -> CGRect {
        let frame = window.frame
        let toolbar = window.toolbars.firstMatch
        let top = toolbar.exists ? toolbar.frame.maxY : frame.minY
        let dock: CGFloat = NSScreen.main.map { $0.frame.maxY - $0.visibleFrame.minY } ?? .greatestFiniteMagnitude
        return CGRect(x: frame.minX, y: top, width: frame.width, height: min(frame.maxY, dock) - top)
    }

    /// Where each of `parts` is on the screen, by name, in screen points with the origin top left
    /// (XCUI's); none for one that is not there.
    @MainActor
    private func frames(of parts: [String: XCUIElement]) -> [String: CGRect] {
        var found: [String: CGRect] = [:]
        for (name, element) in parts where element.exists {
            found[name] = element.frame
        }
        return found
    }

    /// Both there, and within two points of each other.
    private func same(_ one: CGRect?, _ other: CGRect?) -> Bool {
        guard let one, let other else { return false }
        return abs(one.minX - other.minX) <= 2 && abs(one.minY - other.minY) <= 2
            && abs(one.width - other.width) <= 2 && abs(one.height - other.height) <= 2
    }

    private func described(_ frame: CGRect?) -> String {
        frame.map { "\($0)" } ?? "not there"
    }

    /// What the texts inside `root` say, in order, or that it is not there.
    @MainActor
    private func words(in root: XCUIElement) -> String {
        guard root.exists else { return "not there" }
        return root.staticTexts.allElementsBoundByIndex.filter { $0.exists }
            .map { $0.label.isEmpty ? ($0.value as? String ?? "") : $0.label }
            .joined(separator: " | ")
    }

    /// How many lines the find bar says hold what is looked for: the 8 of "3/8".
    @MainActor
    private func total(_ count: XCUIElement) -> Int? {
        guard count.exists else { return nil }
        let said = (count.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? count.label
        return said.split(separator: "/").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Every event card accessibility has, for reading after the run: where it is and what it says.
    @MainActor
    private func eventCards(in app: XCUIApplication) -> String {
        app.descendants(matching: .any).matching(identifier: "event-card").allElementsBoundByIndex
            .filter { $0.exists }
            .map { card in
                let said = (card.staticTexts.allElementsBoundByIndex + card.textViews.allElementsBoundByIndex)
                    .filter { $0.exists }
                    .map { "\($0.label.isEmpty ? ($0.value as? String ?? "") : $0.label) @\(Int($0.frame.minY))" }
                return "\(card.elementType.rawValue) \(card.frame): \(said.joined(separator: " | "))"
            }
            .joined(separator: "\n")
    }

    /// How many of the chat's cards of one kind (their identifier: `board-notice`, `event-card`)
    /// hold `text`.
    @MainActor
    private func cards(_ identifier: String, holding text: String, in app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex
            .filter { holds(text, whole: false, in: $0) }.count
    }

    /// How many messages carry a mark of one kind (its identifier: `unconfirmed`, `mid-turn`): one
    /// for each line of the chat that has it, however many elements accessibility makes of a
    /// label (its picture and its words).
    @MainActor
    private func marks(_ identifier: String, in app: XCUIApplication) -> Int {
        var lines: [CGRect] = []
        for mark in app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex where mark.exists {
            let frame = mark.frame
            if frame.height > 0, !lines.contains(where: { $0.minY < frame.maxY && frame.minY < $0.maxY }) {
                lines.append(frame)
            }
        }
        return lines.count
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

    @MainActor
    private func waitForText(_ text: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { hasText(text, in: app) }
    }

    /// Numbers worth reading after the run, kept as a text beside the pictures (`name.txt`).
    private func note(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func keep(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
