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

        // the assistants now come from the stand-in: 詩音 and 课程（CI）
        app.typeKey("w", modifierFlags: .command)
        let chief = element("bot-shion", in: app)
        guard chief.waitForExistence(timeout: 10) else {
            keep(XCUIScreen.main.screenshot(), "signin-4-no-assistants")
            return XCTFail("No assistants from the server")
        }
        XCTAssertTrue(element("bot-study", in: app).exists)
        chief.click()
        let opened = waitForText("CI 替身服务器连上了", in: app, timeout: 15)
        keep(app.windows.firstMatch.screenshot(), "signin-4-chat")
        XCTAssertTrue(opened, "the Bot Chat did not open")

        let composer = element("composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("hello")
        element("send", in: app).click()
        let replied = waitForText("收到：hello", in: app, timeout: 15)
        keep(app.windows.firstMatch.screenshot(), "signin-5-reply")
        XCTAssertTrue(replied, "no reply streamed back")

        // 詩音's chat on the stand-in is 132 rows: it opened on the newest 50, and the older ones
        // come a page at a time as the top scrolls into view
        XCTAssertFalse(waitForText("第 1 条（你）", in: app, timeout: 1), "the whole transcript came at once")
        let window = app.windows.firstMatch
        let transcript = element("transcript", in: app)
        XCTAssertTrue(transcript.waitForExistence(timeout: 5), "no transcript")
        // which sign of a wheel delta scrolls up is the runner's business: nudge, and see which
        // way a row on screen moved. Towards older messages rows move down; the chat is at its
        // bottom, so a nudge the other way moves nothing.
        var direction: CGFloat = 1
        if let row = findText("第 124 条", in: app) {
            let before = row.frame.minY
            transcript.hover()
            transcript.scroll(byDeltaX: 0, deltaY: 200)
            Thread.sleep(forTimeInterval: 0.5)
            direction = row.exists && row.frame.minY > before + 1 ? 1 : -1
            print("wheel: +200 moved 第 124 条 from \(before) to \(row.exists ? row.frame.minY : -1); up is \(direction)")
        }
        var reachedTop = false
        var sawSecondPage = false
        for _ in 0..<24 {
            // wheel events go where the pointer is: put it on the transcript, not the composer
            transcript.hover()
            transcript.scroll(byDeltaX: 0, deltaY: direction * 1200)
            if waitForText("第 1 条（你）", in: app, timeout: 1.5) {
                reachedTop = true
                break
            }
            // the moment the second page lands: the rows that were at the top should still be there
            if !sawSecondPage && waitForText("第 81 条", in: app, timeout: 0.2) {
                sawSecondPage = true
                keep(window.screenshot(), "signin-6a-second-page")
            }
        }
        keep(window.screenshot(), "signin-6-oldest")
        XCTAssertTrue(reachedTop, "older pages did not load on scrolling up")

        // 课程 has no Bot Chat on the stand-in yet: Shion creates one (the stand-in checks the
        // fields against Hermes's, and logs which interface the assistant would be told)
        element("bot-study", in: app).click()
        let created = waitForText("新的 Bot Chat。", in: app, timeout: 15)
        keep(window.screenshot(), "signin-7-new-chat")
        XCTAssertTrue(created, "the new Bot Chat did not open")

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
