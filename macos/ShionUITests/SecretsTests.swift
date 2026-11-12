import AppKit
import XCTest

/// Passwords and keys an assistant asks for, end to end against ci/fake_hermes.py (the requests
/// are in ci/fake_secrets.py, shaped like Hermes's `sudo` and `secret` server requests): sign in,
/// open 通勤's chat and have it install ffmpeg, which asks for the sudo password and, at the same
/// time, NOTION_API_KEY for the notion skill. Both cards show in the chat and in 待你处理; the
/// password is typed and sent from 待你处理 (the stand-in checks it without writing it down, and the
/// command goes through), the key is declined in the chat, and each answer leaves the other card
/// alone. Then one nobody answers expires, and one asked just before the connection drops is
/// answered after the reconnect. A picture at each step (`secrets-*.png`).
final class SecretsTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"
    /// What the stand-in checks the sudo password against (fake_secrets.py PASSWORD).
    private let password = "ci-sudo-Pa55"
    /// The stand-in's request ids (fake_secrets.py): Hermes's are random.
    private let sudoId = "srq-00000000c101"
    private let keyId = "srq-00000000c102"
    private let lateId = "srq-00000000c103"
    private let dropId = "srq-00000000c104"

    @MainActor
    func testPasswordsAndKeys() throws {
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

        // sign in as SignInTests does; Settings opens on the tab it was last left on
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings window")
        if !settings.textFields["server-address"].waitForExistence(timeout: 2) {
            selectTab("服务器", in: settings)
        }
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        settings.buttons["sign-in"].click()
        let state = element("connection-state", in: settings)
        let online = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "已连接", "已连接")
        let connected = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: online, object: state)], timeout: 45)
        guard connected == .completed else {
            keep(XCUIScreen.main.screenshot(), "secrets-0-not-connected")
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }
        app.typeKey("w", modifierFlags: .command)
        // from here a check that fails is kept and the rest still runs; only a missing card stops it
        continueAfterFailure = true

        // 0. 课程's approval (raised once Shion attaches its chat): answered in 待你处理, it leaves
        // there and stays in 课程's chat as a line saying what was chosen
        let commute = element("bot-commute", in: app)
        guard commute.waitForExistence(timeout: 10) else { return XCTFail("no assistants from the server") }
        element("nav-confirm", in: app).click()
        let allow = app.buttons["允许这一次"].firstMatch
        if allow.waitForExistence(timeout: 15) {
            allow.click()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: allow)
            XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "the approval stayed in 待你处理")
            element("bot-study", in: app).click()
            XCTAssertTrue(waitForLabel(element("ask-outcome-ap-moodle", in: app), "已允许这一次", timeout: 15),
                          "课程's chat has no line for the approval")
            Thread.sleep(forTimeInterval: 0.5)
            keep(window.screenshot(), "secrets-0-approved")
        } else {
            XCTFail("课程's approval did not reach 待你处理")
        }

        // 1. 通勤's chat (created on the stand-in), and a turn that asks for both at once
        commute.click()
        XCTAssertTrue(waitForText("新的 Bot Chat。", in: app, timeout: 15), "通勤's chat did not open")
        say("装 ffmpeg（CI）", in: app)
        let sudoCard = element("secret-card-\(sudoId)", in: app)
        let keyCard = element("secret-card-\(keyId)", in: app)
        let asked = sudoCard.waitForExistence(timeout: 15) && keyCard.waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 0.8)
        keep(window.screenshot(), "secrets-1-asked")
        guard asked else { return XCTFail("no cards for the sudo password and NOTION_API_KEY in the chat") }
        // who wants it, what for, what it is; and how long Hermes still waits
        XCTAssertTrue(waitForText("要 sudo 密码", in: app, timeout: 2), "the sudo card does not say what it wants")
        XCTAssertTrue(waitForText("sudo apt-get install -y ffmpeg", in: sudoCard, timeout: 2), "the sudo card does not show the command")
        XCTAssertTrue(waitForText("terminal", in: sudoCard, timeout: 2), "the sudo card does not name the tool")
        XCTAssertTrue(waitForText("NOTION_API_KEY", in: keyCard, timeout: 2), "the key's card does not name the variable")
        XCTAssertTrue(waitForText("技能 notion", in: keyCard, timeout: 2), "the key's card does not name the skill")
        XCTAssertTrue(element("secret-left-\(sudoId)", in: app).exists, "no countdown on the sudo card")
        XCTAssertTrue(element("secret-left-\(keyId)", in: app).exists, "no countdown on the key's card")

        // 2. both wait in 待你处理 too; the password is typed and sent there
        element("nav-confirm", in: app).click()
        let field = app.secureTextFields["secret-field-\(sudoId)"]
        let listed = field.waitForExistence(timeout: 10)
        keep(window.screenshot(), "secrets-2-confirm")
        guard listed else { return XCTFail("the sudo password is not in 待你处理") }
        XCTAssertTrue(app.secureTextFields["secret-field-\(keyId)"].exists, "NOTION_API_KEY is not in 待你处理")
        field.click()
        field.typeText(password)
        // dots on screen, and to accessibility
        XCTAssertFalse(String(describing: field.value).contains(password), "the field's value shows the password")
        keep(window.screenshot(), "secrets-3-typed")
        element("secret-submit-\(sudoId)", in: app).click()
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [sent], timeout: 10), .completed, "the sudo password stayed in 待你处理 after 提交")
        XCTAssertTrue(app.secureTextFields["secret-field-\(keyId)"].exists, "answering the password took the key's card with it")

        // 3. back in the chat: the password went, the key still waits; it is declined there
        commute.click()
        XCTAssertTrue(waitForLabel(element("ask-outcome-\(sudoId)", in: app), "已提交", timeout: 10), "the sudo card does not say 已提交")
        XCTAssertFalse(app.secureTextFields["secret-field-\(sudoId)"].exists, "the sudo card kept its field")
        let keyField = app.secureTextFields["secret-field-\(keyId)"]
        XCTAssertTrue(keyField.exists && keyField.isEnabled, "the key's field went with the password")
        element("secret-deny-\(keyId)", in: app).click()
        XCTAssertTrue(waitForLabel(element("ask-outcome-\(keyId)", in: app), "已拒绝", timeout: 10), "the key's card does not say 已拒绝")
        // the turn goes on: the command ran with the password, the skill went without its key
        XCTAssertTrue(waitForText("ffmpeg 装好了（CI）", in: app, timeout: 15), "the sudo command did not go through")
        XCTAssertTrue(waitForText("没有 NOTION_API_KEY", in: app, timeout: 5), "the declined key did not reach the stand-in")
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "secrets-4-answered")
        XCTAssertFalse(shows(password, in: app), "the password shows somewhere in the window")

        // 4. one nobody answers: it expires, its field goes
        say("会过期（CI）", in: app)
        let late = app.secureTextFields["secret-field-\(lateId)"]
        let came = late.waitForExistence(timeout: 15)
        keep(window.screenshot(), "secrets-5-waiting")
        guard came else { return XCTFail("no card for the request that expires") }
        XCTAssertTrue(waitForLabel(element("ask-outcome-\(lateId)", in: app), "已过期", timeout: 25), "the card does not say 已过期")
        XCTAssertFalse(late.exists, "the expired card kept its field")
        XCTAssertTrue(waitForText("没等到 sudo 密码", in: app, timeout: 10), "the turn did not end after the request expired")
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "secrets-6-expired")

        // 5. the connection drops right after a request: the card stays but cannot be answered until
        // the reconnect's resume finds the request still waiting (open_requests); then the password
        // goes on the new connection, once. The tunnel stays down until the card has been seen
        // waiting (StandIn.tunnelUp)
        say("断线（CI）", in: app)
        let dropCard = element("secret-card-\(dropId)", in: app)
        guard dropCard.waitForExistence(timeout: 15) else { return XCTFail("no card for the request asked before the drop") }
        let offline = waitForText("连接", in: dropCard, timeout: 8)
        keep(window.screenshot(), "secrets-7-offline")
        XCTAssertTrue(offline, "the card did not say the connection was down")
        StandIn.tunnelUp("5. the connection drops right after a request")
        let dropField = app.secureTextFields["secret-field-\(dropId)"]
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: dropField)
        guard XCTWaiter().wait(for: [back], timeout: 40) == .completed else {
            keep(window.screenshot(), "secrets-7-not-back")
            return XCTFail("the request could not be answered after the reconnect")
        }
        dropField.click()
        dropField.typeText(password)
        element("secret-submit-\(dropId)", in: app).click()
        XCTAssertTrue(waitForLabel(element("ask-outcome-\(dropId)", in: app), "已提交", timeout: 10), "the card does not say 已提交 after the reconnect")
        XCTAssertTrue(waitForText("sox 装好了（CI）", in: app, timeout: 15), "the password given after the reconnect did not reach the stand-in")
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "secrets-8-reconnected")
        // the chat caught up after the reconnect (replayed, or read again); the lines are Shion's own and stay
        XCTAssertTrue(waitForLabel(element("ask-outcome-\(sudoId)", in: app), "已提交", timeout: 5),
                      "the sudo password's line went with the reconnect")
        element("bot-study", in: app).click()
        XCTAssertTrue(waitForLabel(element("ask-outcome-ap-moodle", in: app), "已允许这一次", timeout: 10),
                      "the approval's line went with the reconnect")
        commute.click()

        // 待你处理 holds none of them now
        element("nav-confirm", in: app).click()
        Thread.sleep(forTimeInterval: 0.8)
        keep(window.screenshot(), "secrets-9-confirm-after")
        for id in [sudoId, keyId, lateId, dropId] {
            XCTAssertFalse(element("secret-card-\(id)", in: app).exists, "\(id) is still in 待你处理")
        }
        XCTAssertFalse(shows(password, in: app), "the password shows somewhere in the window")
        app.terminate()
    }

    /// A sentence to the chat on screen.
    @MainActor
    private func say(_ text: String, in app: XCUIApplication) {
        let composer = element("composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "no composer")
        composer.click()
        composer.typeText(text)
        element("send", in: app).click()
    }

    /// Whether `text` is in any text, field or label in the app: a value it should never show.
    @MainActor
    private func shows(_ text: String, in app: XCUIApplication) -> Bool {
        let either = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        let named = NSPredicate(format: "label CONTAINS %@", text)
        return [app.staticTexts.matching(either), app.textViews.matching(either), app.textFields.matching(either),
                app.secureTextFields.matching(either), app.descendants(matching: .any).matching(named)]
            .contains { $0.firstMatch.exists }
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        // a Text's words are its value on macOS, its label stays empty
        let says = NSPredicate(format: "label == %@ OR value == %@", label, label)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: says, object: element)], timeout: timeout) == .completed
    }

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
    /// accessibility). `value` is only read on text elements: a toggle's is a number.
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
