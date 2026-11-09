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

            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
            if settings.waitForExistence(timeout: 5) {
                Thread.sleep(forTimeInterval: 1)
                for (identifier, name) in [("calendar-fx-lessons", "calendars"), ("focus-check", "focus"), ("usage-log", "usage")] {
                    if reveal(element(identifier, in: settings), in: settings) {
                        Thread.sleep(forTimeInterval: 0.3)
                        keep(settings.screenshot(), "settings-\(name)-\(appearance)")
                    } else {
                        keep(settings.screenshot(), "settings-\(name)-\(appearance)-missing")
                        XCTFail("No \(identifier) in Settings (\(appearance))")
                    }
                }
            } else {
                XCTFail("No Settings window (\(appearance))")
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
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        if settings.waitForExistence(timeout: 5), reveal(element("calendar-access", in: settings), in: settings) {
            keep(settings.screenshot(), "settings-calendars-noaccess-light")
        } else {
            XCTFail("No calendar access button in Settings")
        }
        app.terminate()
    }

    /// Scrolls Settings until `element` can be clicked: one way, then the other (the sign of a
    /// wheel delta is the runner's business).
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
