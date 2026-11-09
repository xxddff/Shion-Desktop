import AppKit
import XCTest

/// The ⌥Space window end to end, against ci/fake_hermes.py (its answers to the window are in
/// ci/fake_quick.py): sign in, press the global shortcut over another app, send 詩音 a sentence,
/// watch her reply stream into the window, open the whole chat, and see the window start afresh.
/// A picture at each step (`quick-*.png`).
final class QuickAskTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"
    /// The stand-in streams its answer to this a few characters at a time (fake_quick.py).
    private let sentence = "小窗：明天几点出门？"

    @MainActor
    func testQuickAsk() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "today",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))

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
            keep(XCUIScreen.main.screenshot(), "quick-0-not-connected")
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element("bot-shion", in: app).waitForExistence(timeout: 10), "no assistants from the server")

        let field = app.textFields["quick-field"]
        let bar = element("quick-bar", in: app)

        // 1. the global shortcut with another app in front: the window comes up over it, and the
        // same shortcut puts it away again. Only the system's hot key can do this (the menu's copy
        // of the shortcut only works while Shion is the active app).
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        Thread.sleep(forTimeInterval: 1.5)
        finder.typeKey(" ", modifierFlags: .option)
        let global = field.waitForExistence(timeout: 6)
        keep(XCUIScreen.main.screenshot(), "quick-1-over-finder")
        print("over Finder: window \(global ? "up" : "not up"), opened by \(String(describing: bar.value))")
        // a failure here is kept, and the rest still runs: it tells the window apart from the shortcut
        continueAfterFailure = true
        XCTAssertTrue(global, "⌥Space with Finder in front did not bring up the window")
        if global {
            XCTAssertEqual(bar.value as? String, "hotkey", "the window came up, but not by the global shortcut")
            // pressed where the keys now are, the window's field: typing at Finder could hand the
            // keyboard back to Finder first, and then the shortcut brings the window back instead
            field.typeKey(" ", modifierFlags: .option)
            let away = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: field)
            XCTAssertEqual(XCTWaiter().wait(for: [away], timeout: 5), .completed, "pressing ⌥Space again did not put it away")
        } else {
            // Finder had the keys: ⌥Space is its full-screen Quick Look, should anything be selected
            finder.typeKey(.escape, modifierFlags: [])
        }
        continueAfterFailure = false

        // 2. from Shion: the shortcut (or, should it not reach the window, the 前往 menu); the
        // sentence goes to 詩音 and her reply streams in under it
        app.activate()
        Thread.sleep(forTimeInterval: 1)
        open(app, field)
        field.click()
        field.typeText(sentence)
        app.typeKey(.return, modifierFlags: [])
        let answer = element("quick-answer", in: app)
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "the sentence did not show in the window")
        let reply = "收到：" + sentence
        // the cursor of a reply still arriving, before the whole of it is there
        let streaming = waitForText("▍", in: answer, timeout: 10)
        let early = waitForText(reply, in: answer, timeout: 0)
        keep(XCUIScreen.main.screenshot(), "quick-2-streaming")
        XCTAssertTrue(streaming, "the reply did not stream into the window")
        XCTAssertFalse(early, "the whole reply was there at once")
        let replied = waitForText(reply, in: answer, timeout: 15)
        Thread.sleep(forTimeInterval: 0.5)
        keep(XCUIScreen.main.screenshot(), "quick-3-replied")
        XCTAssertTrue(replied, "the reply did not finish in the window")
        XCTAssertFalse(waitForText("▍", in: answer, timeout: 0), "the reply still looks unfinished")

        // 3. the whole chat: the window goes, 詩音's chat opens in the main window with the exchange
        element("quick-open", in: app).click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "the window stayed after opening the chat")
        let titled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "title CONTAINS %@", "詩音"), object: window)
        XCTAssertEqual(XCTWaiter().wait(for: [titled], timeout: 5), .completed, "詩音's chat did not open: \(window.title)")
        let inChat = waitForText(reply, in: element("transcript", in: app), timeout: 10)
        keep(window.screenshot(), "quick-4-full-chat")
        XCTAssertTrue(inChat, "the exchange is not in 詩音's chat")

        // 4. an answered sentence went with the window: it comes back empty, and Esc puts it away
        open(app, field)
        XCTAssertFalse(element("quick-answer", in: app).waitForExistence(timeout: 1), "the window came back with the old answer")
        keep(XCUIScreen.main.screenshot(), "quick-5-again")
        app.typeKey(.escape, modifierFlags: [])
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 5), .completed, "Esc did not put the window away")
        app.terminate()
    }

    /// The window by the shortcut, or by the 前往 menu when the shortcut does not reach it.
    @MainActor
    private func open(_ app: XCUIApplication, _ field: XCUIElement) {
        if !field.exists {
            app.typeKey(" ", modifierFlags: .option)
        }
        if field.waitForExistence(timeout: 4) {
            print("opened by \(String(describing: element("quick-bar", in: app).value))")
            return
        }
        print("⌥Space did not bring the window up; using 前往 → 跟詩音说…")
        app.menuBars.menuBarItems["前往"].click()
        app.menuItems["跟詩音说…"].click()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no ⌥Space window from the menu either")
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

    /// Text under `root`, plain or selectable (selectable text is not a static text to
    /// accessibility). `value` is only read on text elements: a toggle's is a number, which a
    /// CONTAINS predicate would throw on. A timeout of 0 looks once.
    @MainActor
    private func waitForText(_ text: String, in root: XCUIElement, timeout: TimeInterval) -> Bool {
        let either = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        let queries = [
            root.staticTexts.matching(either),
            root.textViews.matching(either),
            root.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)),
        ]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if queries.contains(where: { $0.firstMatch.exists }) { return true }
            if timeout > 0 {
                Thread.sleep(forTimeInterval: 0.3)
            }
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
