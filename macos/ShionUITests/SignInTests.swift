import AppKit
import XCTest

/// Browser sign-in end to end, against ci/fake_hermes.py: a stand-in for Cloudflare Access and
/// the parts of a Hermes gateway Shion talks to, which the workflow starts on 127.0.0.1:8765.
/// Settings → 用浏览器登录 → the sheet runs the stand-in's login page → the loopback redirect →
/// tokens → connected → the assistants come from the server → one round trip in a chat.
/// A picture at each step; the workflow prints the stand-in's request log next to them.
final class SignInTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"

    @MainActor
    func testBrowserSignIn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "today",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        guard settings.waitForExistence(timeout: 5) else {
            keep(XCUIScreen.main.screenshot(), "signin-0-no-settings")
            return XCTFail("No Settings window")
        }
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        keep(settings.screenshot(), "signin-1-filled")

        let signIn = settings.buttons["sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.click()
        Thread.sleep(forTimeInterval: 1.5)
        keep(XCUIScreen.main.screenshot(), "signin-2-sheet")

        let account = element("account-name", in: settings)
        guard account.waitForExistence(timeout: 45) else {
            keep(XCUIScreen.main.screenshot(), "signin-3-stuck")
            return XCTFail("Not signed in")
        }
        XCTAssertTrue(says(account, "ci-user"), "signed in as \(account.label) / \(String(describing: account.value))")

        // selectable text is not a plain static text to accessibility, so look it up by id alone
        let state = element("connection-state", in: settings)
        let online = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "已连接", "已连接")
        let connected = XCTNSPredicateExpectation(predicate: online, object: state)
        let outcome = XCTWaiter().wait(for: [connected], timeout: 25)
        keep(settings.screenshot(), "signin-3-connected")
        print("connection state: \(state.label) / \(String(describing: state.value))")
        guard outcome == .completed else {
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }

        // the assistants now come from the stand-in: 詩音, 课程（CI） and 通勤（CI）
        app.typeKey("w", modifierFlags: .command)
        let chief = element("bot-shion", in: app)
        guard chief.waitForExistence(timeout: 10) else {
            keep(XCUIScreen.main.screenshot(), "signin-4-no-assistants")
            return XCTFail("No assistants from the server")
        }
        XCTAssertTrue(element("bot-study", in: app).exists)

        // 课程's Bot Chat was never opened, yet its approval reaches 等你确认: every Bot Chat is
        // attached in the background once Shion connects
        element("nav-confirm", in: app).click()
        let approval = waitForText("要在课程的云桌面上登录 Moodle 吗", in: app, timeout: 15)
        keep(app.windows.firstMatch.screenshot(), "signin-4a-approval")
        XCTAssertTrue(approval, "the approval from an unopened chat did not arrive")
        if approval {
            app.buttons["允许这一次"].firstMatch.click()
            let gone = NSPredicate(format: "exists == false")
            let settled = XCTNSPredicateExpectation(predicate: gone, object: app.buttons["允许这一次"].firstMatch)
            XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: 10), .completed, "the approval stayed after answering")
            keep(app.windows.firstMatch.screenshot(), "signin-4b-approved")
        }

        // 今天, 待办 and 日报 come from the shion plugin on the stand-in
        element("nav-today", in: app).click()
        let summary = waitForText("（CI）早上好", in: app, timeout: 10)
        keep(app.windows.firstMatch.screenshot(), "signin-4c-today")
        XCTAssertTrue(summary, "詩音's paragraph from the plugin is not on 今天")

        element("nav-todos", in: app).click()
        XCTAssertTrue(waitForText("CI：交实验报告", in: app, timeout: 10), "the plugin's todos are not listed")
        element("todo-toggle-td_ci_report", in: app).click()
        // 课程 adds one through the plugin a few seconds after Shion syncs; the push brings it in
        let pushed = waitForText("CI：复习第 7 回", in: app, timeout: 15)
        keep(app.windows.firstMatch.screenshot(), "signin-4d-todos")
        XCTAssertTrue(pushed, "the todo an assistant added did not arrive")

        element("nav-reports", in: app).click()
        let report = waitForText("CI 日报：昨天睡得早", in: app, timeout: 10)
        keep(app.windows.firstMatch.screenshot(), "signin-4e-reports")
        XCTAssertTrue(report, "the plugin's report is not on 日报")

        chief.click()
        let opened = waitForText("CI 替身服务器连上了", in: app, timeout: 15)
        keep(app.windows.firstMatch.screenshot(), "signin-4-chat")
        XCTAssertTrue(opened, "the Bot Chat did not open")

        // from here on each check reports, and the next one still runs; where things are on the
        // screen goes in signin-positions.txt
        continueAfterFailure = true
        let transcript = element("transcript", in: app)
        var positions: [String] = []
        // the chat opens at its newest message
        Thread.sleep(forTimeInterval: 0.5)
        let greeting = findText("CI 替身服务器连上了", in: app)
        positions.append("opened: the newest message at \(place(greeting)) in \(transcript.frame)")
        XCTAssertTrue(inView(greeting, of: transcript), "the chat did not open at its newest message. \(positions.last ?? "")")

        let composer = element("composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("hello")
        element("send", in: app).click()
        let replied = waitForText("收到：hello", in: app, timeout: 15)
        Thread.sleep(forTimeInterval: 0.5)
        keep(app.windows.firstMatch.screenshot(), "signin-5-reply")
        XCTAssertTrue(replied, "no reply streamed back")
        // the reply was followed down as it came
        let hello = findText("收到：hello", in: app)
        positions.append("replied: the reply at \(place(hello)) in \(transcript.frame)")
        XCTAssertTrue(inView(hello, of: transcript), "the reply was not followed down. \(positions.last ?? "")")

        // 詩音's chat on the stand-in is 135 rows: it opened on the newest 50, and the older ones
        // come a page at a time as the top scrolls into view
        XCTAssertFalse(waitForText("第 1 条（你）", in: app, timeout: 1), "the whole transcript came at once")
        let window = app.windows.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5), "no transcript")
        // which sign of a wheel delta scrolls up is the runner's business: nudge each way, and see
        // which moves a row on screen down (towards older messages). The wheel turns at the
        // transcript's left margin, in no row, as BoardTests does.
        let wheel = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.4))
        var up = upward(wheel, watching: "第 124 条", in: app, positions: &positions)
        XCTAssertNotNil(up, "the chat did not move on the wheel, either way. \(positions.suffix(2).joined(separator: "; "))")
        if up == nil {
            // to tell what holds it (numbers only): another chat and back, and the nudges again
            element("bot-study", in: app).click()
            _ = waitForText("课程的 Bot Chat", in: app, timeout: 10)
            element("bot-shion", in: app).click()
            _ = waitForText("收到：hello", in: app, timeout: 10)
            Thread.sleep(forTimeInterval: 1)
            up = upward(wheel, watching: "第 124 条", in: app, positions: &positions)
            positions.append("after 课程 and back to 詩音: " + (up.map { "up is \($0)" } ?? "still does not move"))
        }
        // a positive delta scrolls back on the runner (BoardTests): that, when no nudge told
        let direction = up ?? 1
        // to the first message a little at a time. An older page lands 1.5 s after it is asked for
        // (the stand-in's network): the rows are read before each wait and after it, and the row
        // at the top of what shows stays where it was as a page comes in above it
        var reachedTop = false
        var landings: [Int] = []
        // where each page starts on the stand-in, newest first: a row below the first number means
        // the next page came in
        var floors = [82, 32, 1]
        for step in 1...40 where !reachedTop {
            wheel.scroll(byDeltaX: 0, deltaY: direction * 300)
            Thread.sleep(forTimeInterval: 0.4)
            let before = layout(of: transcript)
            Thread.sleep(forTimeInterval: 2.2)
            let after = layout(of: transcript)
            let area = transcript.frame
            reachedTop = after.rows["第 1 条（你）"] != nil
            let top = before.rows
                .filter { $0.value.minY >= area.minY - 1 && $0.value.maxY <= area.maxY + 1 }
                .min { $0.value.minY < $1.value.minY }
            let now = top.flatMap { after.rows[$0.key]?.minY }
            let barMoved = before.bar.flatMap { bar in after.bar.map { abs($0 - bar) > 0.001 } } ?? false
            if let earliest = after.rows.keys.compactMap(number).min(), floors.count > 1, earliest < floors[0] {
                floors.removeFirst()
                landings.append(step)
                keep(window.screenshot(), "signin-6a-page-\(landings.count + 1)")
            }
            guard let top, barMoved || now != top.value.minY || Set(after.rows.keys) != Set(before.rows.keys) else { continue }
            positions.append("step \(step): \(top.key) at \(top.value.minY) before the wait, \(now.map { "\($0)" } ?? "gone") after; "
                             + "rows \(span(before)) before, \(span(after)) after; the scroll bar \(barText(before)) before, \(barText(after)) after")
            XCTAssertEqual(now ?? .nan, top.value.minY, accuracy: 4,
                           "the row at the top of what shows moved. \(positions.last ?? "")")
        }
        positions.append("older pages seen from steps \(landings) on; 第 1 条 \(reachedTop ? "reached" : "not reached")")
        // on to the very top, for the picture: 第 1 条 is read a little before it comes into view
        if reachedTop {
            for _ in 0..<2 {
                wheel.scroll(byDeltaX: 0, deltaY: direction * 1200)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        // the oldest page opens with a compaction that has the row_id of 第 1 条, the ask it was
        // stored on, as Hermes sends it: both rows show, with the tool calls after it in one line
        let summarized = waitForText("更早的对话压缩成了摘要", in: app, timeout: 3)
        keep(window.screenshot(), "signin-6-oldest")
        XCTAssertTrue(reachedTop, "older pages did not load on scrolling up")
        XCTAssertTrue(summarized, "the compaction above 第 1 条 is not shown")
        XCTAssertTrue(waitForText("第 1 条（你）", in: app, timeout: 1), "第 1 条, which holds the compaction, is not shown")
        // the two tool calls after it belong to a finished turn read from the transcript: one line
        XCTAssertTrue(waitForText("用了 2 个工具 · web_search", in: app, timeout: 1), "the tool calls after 第 1 条 are not folded into one line")
        XCTAssertFalse(waitForText("web_search · 第 1 条问的", in: app, timeout: 0.5), "the tool calls after 第 1 条 show one by one")

        // 通勤 has no Bot Chat on the stand-in yet: Shion creates one (the stand-in checks the
        // fields against Hermes's, and logs which interface the assistant would be told)
        element("bot-commute", in: app).click()
        let created = waitForText("新的 Bot Chat。", in: app, timeout: 15)
        keep(window.screenshot(), "signin-7-new-chat")
        XCTAssertTrue(created, "the new Bot Chat did not open")
        // one message: it sits at the bottom, just above the composer
        Thread.sleep(forTimeInterval: 0.5)
        let only = findText("新的 Bot Chat", in: app)
        positions.append("a short chat: its message at \(place(only)) in \(transcript.frame)")
        XCTAssertTrue(inView(only, of: transcript) && only.map { transcript.frame.maxY - $0.frame.maxY < 80 } ?? false,
                      "a short chat does not sit at the bottom. \(positions.last ?? "")")

        // the board limits in Settings come from the server: unset overall (4 by its 2 GB), 1 each
        app.typeKey(",", modifierFlags: .command)
        let again = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        let total = element("board-limit-total", in: again)
        let shown = total.waitForExistence(timeout: 5)
        keep(again.screenshot(), "signin-8-board-limits")
        XCTAssertTrue(shown, "no board limits in Settings")
        XCTAssertTrue(says(total, "4 件（按内存推算）"), "overall: \(total.label) / \(String(describing: total.value))")
        let each = element("board-limit-assistant", in: again)
        XCTAssertTrue(says(each, "1 件"), "per assistant: \(each.label) / \(String(describing: each.value))")
        note(positions.joined(separator: "\n"), "signin-positions")
        app.terminate()
    }

    /// The demo's 詩音 chat opened from 日报 with the page in an inspector (`-ShionChatInspector`),
    /// hidden and then shown: the window's split view sets such a page up again as it opens, after
    /// the chat went to its newest message, and puts the transcript back at its top. Twice each:
    /// the chat is at its end (its scroll bar at the bottom). No server.
    @MainActor
    func testOpensAtNewestUnderAnInspector() throws {
        continueAfterFailure = true
        var notes: [String] = []
        for inspector in ["hidden", "shown"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-ShionSnapshot", "YES",
                "-ShionRoute", "reports",
                "-ShionAppearance", "light",
                "-ApplePersistenceIgnoreState", "YES",
                "-ShionChatInspector", inspector,
            ]
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
            let window = app.windows.firstMatch
            let transcript = element("transcript", in: app)
            for round in 1...2 {
                element("bot-shion", in: app).click()
                let opened = transcript.waitForExistence(timeout: 10)
                Thread.sleep(forTimeInterval: 1.5)
                let bar = layout(of: transcript).bar
                keep(window.screenshot(), "signin-9-inspector-\(inspector)-\(round)")
                notes.append("inspector \(inspector), opening \(round): the scroll bar at \(bar.map { String(format: "%.3f", $0) } ?? "not there")")
                XCTAssertTrue(opened, "the chat did not open (inspector \(inspector))")
                XCTAssertGreaterThan(bar ?? 0, 0.98, "the chat did not open at its newest message. \(notes.last ?? "")")
                element("nav-reports", in: app).click()
                Thread.sleep(forTimeInterval: 1)
            }
            app.terminate()
        }
        note(notes.joined(separator: "\n"), "signin-inspector")
    }

    /// The demo's 詩音 chat, at its end: ⌘↑ to its top (Home if the key does not move it, one turn of
    /// the wheel all the way if neither does), and two seconds later it is still there; a jump to
    /// the top is the reader's, not something to follow back down. No server.
    @MainActor
    func testJumpToTheTopStays() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "chat-shion",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch
        let transcript = element("transcript", in: app)
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "no transcript")
        Thread.sleep(forTimeInterval: 1.5)
        var notes = ["opened: the scroll bar at \(barText(layout(of: transcript)))"]
        XCTAssertGreaterThan(layout(of: transcript).bar ?? 0, 0.98, "the chat did not open at its end. \(notes[0])")
        // the keys go to what has the keyboard: the transcript, once its margin is clicked
        let margin = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
        margin.click()
        var how = "⌘↑"
        app.typeKey(.upArrow, modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        if (layout(of: transcript).bar ?? 1) > 0.02 {
            how = "Home"
            app.typeKey(.home, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)
        }
        // a first turn of the wheel sometimes moves nothing on the runner (see upward): up to three
        for _ in 0..<3 where (layout(of: transcript).bar ?? 1) > 0.02 {
            how = "the wheel, all the way in one turn"
            margin.scroll(byDeltaX: 0, deltaY: 100_000)
            Thread.sleep(forTimeInterval: 0.5)
        }
        let jumped = layout(of: transcript).bar
        Thread.sleep(forTimeInterval: 2)
        let later = layout(of: transcript).bar
        keep(window.screenshot(), "signin-10-jumped-to-top")
        notes.append("to the top by \(how): the scroll bar at \(jumped.map { String(format: "%.3f", $0) } ?? "not there"), "
                     + "two seconds later \(later.map { String(format: "%.3f", $0) } ?? "not there")")
        note(notes.joined(separator: "\n"), "signin-jump")
        XCTAssertLessThan(jumped ?? 1, 0.02, "nothing took the chat to its top. \(notes.last ?? "")")
        XCTAssertLessThan(later ?? 1, 0.02, "the chat went back down after a jump to its top. \(notes.last ?? "")")
        app.terminate()
    }

    /// Which sign of a wheel delta at `wheel` scrolls the chat back, from nudges each way watching
    /// the row `label`; nil when none moves it. The pointer rests there first, and the nudges grow
    /// from 40 to 80: on the runner a first nudge of 40 sometimes moves nothing, the pointer
    /// resting there or not, where 80 then moves. The numbers go in `positions`.
    @MainActor
    private func upward(_ wheel: XCUICoordinate, watching label: String, in app: XCUIApplication,
                        positions: inout [String]) -> CGFloat? {
        guard let row = findText(label, in: app) else {
            positions.append("wheel: no \(label) to watch")
            return nil
        }
        wheel.hover()
        Thread.sleep(forTimeInterval: 0.5)
        for size: CGFloat in [40, 80] {
            for sign: CGFloat in [1, -1] {
                let before = row.exists ? row.frame.minY : -1
                wheel.scroll(byDeltaX: 0, deltaY: sign * size)
                Thread.sleep(forTimeInterval: 0.5)
                let after = row.exists ? row.frame.minY : -1
                positions.append("wheel: \(sign * size) moved \(label) from \(before) to \(after)")
                if after > before + 1 {
                    return sign
                }
            }
        }
        return nil
    }

    /// The 第 N 条 rows the transcript has laid out, from one snapshot of it (quick enough to read
    /// between a wheel turn and a page landing), by their text; and where its scroll bar is.
    @MainActor
    private func layout(of transcript: XCUIElement) -> (rows: [String: CGRect], bar: Double?) {
        guard let root = try? transcript.snapshot() else { return ([:], nil) }
        var rows: [String: CGRect] = [:]
        func visit(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText || node.elementType == .textView,
               let text = [node.label, node.value as? String ?? ""].first(where: { $0.hasPrefix("第 ") && $0.contains(" 条（") }),
               rows[text] == nil {
                rows[text] = node.frame
            }
            node.children.forEach(visit)
        }
        visit(root)
        // its own bar, not a wide table's inside a row
        let bar = root.children.first { $0.elementType == .scrollBar && $0.frame.height > $0.frame.width }
        let value = bar?.value
        return (rows, (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init))
    }

    /// N of a 第 N 条 row.
    private func number(_ row: String) -> Int? {
        guard let start = row.range(of: "第 "),
              let end = row.range(of: " 条", range: start.upperBound..<row.endIndex) else { return nil }
        return Int(row[start.upperBound..<end.lowerBound])
    }

    /// Which 第 N 条 rows were laid out, first to last.
    private func span(_ layout: (rows: [String: CGRect], bar: Double?)) -> String {
        let numbers = layout.rows.keys.compactMap(number)
        guard let first = numbers.min(), let last = numbers.max() else { return "none" }
        return "\(first)–\(last)"
    }

    private func barText(_ layout: (rows: [String: CGRect], bar: Double?)) -> String {
        layout.bar.map { String(format: "%.3f", $0) } ?? "not there"
    }

    /// In the transcript's visible part, not above or below it.
    @MainActor
    private func inView(_ element: XCUIElement?, of transcript: XCUIElement) -> Bool {
        guard let element, element.exists, transcript.exists else { return false }
        let frame = element.frame, area = transcript.frame
        return frame.minY >= area.minY - 2 && frame.maxY <= area.maxY + 2
    }

    /// Where an element is on the screen, top to bottom, or "gone".
    @MainActor
    private func place(_ element: XCUIElement?) -> String {
        guard let element, element.exists else { return "gone" }
        return "\(element.frame.minY)–\(element.frame.maxY)"
    }

    /// Numbers worth reading after the run, kept as a text beside the pictures (`name.txt`).
    private func note(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
    private func says(_ element: XCUIElement, _ text: String) -> Bool {
        element.label == text || (element.value as? String) == text
    }

    /// The first text element showing `text`, plain or selectable; nil when none is there.
    @MainActor
    private func findText(_ text: String, in app: XCUIApplication) -> XCUIElement? {
        let either = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        return [app.staticTexts.matching(either).firstMatch, app.textViews.matching(either).firstMatch]
            .first { $0.exists }
    }

    /// Text anywhere in the app, plain or selectable (selectable text is not a static text to
    /// accessibility). `value` is only read on text elements: a toggle's is a number, which a
    /// CONTAINS predicate would throw on.
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
