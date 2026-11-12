import AppKit
import XCTest

/// Opens every page in light and dark and keeps a screenshot of the window for each, plus the
/// menu bar panel and Settings. CI exports the attachments as PNGs (see
/// .github/workflows/macos.yml), so the UI can be reviewed from pictures. The app pins its demo
/// date and stills its animations in snapshot mode, so runs are comparable.
final class ScreenshotTests: XCTestCase {
    private let routes = ["today", "confirm", "todos", "calendar", "reports", "board", "desktop", "chat-shion", "chat-study",
                          "chat-news", "chat-mail"]

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

    /// 课程's 工作记录 on the demo day (`-ShionTab work`), light and dark, and a card of it opened
    /// on the side.
    @MainActor
    func testWorkLog() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = launch(route: "chat-study", appearance: appearance, extra: ["-ShionTab", "work"])
            let window = app.windows.firstMatch
            guard window.waitForExistence(timeout: 20) else {
                XCTFail("No window for 工作记录 (\(appearance))")
                app.terminate()
                continue
            }
            Thread.sleep(forTimeInterval: 1)
            keep(window.screenshot(), name: "work-study-\(appearance)")
            XCTAssertFalse(window.staticTexts["助手忙碌时"].exists,
                           "The hidden chat's picker label leaked into the work log accessibility tree")
            let row = window.buttons["work-g5d2"]
            if row.waitForExistence(timeout: 5) {
                let clickable = XCTWaiter().wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "hittable == true"), object: row)], timeout: 5) == .completed
                if clickable {
                    row.click()
                    XCTAssertTrue(window.buttons["work-detail-close"].waitForExistence(timeout: 5),
                                  "Clicking the work log card did not open its detail (\(appearance))")
                    keep(window.screenshot(), name: "work-study-detail-\(appearance)")
                } else {
                    let tree = XCTAttachment(string: window.debugDescription)
                    tree.name = "work-study-\(appearance)-accessibility.txt"
                    tree.lifetime = .keepAlways
                    add(tree)
                    XCTFail("The visible work log card is not clickable (\(appearance)): \(row.debugDescription)")
                }
            } else {
                XCTFail("No card in 工作记录 (\(appearance))")
            }
            app.terminate()
        }
    }

    /// The demo's long code line and wide table, scrolled sideways in their own boxes: a picture of
    /// each, and a line saying whether the right end came into view and the words before stayed.
    /// BoardTests asserts the same on the stand-in's reply; a failure here would fail this step and
    /// skip that one, so this only reports.
    @MainActor
    func testWideBlocksScroll() throws {
        // 詩音's reply ends with a code block whose first line runs past it
        var app = launch(route: "chat-shion", appearance: "light")
        var window = app.windows.firstMatch
        if window.waitForExistence(timeout: 20) {
            Thread.sleep(forTimeInterval: 1)
            let code = element("markdown-code", in: app)
            report("詩音's code line", area: code, end: text(containing: "BinaryHeap", in: code),
                   before: text(containing: "作业4 要做两件事", in: app), window: window, name: "chat-shion-code-scrolled")
        }
        app.terminate()

        // 资讯's sources side by side: six columns, wider than the reply even with their cells wrapped
        app = launch(route: "chat-news", appearance: "light")
        window = app.windows.firstMatch
        if window.waitForExistence(timeout: 20) {
            Thread.sleep(forTimeInterval: 1)
            report("资讯's table", area: element("markdown-table-scroll", in: app), end: text(equalTo: "和传言的出入", in: app),
                   before: text(containing: "找到三处说法", in: app), window: window, name: "chat-news-table-scrolled")
        }
        app.terminate()
    }

    @MainActor
    private func report(_ what: String, area: XCUIElement, end: XCUIElement, before: XCUIElement, window: XCUIElement, name: String) {
        guard area.waitForExistence(timeout: 5), end.exists, before.exists else {
            print("sideways: \(what): no scrolling box (\(area.exists)), right end (\(end.exists)) or words before it (\(before.exists))")
            keep(window.screenshot(), name: name + "-missing")
            return
        }
        let past = end.frame.maxX > area.frame.maxX + 1
        let x = before.frame.minX
        let revealed = scrollSideways(area, revealing: end)
        keep(window.screenshot(), name: name)
        print("sideways: \(what): past the edge at first \(past), in view after scrolling \(revealed), "
              + "words before moved \(abs(before.frame.minX - x) > 1) (\(end.frame) in \(area.frame))")
    }

    /// Scrolls `area` sideways until `target`'s right edge is inside it. Which sign of a wheel
    /// delta moves content left is the runner's business: at the leading edge a nudge the other
    /// way moves nothing, so the first nudge tells.
    @MainActor
    private func scrollSideways(_ area: XCUIElement, revealing target: XCUIElement) -> Bool {
        let inside = { target.frame.maxX <= area.frame.maxX + 2 }
        let start = target.frame.minX
        var step: CGFloat = -300
        for attempt in 0..<10 {
            if inside() { return true }
            area.scroll(byDeltaX: step, deltaY: 0)
            Thread.sleep(forTimeInterval: 0.4)
            if attempt == 0, target.frame.minX >= start - 1 {
                step = -step
            }
        }
        return inside()
    }

    @MainActor
    private func element(_ identifier: String, in root: XCUIElement) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A text, plain or selectable (selectable text is a text view to accessibility), containing
    /// `part`: its string is its label or its value.
    @MainActor
    private func text(containing part: String, in root: XCUIElement) -> XCUIElement {
        let either = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", part, part)
        let plain = root.staticTexts.matching(either).firstMatch
        return plain.exists ? plain : root.textViews.matching(either).firstMatch
    }

    @MainActor
    private func text(equalTo whole: String, in root: XCUIElement) -> XCUIElement {
        let exact = NSPredicate(format: "label == %@ OR value == %@", whole, whole)
        let plain = root.staticTexts.matching(exact).firstMatch
        return plain.exists ? plain : root.textViews.matching(exact).firstMatch
    }

    /// The mail chat's composer holding what it is about to send: a picture and a file ready, a
    /// picture going up, a file too big to send (`-ShionDemoDrafts YES`).
    @MainActor
    func testComposerAttachments() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = launch(route: "chat-mail", appearance: appearance, extra: ["-ShionDemoDrafts", "YES"])
            let window = app.windows.firstMatch
            if window.waitForExistence(timeout: 20) {
                Thread.sleep(forTimeInterval: 1)
                keep(window.screenshot(), name: "chat-mail-attachments-\(appearance)")
            } else {
                XCTFail("No window for the mail chat (\(appearance))")
            }
            app.terminate()
        }
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

    /// ⌘F in 詩音's chat (demo): 「作业」 is in your message (purple) and in her reply below it; the
    /// hit in view in the system's find yellow, the others in a paler one, light and dark.
    @MainActor
    func testFind() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = launch(route: "chat-shion", appearance: appearance)
            let window = app.windows.firstMatch
            guard window.waitForExistence(timeout: 20) else {
                XCTFail("No window for find (\(appearance))")
                app.terminate()
                continue
            }
            Thread.sleep(forTimeInterval: 1)
            app.typeKey("f", modifierFlags: .command)
            let field = window.descendants(matching: .any).matching(identifier: "find-field").firstMatch
            if field.waitForExistence(timeout: 5) {
                field.click()
                field.typeText("作业")
                Thread.sleep(forTimeInterval: 1)
                keep(window.screenshot(), name: "find-\(appearance)")
            } else {
                XCTFail("⌘F did not open the find bar (\(appearance))")
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
            for (key, title) in [("2", "待你处理"), ("6", "看板"), ("1", "今天")] {
                app.typeKey(key, modifierFlags: .command)
                XCTAssertTrue(waitForTitle(window, title), "⌘\(key) did not open \(title): \(window.title)")
            }

            // the ⌥Space window from the menu, empty; with no server, a sentence stays in it,
            // marked as waiting to go out; Esc puts it away
            app.menuBars.menuBarItems["前往"].click()
            app.menuItems.matching(NSPredicate(format: "title BEGINSWITH '跟' AND title ENDSWITH '说…'")).firstMatch.click()
            let quick = app.textFields["quick-field"]
            if quick.waitForExistence(timeout: 5) {
                Thread.sleep(forTimeInterval: 0.8)
                keep(XCUIScreen.main.screenshot(), name: "quick-empty-\(appearance)")
                quick.typeText("明天几点出门？")
                app.typeKey(.return, modifierFlags: [])
                let waiting = app.descendants(matching: .any)["quick-waiting"]
                XCTAssertTrue(waiting.waitForExistence(timeout: 5), "a sentence sent without a server does not show as waiting")
                Thread.sleep(forTimeInterval: 0.5)
                keep(XCUIScreen.main.screenshot(), name: "quick-waiting-\(appearance)")
                app.typeKey(.escape, modifierFlags: [])
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: quick)
                XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "Esc did not put the window away")
            } else {
                keep(XCUIScreen.main.screenshot(), name: "quick-empty-\(appearance)-missing")
                XCTFail("前往 → 跟…说… did not bring up the window (\(appearance))")
            }
            app.terminate()
        }
    }

    /// Settings scrolled to 图片和文件.
    @MainActor
    func testMediaSettings() throws {
        continueAfterFailure = true
        let app = launch(route: "today", appearance: "light")
        _ = app.windows.firstMatch.waitForExistence(timeout: 20)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        guard settings.waitForExistence(timeout: 5) else {
            keep(XCUIScreen.main.screenshot(), name: "settings-media-screen")
            return XCTFail("No Settings window")
        }
        // on its 服务器 tab, where the section is
        if !settings.textFields["server-address"].waitForExistence(timeout: 1) {
            selectTab("服务器", in: settings)
        }
        let usage = settings.descendants(matching: .any).matching(identifier: "media-cache").firstMatch
        let form = settings.scrollViews.firstMatch
        // which sign scrolls down is the runner's business: one way a few times, then the other
        for delta in [-400.0, -400, -400, 400, 400, 400, 400, 400, 400] {
            if usage.exists && usage.isHittable { break }
            form.hover()
            form.scroll(byDeltaX: 0, deltaY: delta)
            Thread.sleep(forTimeInterval: 0.4)
        }
        Thread.sleep(forTimeInterval: 0.5)
        keep(settings.screenshot(), name: "settings-media-light")
        XCTAssertTrue(usage.exists, "no 图片和文件 section in Settings")
        app.terminate()
    }

    /// Settings → 快捷键: the global shortcut's recorder, light and dark. Left there, Settings
    /// still opens on 服务器 next time in a test run.
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
            app.terminate()

            let again = launch(route: "today", appearance: appearance)
            _ = again.windows.firstMatch.waitForExistence(timeout: 20)
            again.typeKey(",", modifierFlags: .command)
            let reopened = again.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
            XCTAssertTrue(reopened.waitForExistence(timeout: 5), "No Settings window the second time")
            XCTAssertTrue(reopened.textFields["server-address"].waitForExistence(timeout: 5),
                          "Settings did not open on 服务器 after being left on 快捷键")
            again.terminate()
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
