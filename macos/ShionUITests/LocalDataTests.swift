import AppKit
import XCTest

/// This Mac's own data end to end, against ci/fake_hermes.py (its shion plugin is ci/fake_shion.py).
/// A runner cannot grant calendar or Accessibility access and has no Apple Intelligence, so the app
/// runs on made-up local sources that follow the clock (`-ShionLocalScript YES`): calendars with a
/// focus block under way, a cat video in front for the last 7 minutes, a usage record from earlier
/// today. Checks that the calendar is there with or without a server, that 詩音 hears she was left
/// (and back) through `focus.report` without the plugin's line showing in her chat, that 回顾 writes
/// the uploaded screen time into today's life report without the excluded app, and that unticking a
/// calendar takes its events away. A picture at each step (`local-*.png`).
final class LocalDataTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"

    @MainActor
    func testLocalData() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionLocalScript", "YES",
            "-ShionRoute", "today",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))

        // the calendars on 今天 before any server: the focus block, not the unticked calendar's event
        let calendar = waitForText("CI：实验报告 第3章", in: app, timeout: 10)
        keep(window.screenshot(), "local-1-today")
        XCTAssertTrue(calendar, "this Mac's calendar is not on 今天")
        XCTAssertFalse(waitForText("CI：不该出现的日程", in: app, timeout: 1), "an unticked calendar's event shows")

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
            keep(XCUIScreen.main.screenshot(), "local-2-not-connected")
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }
        app.typeKey("w", modifierFlags: .command)
        continueAfterFailure = true

        // connected (今天's paragraph is the plugin's now), the calendar is still this Mac's
        element("nav-today", in: app).click()
        let plugin = waitForText("（CI）早上好", in: app, timeout: 10)
        let still = waitForText("CI：实验报告 第3章", in: app, timeout: 5)
        keep(window.screenshot(), "local-2-today-connected")
        XCTAssertTrue(plugin, "今天 is not the plugin's")
        XCTAssertTrue(still, "the calendar went away with the server")

        // 7 minutes on a cat video in the focus block: the Mac tells 詩音 through the plugin, the
        // plugin's line wakes her in her Bot Chat and she answers; the line itself is hers, not yours
        element("bot-shion", in: app).click()
        let told = waitForText("（CI）「CI：实验报告 第3章」已经过了", in: app, timeout: 30)
        keep(window.screenshot(), "local-3-chief-told")
        XCTAssertTrue(told, "詩音 did not hear that you drifted off the plan")
        XCTAssertFalse(waitForText("［专注检查］", in: app, timeout: 1), "the plugin's line shows in her chat")
        // then the report comes to the front, and she hears you are back on it
        let back = waitForText("（CI）回来了就好", in: app, timeout: 40)
        keep(window.screenshot(), "local-4-chief-back")
        XCTAssertTrue(back, "詩音 did not hear that you are back on the plan")
        XCTAssertFalse(waitForText("［专注检查］", in: app, timeout: 1), "the plugin's line shows in her chat")

        // the menu bar: on the plan now
        let item = app.descendants(matching: .statusItem).firstMatch
        if item.waitForExistence(timeout: 5) {
            item.click()
            let onPlan = waitForText("在做「CI：实验报告 第3章」", in: app, timeout: 5)
            keep(XCUIScreen.main.screenshot(), "local-5-menubar")
            XCTAssertTrue(onPlan, "the menu bar's focus check is not on the plan")
            app.typeKey(.escape, modifierFlags: [])
        } else {
            XCTFail("No status item")
        }

        // 回顾 wrote today's screen time from what the Mac uploaded; 1Password is left out of it
        element("nav-reports", in: app).click()
        let screenTime = waitForText("Xcode 40 分钟", in: app, timeout: 30)
        keep(window.screenshot(), "local-6-report")
        XCTAssertTrue(screenTime, "the uploaded usage is not in today's screen time")
        XCTAssertFalse(waitForText("1Password", in: app, timeout: 1), "an excluded app reached the server")

        // Settings → 这台 Mac: what 詩音 was told last, the upload, and the calendars
        guard let local = openLocalSettings(app, waitingFor: "focus-check") else {
            keep(XCUIScreen.main.screenshot(), "local-7-no-settings")
            return XCTFail("no 这台 Mac tab in Settings")
        }
        let sent = element("focus-last-sent", in: local)
        if reveal(sent, in: local) {
            keep(local.screenshot(), "local-7-settings-focus")
            XCTAssertTrue(says(sent, "回到「CI：实验报告 第3章」上了"), "last report: \(sent.label) / \(String(describing: sent.value))")
        } else {
            keep(local.screenshot(), "local-7-settings-focus")
            XCTFail("no last report in Settings")
        }
        let upload = element("usage-last-upload", in: local)
        if reveal(upload, in: local) {
            XCTAssertFalse(says(upload, "还没发过") || says(upload, "没发出去"), "upload: \(upload.label) / \(String(describing: upload.value))")
        }
        // untick 专注: its focus block leaves 今天
        let focusCalendar = element("calendar-fx-focus", in: local)
        if reveal(focusCalendar, in: local) {
            focusCalendar.click()
            Thread.sleep(forTimeInterval: 0.5)
            keep(local.screenshot(), "local-8-settings-calendars")
        } else {
            XCTFail("no 专注 calendar in Settings")
        }
        app.typeKey("w", modifierFlags: .command)
        element("nav-today", in: app).click()
        let gone = !waitForText("CI：实验报告 第3章", in: app, timeout: 2)
        keep(window.screenshot(), "local-9-unticked")
        XCTAssertTrue(gone, "an unticked calendar's event stays on 今天")
        // 课表's class starts 90 minutes after launch: still there whenever that is today
        if Calendar.current.isDateInToday(Date().addingTimeInterval(100 * 60)) {
            XCTAssertTrue(waitForText("CI：线性代数", in: app, timeout: 2), "the ticked calendars' events went too")
        }
        app.terminate()
    }

    /// Settings, on its 这台 Mac tab (the window opens on the tab used last); nil without it.
    @MainActor
    private func openLocalSettings(_ app: XCUIApplication, waitingFor identifier: String) -> XCUIElement? {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        guard settings.waitForExistence(timeout: 5) else { return nil }
        let mine = element(identifier, in: settings)
        if !mine.waitForExistence(timeout: 1) {
            let tabs = [settings.toolbarButtons["这台 Mac"], settings.toolbars.buttons["这台 Mac"], settings.buttons["这台 Mac"],
                        settings.radioButtons["这台 Mac"]]
            if let tab = tabs.first(where: { $0.exists }) {
                tab.click()
            } else {
                let any = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "这台 Mac")).firstMatch
                if any.waitForExistence(timeout: 3) { any.click() }
            }
        }
        return mine.waitForExistence(timeout: 10) ? settings : nil
    }

    /// Scrolls Settings until `element` can be clicked. Which sign of a wheel delta scrolls down is
    /// the runner's business: one way, then the other.
    @MainActor
    private func reveal(_ element: XCUIElement, in window: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        let area = window.scrollViews.firstMatch.exists ? window.scrollViews.firstMatch : window
        for delta in [-300.0, 300.0] {
            for _ in 0..<10 {
                if element.isHittable { return true }
                area.hover()
                area.scroll(byDeltaX: 0, deltaY: delta)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        return element.isHittable
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
        element.label.contains(text) || ((element.value as? String)?.contains(text) ?? false)
    }

    /// Text anywhere in the app, plain or selectable. `value` is only read on text elements: a
    /// toggle's is a number, which a CONTAINS predicate would throw on.
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
