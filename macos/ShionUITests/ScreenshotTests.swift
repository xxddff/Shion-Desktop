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
