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
/// 3. after a sentence was admitted, before its receipt: 等连上后确认 while down, then an ordinary
///    message with its answer, once;
/// 4. before a sentence was admitted: once back, 没发出去 with 重发, which sends it, once;
/// 5. while an approval waits: once back it is still in 等你确认, and answering it there lets the
///    turn finish in the same bubble;
/// 6. before a reply longer than the session keeps: the replay cannot reach back, the newest page
///    stands in, and the reply is there whole, once, with nothing still replying;
/// 7. not a drop: Hermes ends the subscription of a socket that cannot keep up (session.replay_gap)
///    and keeps the socket; what was missed comes back on it, and the reply is whole in one bubble;
/// 8. a picture and a file, before Hermes had them: once back, 没发出去 with 重发. The server
///    cleared the picture meanwhile, so the same submission is refused, and the picture goes up
///    again from the Mac under a new one; answered once, with both.
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
        // later is the only one in 等你确认
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
