import AppKit
import XCTest

/// Opens every page in light and dark and keeps a screenshot of the window for each, plus the
/// menu bar panel and Settings. CI exports the attachments as PNGs (see
/// .github/workflows/macos.yml), so the UI can be reviewed from pictures. The app pins its demo
/// date and stills its animations in snapshot mode, so runs are comparable.
final class ScreenshotTests: XCTestCase {
    private let routes = ["today", "confirm", "todos", "calendar", "reports", "board", "desktop", "chat-shion", "chat-study"]

    @MainActor
    func testEveryPage() throws {
        continueAfterFailure = true
        if let screen = NSScreen.main {
            print("Screen: \(screen.frame.size) at \(screen.backingScaleFactor)x")
        }
        for appearance in ["light", "dark"] {
            for route in routes {
                let app = launch(route: route, appearance: appearance)
                let window = app.windows.firstMatch
                if window.waitForExistence(timeout: 20) {
                    Thread.sleep(forTimeInterval: 1)
                    keep(window.screenshot(), name: "\(route)-\(appearance)")
                } else {
                    XCTFail("No window for \(route) (\(appearance))")
                }
                app.terminate()
            }
        }
    }

    /// 詩音's own settings page (`assistant-shion`), on the demo's content.
    @MainActor
    func testAssistantPage() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = launch(route: "assistant-shion", appearance: appearance)
            let window = app.windows.firstMatch
            if window.waitForExistence(timeout: 20) {
                Thread.sleep(forTimeInterval: 1)
                keep(window.screenshot(), name: "assistant-shion-\(appearance)")
            } else {
                XCTFail("No window for the assistant page (\(appearance))")
            }
            app.terminate()
        }
    }

    @MainActor
    func testMenuBarAndSettings() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = launch(route: "today", appearance: appearance)
            _ = app.windows.firstMatch.waitForExistence(timeout: 20)

            let item = app.descendants(matching: .statusItem).firstMatch
            if item.waitForExistence(timeout: 5) {
                item.click()
                Thread.sleep(forTimeInterval: 1.5)
                keep(XCUIScreen.main.screenshot(), name: "menubar-\(appearance)")
                app.typeKey(.escape, modifierFlags: [])
            } else {
                XCTFail("No status item")
            }

            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
            if settings.waitForExistence(timeout: 5) {
                Thread.sleep(forTimeInterval: 1)
                keep(settings.screenshot(), name: "settings-\(appearance)")
            } else {
                keep(XCUIScreen.main.screenshot(), name: "settings-\(appearance)-screen")
            }
            app.terminate()
        }
    }

    /// Settings signed in (to a made-up server, nothing is dialled), then with the session token.
    @MainActor
    func testSettingsSignedIn() throws {
        continueAfterFailure = true
        let app = launch(route: "today", appearance: "light", extra: ["-ShionDemoSignIn", "YES"])
        _ = app.windows.firstMatch.waitForExistence(timeout: 20)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        guard settings.waitForExistence(timeout: 5) else {
            keep(XCUIScreen.main.screenshot(), name: "settings-signedin-screen")
            return XCTFail("No Settings window")
        }
        Thread.sleep(forTimeInterval: 1)
        keep(settings.screenshot(), name: "settings-signedin-light")
        // a segmented picker's segments are radio buttons to accessibility, or plain buttons
        let token = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "会话令牌")).firstMatch
        if token.waitForExistence(timeout: 3) {
            token.click()
            Thread.sleep(forTimeInterval: 0.5)
            keep(settings.screenshot(), name: "settings-token-light")
        } else {
            print("No 会话令牌 segment to click")
        }
        app.terminate()
    }

    /// Settings' 服务器体检, with the screenshot run's made-up results: nothing is dialled.
    @MainActor
    func testServerCheck() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = launch(route: "today", appearance: appearance, extra: ["-ShionDemoSignIn", "YES"])
            _ = app.windows.firstMatch.waitForExistence(timeout: 20)
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
            if settings.waitForExistence(timeout: 5) {
                selectTab("服务器体检", in: settings)
                Thread.sleep(forTimeInterval: 1)
                keep(settings.screenshot(), name: "settings-check-\(appearance)")
                selectTab("服务器", in: settings)
            } else {
                XCTFail("No Settings window (\(appearance))")
            }
            app.terminate()
        }
    }

    /// 詩音's chat ending in a failed turn (demo, `-ShionFailureDemo YES`): what went wrong and what
    /// to do, then 详情 opened on Hermes's own words, light and dark.
    @MainActor
    func testFailedTurn() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = launch(route: "chat-shion", appearance: appearance, extra: ["-ShionFailureDemo", "YES"])
            let window = app.windows.firstMatch
            guard window.waitForExistence(timeout: 20) else {
                XCTFail("No window for the failed turn (\(appearance))")
                app.terminate()
                continue
            }
            Thread.sleep(forTimeInterval: 1)
            keep(window.screenshot(), name: "failed-turn-\(appearance)")
            let details = window.descendants(matching: .any).matching(identifier: "failure-details").firstMatch
            if details.waitForExistence(timeout: 5) {
                details.click()
                Thread.sleep(forTimeInterval: 0.8)
                keep(window.screenshot(), name: "failed-turn-details-\(appearance)")
            } else {
                XCTFail("No 详情 on the failed turn (\(appearance))")
            }
            app.terminate()
        }
    }

    /// The ⌥Space window with a sentence and 詩音's answer in it (demo), then empty from the 前往
    /// menu, with what it says when no server is connected; ⌘K over the main window, a search,
    /// ↓ and Return; ⌘1…⌘7. Whole screen for the window, which floats over the others.
    @MainActor
    func testQuickAskAndJump() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let demo = launch(route: "today", appearance: appearance, extra: ["-ShionQuickDemo", "YES"])
            _ = demo.windows.firstMatch.waitForExistence(timeout: 20)
            if demo.textFields["quick-field"].waitForExistence(timeout: 10) {
                Thread.sleep(forTimeInterval: 1)
                keep(XCUIScreen.main.screenshot(), name: "quick-\(appearance)")
            } else {
                keep(XCUIScreen.main.screenshot(), name: "quick-\(appearance)-missing")
                XCTFail("No ⌥Space window (\(appearance))")
            }
            demo.terminate()

            let app = launch(route: "today", appearance: appearance)
            let window = app.windows.firstMatch
            _ = window.waitForExistence(timeout: 20)
            Thread.sleep(forTimeInterval: 1)

            // ⌘K: the pages and the assistants; 「课」 finds 课程 and two todos; ↓ and Return open
            // the first todo in 待办
            app.typeKey("k", modifierFlags: .command)
            let field = app.textFields["jump-field"]
            if field.waitForExistence(timeout: 5) {
                Thread.sleep(forTimeInterval: 0.5)
                keep(window.screenshot(), name: "jump-\(appearance)")
                field.typeText("课")
                Thread.sleep(forTimeInterval: 0.5)
                keep(window.screenshot(), name: "jump-search-\(appearance)")
                XCTAssertTrue(app.descendants(matching: .any)["jump-bot-study"].exists, "「课」 did not find 课程")
                XCTAssertTrue(app.descendants(matching: .any)["jump-todo-td2"].exists, "「课」 did not find the todo 机器学习 课前小测")
                app.typeKey(.downArrow, modifierFlags: [])
                app.typeKey(.return, modifierFlags: [])
                XCTAssertTrue(waitForTitle(window, "待办"), "↓ Return did not open the todo in 待办: \(window.title)")
                Thread.sleep(forTimeInterval: 0.8)
                keep(window.screenshot(), name: "jump-todo-\(appearance)")
                XCTAssertFalse(field.exists, "the palette stayed up")
            } else {
                keep(window.screenshot(), name: "jump-\(appearance)-missing")
                XCTFail("No ⌘K palette (\(appearance))")
            }

            // ⌘1…⌘7 are the pages in sidebar order
            for (key, title) in [("2", "等你确认"), ("6", "看板"), ("1", "今天")] {
                app.typeKey(key, modifierFlags: .command)
                XCTAssertTrue(waitForTitle(window, title), "⌘\(key) did not open \(title): \(window.title)")
            }

            // the ⌥Space window from the menu, empty; with no server, a sentence stays with the
            // connection's state under it; Esc puts it away
            app.menuBars.menuBarItems["前往"].click()
            app.menuItems["跟詩音说…"].click()
            let quick = app.textFields["quick-field"]
            if quick.waitForExistence(timeout: 5) {
                Thread.sleep(forTimeInterval: 0.8)
                keep(XCUIScreen.main.screenshot(), name: "quick-empty-\(appearance)")
                quick.typeText("明天几点出门？")
                app.typeKey(.return, modifierFlags: [])
                let state = app.descendants(matching: .any)["quick-status"]
                XCTAssertTrue(state.waitForExistence(timeout: 5), "no state under a sentence sent without a server")
                Thread.sleep(forTimeInterval: 0.5)
                keep(XCUIScreen.main.screenshot(), name: "quick-offline-\(appearance)")
                app.typeKey(.escape, modifierFlags: [])
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: quick)
                XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "Esc did not put the window away")
            } else {
                keep(XCUIScreen.main.screenshot(), name: "quick-empty-\(appearance)-missing")
                XCTFail("前往 → 跟詩音说… did not bring up the window (\(appearance))")
            }
            app.terminate()
        }
    }

    /// Settings → 快捷键: the global shortcut's recorder, light and dark.
    @MainActor
    func testShortcutSettings() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = launch(route: "today", appearance: appearance)
            _ = app.windows.firstMatch.waitForExistence(timeout: 20)
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
            guard settings.waitForExistence(timeout: 5) else {
                keep(XCUIScreen.main.screenshot(), name: "settings-shortcut-\(appearance)-screen")
                XCTFail("No Settings window")
                app.terminate()
                continue
            }
            selectTab("快捷键", in: settings)
            let recorder = settings.descendants(matching: .any)["quick-shortcut"]
            XCTAssertTrue(recorder.waitForExistence(timeout: 5), "no shortcut recorder on the 快捷键 tab")
            Thread.sleep(forTimeInterval: 0.8)
            keep(settings.screenshot(), name: "settings-shortcut-\(appearance)")
            // Settings opens on the tab it was left on, next launch too: leave it on 服务器, where
            // the sign-in tests that run next fill in the server
            selectTab("服务器", in: settings)
            XCTAssertTrue(settings.textFields["server-address"].waitForExistence(timeout: 5), "Settings not back on 服务器")
            app.terminate()
        }
    }

    /// A Settings tab: a toolbar button, a radio button or a plain one, depending on the system.
    @MainActor
    private func selectTab(_ name: String, in settings: XCUIElement) {
        let tabs = [settings.toolbarButtons[name], settings.toolbars.buttons[name], settings.buttons[name],
                    settings.radioButtons[name]]
        if let tab = tabs.first(where: { $0.exists }) {
            tab.click()
        } else {
            settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch.click()
        }
    }

    @MainActor
    private func waitForTitle(_ window: XCUIElement, _ title: String, timeout: TimeInterval = 5) -> Bool {
        let titled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "title CONTAINS %@", title), object: window)
        return XCTWaiter().wait(for: [titled], timeout: timeout) == .completed
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

    private func keep(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
