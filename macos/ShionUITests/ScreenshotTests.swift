import AppKit
import XCTest

/// Opens every page in light and dark and keeps a screenshot of the window for each, plus the
/// menu bar panel and Settings. CI exports the attachments as PNGs (see
/// .github/workflows/macos.yml), so the UI can be reviewed from pictures. The app pins its demo
/// date and stills its animations in snapshot mode, so runs are comparable.
final class ScreenshotTests: XCTestCase {
    private let routes = ["today", "confirm", "todos", "calendar", "reports", "board", "desktop", "chat-shion", "chat-study", "chat-news"]

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

    /// A code line and a table wider than the reply scroll sideways in their own boxes: what was
    /// past the right edge comes into view, and the words around them stay where they are.
    @MainActor
    func testWideBlocksScroll() throws {
        continueAfterFailure = true
        // 詩音's reply ends with a code block whose first line runs past it
        var app = launch(route: "chat-shion", appearance: "light")
        var window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "no window for 詩音's chat")
        Thread.sleep(forTimeInterval: 1)
        let code = element("markdown-code", in: app)
        let line = text(containing: "BinaryHeap", in: code)
        let before = text(containing: "作业4 要做两件事", in: app)
        if code.waitForExistence(timeout: 5), line.exists, before.exists {
            let past = line.frame.maxX > code.frame.maxX + 1
            let x = before.frame.minX
            let shown = scrollSideways(code, revealing: line)
            keep(window.screenshot(), name: "chat-shion-code-scrolled")
            XCTAssertTrue(past, "the long code line fits already: \(line.frame) in \(code.frame)")
            XCTAssertTrue(shown, "scrolling the code block did not bring the line's end into view: \(line.frame) in \(code.frame)")
            XCTAssertEqual(before.frame.minX, x, accuracy: 1, "the words before the code moved with it")
        } else {
            XCTFail("no code block, its long line or the words before it")
        }
        app.terminate()

        // 资讯's sources side by side: six columns, wider than the reply even with their cells wrapped
        app = launch(route: "chat-news", appearance: "light")
        window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "no window for 资讯's chat")
        Thread.sleep(forTimeInterval: 1)
        let table = element("markdown-table-scroll", in: app)
        let last = text(equalTo: "和传言的出入", in: app)
        let words = text(containing: "找到三处说法", in: app)
        if table.waitForExistence(timeout: 5), last.exists, words.exists {
            let past = last.frame.maxX > table.frame.maxX + 1
            let x = words.frame.minX
            let shown = scrollSideways(table, revealing: last)
            keep(window.screenshot(), name: "chat-news-table-scrolled")
            XCTAssertTrue(past, "the wide table's last column fits already: \(last.frame) in \(table.frame)")
            XCTAssertTrue(shown, "scrolling the table did not bring its last column into view: \(last.frame) in \(table.frame)")
            XCTAssertEqual(words.frame.minX, x, accuracy: 1, "the words before the table moved with it")
        } else {
            keep(window.screenshot(), name: "chat-news-no-wide-table")
            XCTFail("the wide table does not scroll on its own, or its last column or the words before it are missing")
        }
        app.terminate()
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
