import AppKit
import XCTest

/// Browser sign-in end to end, against ci/fake_hermes.py: a stand-in for Cloudflare Access and
/// the parts of a Hermes gateway Shion talks to, which the workflow starts on 127.0.0.1:8765.
/// Settings → 用浏览器登录 → the sheet runs the stand-in's login page → the loopback redirect →
/// tokens → connected → the assistants come from the server → one round trip in a chat.
/// A picture at each step; the workflow prints the stand-in's request log next to them.
final class SignInTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"

    @MainActor
    func testBrowserSignIn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "today",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        guard settings.waitForExistence(timeout: 5) else {
            keep(XCUIScreen.main.screenshot(), "signin-0-no-settings")
            return XCTFail("No Settings window")
        }
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        keep(settings.screenshot(), "signin-1-filled")

        let signIn = settings.buttons["sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.click()
        Thread.sleep(forTimeInterval: 1.5)
        keep(XCUIScreen.main.screenshot(), "signin-2-sheet")

        let account = element("account-name", in: settings)
        guard account.waitForExistence(timeout: 45) else {
            keep(XCUIScreen.main.screenshot(), "signin-3-stuck")
            return XCTFail("Not signed in")
        }
        XCTAssertTrue(says(account, "ci-user"), "signed in as \(account.label) / \(String(describing: account.value))")

        // selectable text is not a plain static text to accessibility, so look it up by id alone
        let state = element("connection-state", in: settings)
        let online = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "已连接", "已连接")
        let connected = XCTNSPredicateExpectation(predicate: online, object: state)
        let outcome = XCTWaiter().wait(for: [connected], timeout: 25)
        keep(settings.screenshot(), "signin-3-connected")
        print("connection state: \(state.label) / \(String(describing: state.value))")
        guard outcome == .completed else {
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }

        // the assistants now come from the stand-in: 詩音 and 课程（CI）
        app.typeKey("w", modifierFlags: .command)
        let chief = element("bot-shion", in: app)
        guard chief.waitForExistence(timeout: 10) else {
            keep(XCUIScreen.main.screenshot(), "signin-4-no-assistants")
            return XCTFail("No assistants from the server")
        }
        XCTAssertTrue(element("bot-study", in: app).exists)
        chief.click()
        let opened = waitForText("CI 替身服务器连上了", in: app, timeout: 15)
        keep(app.windows.firstMatch.screenshot(), "signin-4-chat")
        XCTAssertTrue(opened, "the Bot Chat did not open")

        let composer = element("composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("hello")
        element("send", in: app).click()
        let replied = waitForText("收到：hello", in: app, timeout: 15)
        keep(app.windows.firstMatch.screenshot(), "signin-5-reply")
        XCTAssertTrue(replied, "no reply streamed back")
        app.terminate()
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
        element.label == text || (element.value as? String) == text
    }

    /// Text anywhere in the app, plain or selectable (selectable text is not a static text to
    /// accessibility). `value` is only read on text elements: a toggle's is a number, which a
    /// CONTAINS predicate would throw on.
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
