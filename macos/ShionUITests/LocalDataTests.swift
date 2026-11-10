import AppKit
import XCTest

/// This Mac's own data end to end, against ci/fake_hermes.py (its shion plugin is ci/fake_shion.py).
/// A runner cannot grant calendar or Accessibility access and has no Apple Intelligence, so the app
/// runs on made-up local sources that follow the clock (`-ShionLocalScript YES`): calendars with a
/// focus block under way, a cat video in front for the last 7 minutes, a usage record from earlier
/// today. Checks that the calendar is there with or without a server, that 詩音 hears she was left
/// (and back) through `focus.report` without the plugin's line showing in her chat, that 回顾 writes
/// the uploaded screen time into today's life report without the excluded app, that unticking a
/// calendar takes its events away, and that the plugin wakes whoever is chosen 总秘书 on this Mac
/// (its `chief_profile` follows: Hermes's default profile has the plugin on the stand-in). A picture at each step
/// (`local-*.png`).
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

        // sign in as SignInTests does; Settings opens on the tab it was last left on
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings window")
        if !settings.textFields["server-address"].waitForExistence(timeout: 2) {
            select("服务器", in: settings)
        }
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
        guard let local = openSettings(app, tab: "这台 Mac", waitingFor: "focus-check") else {
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
        select("服务器", in: local)
        XCTAssertTrue(local.textFields["server-address"].waitForExistence(timeout: 5), "Settings not back on 服务器")
        app.typeKey("w", modifierFlags: .command)
        element("nav-today", in: app).click()
        let gone = !waitForText("CI：实验报告 第3章", in: app, timeout: 2)
        keep(window.screenshot(), "local-9-unticked")
        XCTAssertTrue(gone, "an unticked calendar's event stays on 今天")
        // 课表's class starts 90 minutes after launch: still there whenever that is today
        if Calendar.current.isDateInToday(Date().addingTimeInterval(100 * 60)) {
            XCTAssertTrue(waitForText("CI：线性代数", in: app, timeout: 2), "the ticked calendars' events went too")
        }

        // Hermes's default profile becomes 总秘书 in Settings → 助手: Shion sets the plugin's
        // chief_profile in that profile, and the focus check says the plugin wakes it; then back to 詩音
        guard let assistants = openSettings(app, tab: "助手", waitingFor: "chief-picker") else {
            keep(XCUIScreen.main.screenshot(), "local-10-no-assistants")
            return XCTFail("no 助手 tab in Settings")
        }
        choose("Hermes（CI）", in: "chief-picker", window: assistants, app: app)
        select("这台 Mac", in: assistants)
        let chief = element("focus-chief", in: assistants)
        let other = reveal(chief, in: assistants) && waitUntil(timeout: 10) { self.says(chief, "Hermes（CI）") }
        keep(assistants.screenshot(), "local-10-chief-default")
        XCTAssertTrue(other, "the focus check does not say the plugin wakes Hermes（CI）: \(chief.label) / \(String(describing: chief.value))")
        select("助手", in: assistants)
        choose("詩音", in: "chief-picker", window: assistants, app: app)
        select("这台 Mac", in: assistants)
        let shion = reveal(chief, in: assistants) && waitUntil(timeout: 10) { self.says(chief, "詩音") }
        keep(assistants.screenshot(), "local-11-chief-shion")
        XCTAssertTrue(shion, "the focus check does not say the plugin wakes 詩音 again: \(chief.label) / \(String(describing: chief.value))")
        select("服务器", in: assistants)
        XCTAssertTrue(assistants.textFields["server-address"].waitForExistence(timeout: 5), "Settings not back on 服务器")
        app.typeKey("w", modifierFlags: .command)
        app.terminate()
    }

    /// Settings, on that tab (the window opens on the tab used last); nil without it, with Settings
    /// put back on 服务器.
    @MainActor
    private func openSettings(_ app: XCUIApplication, tab: String, waitingFor identifier: String) -> XCUIElement? {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        guard settings.waitForExistence(timeout: 5) else { return nil }
        let mine = element(identifier, in: settings)
        if !mine.waitForExistence(timeout: 1) {
            select(tab, in: settings)
        }
        if mine.waitForExistence(timeout: 10) { return settings }
        select("服务器", in: settings)
        return nil
    }

    /// A picker's item, from its pop-up menu.
    @MainActor
    private func choose(_ item: String, in identifier: String, window: XCUIElement, app: XCUIApplication) {
        let picker = element(identifier, in: window)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no \(identifier)")
        picker.click()
        let entry = app.menuItems[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "no \(item) in \(identifier)")
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)
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

    /// A Settings tab, by its name. Back on 服务器 before a test lets go, so a test after it finds the
    /// server's fields however the window comes back.
    @MainActor
    private func select(_ name: String, in settings: XCUIElement) {
        let tabs = [settings.toolbarButtons[name], settings.toolbars.buttons[name], settings.buttons[name],
                    settings.radioButtons[name]]
        if let tab = tabs.first(where: { $0.exists }) {
            tab.click()
        } else {
            let any = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
            if any.waitForExistence(timeout: 3) { any.click() }
        }
    }

    /// Scrolls Settings until `element` is in full view under the toolbar (a row under the toolbar's
    /// glass counts as hittable, but a click there lands on the toolbar); with `atTop`, until it is
    /// just under the toolbar, so what follows it is in view too. Which sign of a wheel delta scrolls
    /// which way is the runner's business: a step that moves the page the wrong way flips it.
    @MainActor
    private func reveal(_ element: XCUIElement, in window: XCUIElement, atTop: Bool = false) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        let area = window.scrollViews.firstMatch.exists ? window.scrollViews.firstMatch : window
        let toolbar = window.toolbars.firstMatch
        var up: CGFloat = -1  // the sign of a delta that moves the page up
        var signKnown = false
        for _ in 0..<40 {
            let top = (toolbar.exists ? toolbar.frame.maxY : window.frame.minY) + 6
            let bottom = window.frame.maxY - 6
            let frame = element.frame
            let inView = frame.minY >= top && frame.maxY <= bottom
            // where its top should be: under the toolbar with room for its section's header, or
            // wherever it is fully in view
            let target = atTop ? top + 48 : min(max(frame.minY, top), bottom - frame.height)
            let distance = frame.minY - target  // more than 0: the page has to move up
            if inView, abs(distance) <= (atTop ? 16 : 0.5) { return true }
            area.hover()
            area.scroll(byDeltaX: 0, deltaY: (distance > 0 ? up : -up) * max(16, min(240, abs(distance))))
            Thread.sleep(forTimeInterval: 0.25)
            let moved = element.frame.minY - frame.minY
            if abs(moved) < 1 {
                // nothing moved: the wrong way at an end of the page, or the end it has to go to
                if !signKnown {
                    up = -up
                    signKnown = true
                    continue
                }
                return inView
            }
            signKnown = true
            if (distance > 0) != (moved < 0) { up = -up }
        }
        return false
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
