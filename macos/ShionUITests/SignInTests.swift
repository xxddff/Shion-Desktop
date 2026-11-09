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

        let account = settings.staticTexts["account-name"]
        guard account.waitForExistence(timeout: 45) else {
            keep(XCUIScreen.main.screenshot(), "signin-3-stuck")
            return XCTFail("Not signed in")
        }
        XCTAssertTrue(says(account, "ci-user"), "signed in as \(account.label) / \(String(describing: account.value))")

        let state = settings.staticTexts["connection-state"]
        let online = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "已连接", "已连接")
        let connected = XCTNSPredicateExpectation(predicate: online, object: state)
        let outcome = XCTWaiter().wait(for: [connected], timeout: 25)
        keep(settings.screenshot(), "signin-3-connected")
        guard outcome == .completed else {
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }

        // the assistants now come from the stand-in: 詩音 and 课程（CI）
        app.typeKey("w", modifierFlags: .command)
        let chief = app.descendants(matching: .any).matching(identifier: "bot-shion").firstMatch
        guard chief.waitForExistence(timeout: 10) else {
            keep(XCUIScreen.main.screenshot(), "signin-4-no-assistants")
            return XCTFail("No assistants from the server")
        }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "bot-study").firstMatch.exists)
        chief.click()
        let greeting = text(in: app, containing: "CI 替身服务器连上了")
        XCTAssertTrue(greeting.waitForExistence(timeout: 15), "the Bot Chat did not open")
        keep(app.windows.firstMatch.screenshot(), "signin-4-chat")

        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("hello")
        app.buttons["send"].firstMatch.click()
        let reply = text(in: app, containing: "收到：hello")
        let replied = reply.waitForExistence(timeout: 15)
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
    private func says(_ element: XCUIElement, _ text: String) -> Bool {
        element.label == text || (element.value as? String) == text
    }

    @MainActor
    private func text(in app: XCUIApplication, containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    private func keep(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
