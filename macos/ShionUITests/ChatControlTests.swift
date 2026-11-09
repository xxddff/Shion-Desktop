import AppKit
import XCTest

/// Stop, retry, find, the server check and the last data, end to end against ci/fake_hermes.py
/// (fake_control.py plays the parts Hermes has for them). Signs in as SignInTests does, then:
/// Settings' 服务器体检 against the stand-in (通勤's profile has no shion plugin); in 詩音's chat a
/// long reply stopped with ⌘. (session.interrupt for the turn's run) and kept as 已停止; 重试 on
/// it (a fenced rewind, then the same words again); ⌘F over the loaded rows, and back into older
/// pages for a hit not loaded yet; then 断开, and the window keeps the server's data, read-only.
/// A picture at each step (chatctl-*.png).
final class ChatControlTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"

    @MainActor
    func testStopRetryFindAndLastData() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "today",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))

        // signed in through the stand-in's browser sheet, as SignInTests does
        app.typeKey(",", modifierFlags: .command)
        let settings = settingsWindow(app)
        guard settings.waitForExistence(timeout: 5) else {
            keep(XCUIScreen.main.screenshot(), "chatctl-0-no-settings")
            return XCTFail("No Settings window")
        }
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        settings.buttons["sign-in"].click()
        let state = element("connection-state", in: settings)
        guard XCTWaiter().wait(for: [phase("已连接 ·", of: state)], timeout: 60) == .completed else {
            keep(XCUIScreen.main.screenshot(), "chatctl-0-not-connected")
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }

        // 服务器体检: every check against the stand-in
        label("服务器体检", in: settings).click()
        let notifications = element("check-notifications", in: settings)
        let done = NSPredicate(format: "label != %@ AND value != %@", "检查中…", "检查中…")
        let checked = notifications.waitForExistence(timeout: 10)
            && XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: notifications)], timeout: 30) == .completed
        keep(settings.screenshot(), "chatctl-1-check")
        XCTAssertTrue(checked, "the server check did not finish")
        expect("check-access", in: settings, "service token 放行了")
        expect("check-login", in: settings, startsWith: "有效 · ci-user · ")
        expect("check-protocol", in: settings, "hermes gateway")
        expect("check-capabilities", in: settings, "Shion 用到的都有")
        expect("check-plugin", in: settings, "1 个助手没有")
        expect("check-plugin-commute", in: settings, "没装或没启用")
        expect("check-plugin-shion", in: settings, startsWith: "ci · 今天是 ")
        expect("check-kanban", in: settings, "在 · 2 块看板")
        expect("check-limits", in: settings, "整台服务器 4 件（按内存推算） · 每个助手 1 件")
        label("通用", in: settings).click()
        app.typeKey("w", modifierFlags: .command)

        // a long reply, stopped with ⌘. part way: what had come stays, marked 已停止
        let chief = element("bot-shion", in: app)
        XCTAssertTrue(chief.waitForExistence(timeout: 10), "no assistants from the server")
        chief.click()
        XCTAssertTrue(waitForText("CI 替身服务器连上了", in: app, timeout: 15), "詩音's chat did not open")
        let composer = element("composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("讲一个长故事")
        element("send", in: app).click()
        let stop = element("stop", in: app)
        let running = stop.waitForExistence(timeout: 10) && waitForText("山里有座庙", in: app, timeout: 10)
        keep(app.windows.firstMatch.screenshot(), "chatctl-2-running")
        XCTAssertTrue(running, "no stop button while the reply streamed")
        app.typeKey(".", modifierFlags: .command)
        let stopped = element("stopped", in: app)
        if !stopped.waitForExistence(timeout: 8) {
            XCTFail("⌘. did not stop the reply")
            if stop.exists { stop.click() }
        }
        let marked = stopped.waitForExistence(timeout: 8)
        keep(app.windows.firstMatch.screenshot(), "chatctl-3-stopped")
        guard marked else { return XCTFail("the stopped reply is not marked 已停止") }
        XCTAssertTrue(element("send", in: app).waitForExistence(timeout: 5), "the send button did not come back")

        // 重试: the turn is rewound on the server and the same words go again
        let retry = element("retry", in: app)
        guard retry.waitForExistence(timeout: 5) else {
            return XCTFail("no 重试 under the last reply")
        }
        retry.click()
        let retried = waitForText("（重试）故事讲完了", in: app, timeout: 20)
        keep(app.windows.firstMatch.screenshot(), "chatctl-4-retried")
        XCTAssertTrue(retried, "the retried turn did not reply")
        XCTAssertFalse(element("stopped", in: app).exists, "the stopped reply is still there after 重试")
        // selectable text is a text view to accessibility, its words in the value
        let prompts = max(app.staticTexts.matching(NSPredicate(format: "label == %@", "讲一个长故事")).count,
                          app.textViews.matching(NSPredicate(format: "value == %@", "讲一个长故事")).count)
        XCTAssertLessThanOrEqual(prompts, 1, "the prompt shows \(prompts) times after 重试")

        // ⌘F over the rows loaded: 第 120 to 129 条 are on the newest page
        app.typeKey("f", modifierFlags: .command)
        let field = element("find-field", in: app)
        guard field.waitForExistence(timeout: 5) else {
            keep(app.windows.firstMatch.screenshot(), "chatctl-5-no-find")
            return XCTFail("⌘F did not open the find bar")
        }
        field.click()
        field.typeText("第 12")
        let count = element("find-count", in: app)
        let counted = count.waitForExistence(timeout: 5)
        keep(app.windows.firstMatch.screenshot(), "chatctl-5-find")
        XCTAssertTrue(counted, "no count in the find bar")
        let first = position(count)
        XCTAssertNotNil(first, "count reads \(count.label) / \(String(describing: count.value))")
        if let first {
            XCTAssertEqual(first.0, first.1, "the newest hit is not the first one in view")
            field.typeText("\r")
            XCTAssertTrue(waitUntil(timeout: 3) { self.position(count)?.0 == first.0 - 1 }, "Return did not go to the older hit")
        }
        // 第 3 条 is pages back: ↑ reads older pages until it turns up
        field.typeKey("a", modifierFlags: .command)
        field.typeText("第 3 条")
        element("find-older", in: app).click()
        let dug = waitForText("第 3 条（你）", in: app, timeout: 30)
        keep(app.windows.firstMatch.screenshot(), "chatctl-6-find-older")
        XCTAssertTrue(dug, "older pages were not read for the hit")
        app.typeKey(.escape, modifierFlags: [])

        // 断开: the window keeps the server's data, read-only, and says from when
        app.typeKey(",", modifierFlags: .command)
        let prefs = settingsWindow(app)
        XCTAssertTrue(prefs.waitForExistence(timeout: 5))
        label("通用", in: prefs).click()
        prefs.buttons["断开"].click()
        let offline = element("connection-state", in: prefs)
        XCTAssertEqual(XCTWaiter().wait(for: [phase("未连接，现在是上次的数据", of: offline)], timeout: 10), .completed,
                       "after 断开: \(offline.label) / \(String(describing: offline.value))")
        keep(prefs.screenshot(), "chatctl-7-settings-offline")
        app.typeKey("w", modifierFlags: .command)
        // opened again, the chat starts at its newest row
        element("nav-today", in: app).click()
        element("bot-shion", in: app).click()
        let kept = waitForText("（重试）故事讲完了", in: app, timeout: 5)
        let note = waitForText("上次的数据 · ", in: app, timeout: 5)
        keep(app.windows.firstMatch.screenshot(), "chatctl-8-offline-chat")
        XCTAssertTrue(kept, "the chat went back to the demo after 断开")
        XCTAssertTrue(note, "the sidebar does not say the data is the last the server gave")
        XCTAssertFalse(element("composer", in: app).isEnabled, "the composer takes messages while not connected")
        element("nav-todos", in: app).click()
        let todos = waitForText("CI：交实验报告", in: app, timeout: 5)
        keep(app.windows.firstMatch.screenshot(), "chatctl-9-offline-todos")
        XCTAssertTrue(todos, "the plugin's todos are not kept")
        XCTAssertFalse(element("todo-toggle-td_ci_report", in: app).isEnabled, "a todo can be ticked while not connected")
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

    /// A tab, button or text by what it says.
    @MainActor
    private func label(_ text: String, in root: XCUIElement) -> XCUIElement {
        root.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private func phase(_ prefix: String, of element: XCUIElement) -> XCTNSPredicateExpectation {
        XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix), object: element)
    }

    @MainActor
    private func says(_ element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    @MainActor
    private func expect(_ identifier: String, in root: XCUIElement, _ text: String) {
        let found = element(identifier, in: root)
        XCTAssertTrue(found.waitForExistence(timeout: 3), "no \(identifier)")
        XCTAssertEqual(says(found), text, identifier)
    }

    @MainActor
    private func expect(_ identifier: String, in root: XCUIElement, startsWith text: String) {
        let found = element(identifier, in: root)
        XCTAssertTrue(found.waitForExistence(timeout: 3), "no \(identifier)")
        XCTAssertTrue(says(found).hasPrefix(text), "\(identifier): \(says(found))")
    }

    /// The find bar's "3/10" as (3, 10).
    @MainActor
    private func position(_ count: XCUIElement) -> (Int, Int)? {
        let parts = says(count).split(separator: "/").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
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

    /// Text anywhere in the app, plain or selectable (see SignInTests).
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
