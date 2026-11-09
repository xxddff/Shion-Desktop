import AppKit
import XCTest

/// An assistant's page against ci/fake_hermes.py (ci/fake_profiles.py), on 通勤: its SOUL replaced
/// after another client changed it (asked first), a model the server warns about (asked first), a
/// colour and a shape for its avatar, an MCP server added, given a new URL and a token, switched to
/// OAuth, switched off and deleted, two catalog entries (one installing in the background, which
/// shows up by itself), a toolset, the settings under 其他 and a skill's lock; then the page is read
/// again from the server. A picture at each step (`page-*.png`).
final class BotPageTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"

    @MainActor
    func testAssistantPage() throws {
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
        let window = app.windows.firstMatch

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
            keep(XCUIScreen.main.screenshot(), "page-0-not-connected")
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }
        app.typeKey("w", modifierFlags: .command)

        // 通勤's page; Bot Mode gave it a picture, which the sidebar shows
        XCTAssertTrue(element("bot-commute", in: app).waitForExistence(timeout: 15), "通勤 is not listed")
        openPage(of: "commute", in: app)
        keep(window.screenshot(), "page-1-open")

        // its SOUL, changed by another client since the page read it: asked before overwriting
        let soul = reveal("assistant-soul", in: app)
        XCTAssertTrue(waitUntil(timeout: 10) { self.contains(soul, "Hermes Agent") }, "通勤's SOUL did not load")
        soul.click()
        soul.typeKey("a", modifierFlags: .command)
        soul.typeText("你是通勤助手（CI）。")
        let saveSoul = reveal("assistant-soul-save", in: app)
        saveSoul.click()
        let replace = dialogButton("替换", in: app)
        XCTAssertTrue(replace.waitForExistence(timeout: 5), "replacing the SOUL did not ask first")
        press(replace)
        let overwrite = dialogButton("覆盖", in: app)
        XCTAssertTrue(overwrite.waitForExistence(timeout: 10), "a SOUL changed by another client was not caught")
        keep(window.screenshot(), "page-2-soul-changed")
        press(overwrite)
        XCTAssertTrue(waitUntil(timeout: 10) { saveSoul.exists && !saveSoul.isEnabled }, "the SOUL was not written over the other")

        // a model the server warns about is chosen only once you agree
        reveal("assistant-model", in: app).click()
        let provider = app.menuItems["OpenRouter"].firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 5), "no OpenRouter in the model menu")
        provider.hover()
        let pricey = app.menuItems["ci-pricey"].firstMatch
        if !pricey.waitForExistence(timeout: 2) {
            // a submenu opens on hover; clicking its item opens it too
            provider.click()
        }
        XCTAssertTrue(pricey.waitForExistence(timeout: 5), "no ci-pricey under OpenRouter")
        pricey.click()
        let agree = dialogButton("换成它", in: app)
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "the pricey model did not ask first")
        keep(window.screenshot(), "page-3-model-asks")
        press(agree)
        XCTAssertTrue(waitUntil(timeout: 10) { self.shows(self.element("assistant-model", in: app), "ci-pricey") },
                      "the model did not change: \(element("assistant-model", in: app).label)")

        // the avatar: one of Bot Mode's swatches and a shape, into its section of ui_meta
        let swatch = reveal("assistant-color-4", in: app)
        swatch.click()
        XCTAssertTrue(waitUntil(timeout: 10) { self.says(swatch, "已选") }, "the colour was not taken: \(String(describing: swatch.value))")
        choose("六边形", in: "assistant-shape", app: app)
        XCTAssertTrue(waitUntil(timeout: 10) { self.shows(self.element("assistant-shape", in: app), "六边形") }, "the shape was not taken")
        keep(window.screenshot(), "page-4-look")

        // an MCP server: added, a new URL and a token, then OAuth instead, switched off, deleted
        reveal("mcp-add", in: app).click()
        type("edit-ci", into: element("mcp-new-name", in: app))
        type("https://a.example/mcp", into: element("mcp-new-url", in: app))
        element("mcp-new-create", in: app).click()
        XCTAssertTrue(element("mcp-edit-ci", in: app).waitForExistence(timeout: 10), "the server was not added")
        reveal("mcp-edit-edit-ci", in: app).click()
        type("https://b.example/mcp", into: element("mcp-edit-url", in: app))
        choose("令牌", in: "mcp-edit-auth", app: app)
        type("token-ci", into: element("mcp-edit-token", in: app))
        keep(window.screenshot(), "page-5-mcp-edit")
        element("mcp-edit-save", in: app).click()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("mcp-edit-save", in: app).exists }, "the edit was not saved")
        XCTAssertTrue(waitForText("https://b.example/mcp", in: app, timeout: 10), "the new URL is not listed")
        reveal("mcp-edit-edit-ci", in: app).click()
        XCTAssertTrue(waitUntil(timeout: 5) { self.shows(self.element("mcp-edit-auth", in: app), "令牌") },
                      "the server does not sign in with the token")
        choose("OAuth", in: "mcp-edit-auth", app: app)
        element("mcp-edit-save", in: app).click()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("mcp-edit-save", in: app).exists }, "the change to OAuth was not saved")
        XCTAssertTrue(reveal("mcp-signin-edit-ci", in: app).waitForExistence(timeout: 10), "the server does not offer an OAuth sign-in")
        let enabled = switchOf("mcp-enabled-edit-ci", in: app)
        XCTAssertEqual(isOn(enabled), true, "the rewritten server is not on")
        enabled.click()
        XCTAssertTrue(waitUntil(timeout: 10) { self.isOn(enabled) == false }, "the server was not switched off")
        reveal("mcp-remove-edit-ci", in: app).click()
        let remove = dialogButton("删除", in: app)
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "removing did not ask first")
        press(remove)
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("mcp-edit-ci", in: app).exists }, "the deleted server is still listed")

        // the catalog: fetch installs at once; slow-ci installs in the background and shows up by itself
        reveal("mcp-catalog", in: app).click()
        let fetch = element("mcp-catalog-fetch", in: app)
        XCTAssertTrue(fetch.waitForExistence(timeout: 10), "the catalog did not load")
        fetch.click()
        element("mcp-catalog-install", in: app).click()
        XCTAssertTrue(element("mcp-fetch", in: app).waitForExistence(timeout: 10), "fetch was not installed")
        reveal("mcp-catalog", in: app).click()
        let slow = element("mcp-catalog-slow-ci", in: app)
        XCTAssertTrue(slow.waitForExistence(timeout: 10), "no slow-ci in the catalog")
        slow.click()
        element("mcp-catalog-install", in: app).click()
        let installing = element("mcp-install-slow-ci", in: app).waitForExistence(timeout: 10)
        keep(window.screenshot(), "page-6-installing")
        XCTAssertTrue(installing, "the background install is not shown")
        XCTAssertTrue(element("mcp-slow-ci", in: app).waitForExistence(timeout: 40), "the background install did not show up by itself")

        // a toolset switched on
        reveal("toolset-terminal", in: app)
        let terminal = switchOf("toolset-terminal", in: app)
        XCTAssertEqual(isOn(terminal), false, "terminal starts on: \(String(describing: terminal.value))")
        terminal.click()
        XCTAssertTrue(waitUntil(timeout: 10) { self.isOn(terminal) == true }, "the toolset was not switched on")

        // 其他: approvals, both memories, the turn limit
        choose("每次问你", in: "assistant-approvals", app: app)
        reveal("assistant-memory", in: app)
        let memory = switchOf("assistant-memory", in: app)
        memory.click()
        XCTAssertTrue(waitUntil(timeout: 10) { self.isOn(memory) == false }, "memory was not switched off")
        let aboutYou = switchOf("assistant-user-profile", in: app)
        aboutYou.click()
        XCTAssertTrue(waitUntil(timeout: 10) { self.isOn(aboutYou) == false }, "the user profile was not switched off")
        choose("60 步", in: "assistant-max-turns", app: app)

        // a skill locked against the assistant's own edits
        reveal("skill-lock-arxiv", in: app)
        let lock = element("skill-lock-arxiv", in: app)
        XCTAssertEqual(isOn(lock), false, "arxiv starts locked: \(String(describing: lock.value))")
        lock.click()
        XCTAssertTrue(waitUntil(timeout: 10) { self.isOn(lock) == true }, "the skill was not locked: \(String(describing: lock.value))")

        // the page again, as the server now has it
        element("assistant-chat", in: app).click()
        XCTAssertTrue(waitForText("新的 Bot Chat。", in: app, timeout: 15), "通勤's Bot Chat did not open")
        element("assistant-settings", in: app).click()
        XCTAssertTrue(element("assistant-description", in: app).waitForExistence(timeout: 10), "the page did not open again")
        XCTAssertTrue(waitUntil(timeout: 10) { self.contains(self.reveal("assistant-soul", in: app), "你是通勤助手（CI）") },
                      "the SOUL did not stay")
        XCTAssertTrue(waitUntil(timeout: 10) { self.shows(self.reveal("assistant-model", in: app), "ci-pricey") }, "the model did not stay")
        XCTAssertTrue(says(reveal("assistant-color-4", in: app), "已选"), "the colour did not stay")
        XCTAssertTrue(shows(element("assistant-shape", in: app), "六边形"), "the shape did not stay")
        XCTAssertTrue(reveal("mcp-test-fetch", in: app).exists, "fetch did not stay")
        XCTAssertTrue(reveal("mcp-test-slow-ci", in: app).exists, "slow-ci did not stay")
        XCTAssertFalse(element("mcp-edit-ci", in: app).exists, "the deleted server came back")
        reveal("toolset-terminal", in: app)
        XCTAssertEqual(isOn(switchOf("toolset-terminal", in: app)), true, "the toolset did not stay on")
        XCTAssertTrue(shows(reveal("assistant-approvals", in: app), "每次问你"), "the approvals did not stay")
        reveal("assistant-memory", in: app)
        XCTAssertEqual(isOn(switchOf("assistant-memory", in: app)), false, "memory did not stay off")
        XCTAssertEqual(isOn(switchOf("assistant-user-profile", in: app)), false, "the user profile did not stay off")
        XCTAssertTrue(shows(reveal("assistant-max-turns", in: app), "60 步"), "the turn limit did not stay")
        reveal("skill-lock-arxiv", in: app)
        XCTAssertEqual(isOn(element("skill-lock-arxiv", in: app)), true, "the lock did not stay")
        keep(window.screenshot(), "page-7-again")
        app.terminate()
    }

    // MARK: steps

    /// A picker's item, from its pop-up menu.
    @MainActor
    private func choose(_ item: String, in identifier: String, app: XCUIApplication) {
        let picker = reveal(identifier, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no \(identifier)")
        picker.click()
        let entry = app.menuItems[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "no \(item) in \(identifier)")
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// An assistant's page, from its row's menu in the sidebar.
    @MainActor
    private func openPage(of bot: String, in app: XCUIApplication) {
        let row = element("bot-\(bot)", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(bot) in the sidebar")
        row.rightClick()
        let item = app.menuItems["助手设置…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "no 助手设置 in the menu")
        item.click()
        XCTAssertTrue(element("assistant-description", in: app).waitForExistence(timeout: 10), "\(bot)'s page did not open")
        Thread.sleep(forTimeInterval: 1)
    }

    /// An element of the long assistant page, scrolled into view (as in BotsTests).
    @MainActor
    @discardableResult
    private func reveal(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let target = element(identifier, in: app)
        if target.exists && target.isHittable { return target }
        let margin = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.55))
        for delta: CGFloat in [-300, 300] {
            for _ in 0..<12 {
                margin.hover()
                margin.scroll(byDeltaX: 0, deltaY: delta)
                Thread.sleep(forTimeInterval: 0.25)
                if target.exists && target.isHittable { return target }
            }
        }
        return target
    }

    /// A dialog's button, from the windows: the Touch Bar has the dialog's buttons too, under the
    /// same names, and XCTest cannot click those.
    @MainActor
    private func dialogButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.windows.buttons[title].firstMatch
    }

    /// A dialog's button, clicked at its place on the screen.
    @MainActor
    private func press(_ button: XCUIElement) {
        XCTAssertTrue(button.exists, "the dialog closed before its button was clicked")
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    // MARK: helpers, as in the other tests

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
        element.exists && (element.label == text || (element.value as? String) == text)
    }

    @MainActor
    private func contains(_ element: XCUIElement, _ text: String) -> Bool {
        element.exists && ((element.value as? String)?.contains(text) == true || element.label.contains(text))
    }

    /// A pop-up's or a menu's choice, wherever the control puts it: its value, title or label.
    @MainActor
    private func shows(_ element: XCUIElement, _ text: String) -> Bool {
        guard element.exists else { return false }
        return (element.value as? String)?.contains(text) == true || element.title.contains(text) || element.label.contains(text)
    }

    /// A toggle's switch. Its identifier can be on its label's texts as well, as a row's goes to
    /// each of its parts, so the switch is looked for first.
    @MainActor
    private func switchOf(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let control = app.switches.matching(identifier: identifier).firstMatch
        if control.exists { return control }
        let box = app.checkBoxes.matching(identifier: identifier).firstMatch
        return box.exists ? box : element(identifier, in: app)
    }

    /// A toggle's state: its value is a number (or its text) on macOS.
    @MainActor
    private func isOn(_ toggle: XCUIElement) -> Bool? {
        guard toggle.exists else { return nil }
        if let number = toggle.value as? NSNumber { return number.boolValue }
        if let text = toggle.value as? String { return text == "1" || text.lowercased() == "on" }
        return nil
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    /// Text anywhere in the app, plain or selectable; `value` only on text elements.
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
