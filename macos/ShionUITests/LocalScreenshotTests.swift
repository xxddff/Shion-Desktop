import AppKit
import XCTest

/// Screenshots of this Mac's own data, light and dark, on the made-up calendars, windows and app
/// use that screenshot runs have instead of real ones (nothing is asked for or read): Settings'
/// calendars (by account, each with its color, tick and what it holds), the focus check and the
/// usage record; the menu bar's focus check opened on the windows seen; and, without calendar
/// access, the demo's week with the way to allow it. The week with this Mac's calendars is
/// ScreenshotTests' `calendar-*`.
final class LocalScreenshotTests: XCTestCase {
    @MainActor
    func testLocalData() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = launch(route: "today", appearance: appearance)
            _ = app.windows.firstMatch.waitForExistence(timeout: 20)

            let item = app.descendants(matching: .statusItem).firstMatch
            if item.waitForExistence(timeout: 5) {
                item.click()
                let row = element("focus-row", in: app)
                if row.waitForExistence(timeout: 3) {
                    row.click()
                    Thread.sleep(forTimeInterval: 0.8)
                } else {
                    XCTFail("No focus check in the menu bar (\(appearance))")
                }
                keep(XCUIScreen.main.screenshot(), "menubar-focus-\(appearance)")
                app.typeKey(.escape, modifierFlags: [])
            } else {
                XCTFail("No status item")
            }

            if let settings = openLocalSettings(app, waitingFor: "focus-check") {
                Thread.sleep(forTimeInterval: 1)
                // the calendars as the tab opens; the focus check and the usage record each from its
                // first row, just under the toolbar, so the section follows in full
                for (identifier, name, atTop) in [("calendar-fx-lessons", "calendars", false), ("focus-check", "focus", true),
                                                  ("usage-log", "usage", true)] {
                    if reveal(element(identifier, in: settings), in: settings, atTop: atTop) {
                        Thread.sleep(forTimeInterval: 0.3)
                        keep(settings.screenshot(), "settings-\(name)-\(appearance)")
                    } else {
                        keep(settings.screenshot(), "settings-\(name)-\(appearance)-missing")
                        XCTFail("No \(identifier) in Settings (\(appearance))")
                    }
                }
                // Settings opens on the tab it was left on, next launch too: ScreenshotTests, which
                // runs next, takes 服务器 as it opens
                select("服务器", in: settings)
                XCTAssertTrue(settings.textFields["server-address"].waitForExistence(timeout: 5), "Settings not back on 服务器")
            } else {
                keep(XCUIScreen.main.screenshot(), "settings-local-\(appearance)-missing")
                XCTFail("No 这台 Mac tab in Settings (\(appearance))")
            }
            app.terminate()
        }

        // calendars Shion may not read yet: the demo's week, and the way to allow it
        let app = launch(route: "calendar", appearance: "light", extra: ["-ShionCalendarAccess", "none"])
        let window = app.windows.firstMatch
        if window.waitForExistence(timeout: 20) {
            Thread.sleep(forTimeInterval: 1)
            keep(window.screenshot(), "calendar-noaccess-light")
            XCTAssertTrue(element("calendar-allow", in: app).exists, "no way to allow calendar access on 日程")
        }
        if let settings = openLocalSettings(app, waitingFor: "calendar-access") {
            if reveal(element("calendar-access", in: settings), in: settings) {
                keep(settings.screenshot(), "settings-calendars-noaccess-light")
            } else {
                XCTFail("No calendar access button in Settings")
            }
            select("服务器", in: settings)
            XCTAssertTrue(settings.textFields["server-address"].waitForExistence(timeout: 5), "Settings not back on 服务器")
        } else {
            XCTFail("No 这台 Mac tab in Settings")
        }
        app.terminate()
    }

    /// Settings, on its 这台 Mac tab (the window opens on the tab used last); nil without it,
    /// with Settings put back on 服务器.
    @MainActor
    private func openLocalSettings(_ app: XCUIApplication, waitingFor identifier: String) -> XCUIElement? {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        guard settings.waitForExistence(timeout: 5) else { return nil }
        let mine = element(identifier, in: settings)
        if !mine.waitForExistence(timeout: 1) {
            select("这台 Mac", in: settings)
        }
        if mine.waitForExistence(timeout: 10) { return settings }
        select("服务器", in: settings)
        return nil
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
    private func element(_ identifier: String, in root: XCUIElement) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func launch(route: String, appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", route,
            "-ShionAppearance", appearance,
            "-ApplePersistenceIgnoreState", "YES",
        ] + extra
        app.launch()
        return app
    }

    private func keep(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
