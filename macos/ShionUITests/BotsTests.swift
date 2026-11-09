import AppKit
import XCTest

/// The assistants against ci/fake_hermes.py (their routes are in ci/fake_profiles.py): sign in,
/// make 课程 总秘书 (the shion plugin is only in 詩音's profile, so 今天 goes back to the demo) and
/// 詩音 again, see that Hermes's default profile cannot be deleted and hide it, make an assistant,
/// change its description and SOUL, add an MCP server and test it, turn a skill off, read the page
/// again from the server, and delete the assistant. A picture at each step (`bots-*.png`).
final class BotsTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"

    @MainActor
    func testAssistants() throws {
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
        var settings = settingsWindow(app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings window")
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        settings.buttons["sign-in"].click()
        let state = element("connection-state", in: settings)
        let online = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "已连接", "已连接")
        let connected = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: online, object: state)], timeout: 45)
        guard connected == .completed else {
            keep(XCUIScreen.main.screenshot(), "bots-0-not-connected")
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }
        app.typeKey("w", modifierFlags: .command)

        // 詩音 leads: her paragraph on 今天 comes from the shion plugin in her profile
        XCTAssertTrue(element("bot-default", in: app).waitForExistence(timeout: 10), "Hermes's default profile is not listed")
        let summary = waitForText("（CI）早上好", in: app, timeout: 15)
        keep(window.screenshot(), "bots-1-today")
        XCTAssertTrue(summary, "詩音's paragraph from the plugin is not on 今天")

        // Settings → 助手: 课程 becomes 总秘书. The plugin is not in its profile, so 今天 has the
        // demo's line again
        settings = openAssistantSettings(app)
        choose("课程（CI）", in: "chief-picker", window: settings, app: app)
        keep(settings.screenshot(), "bots-2-chief-study")
        app.typeKey("w", modifierFlags: .command)
        let studyLeads = waitUntil(timeout: 10) {
            let study = self.element("bot-study", in: app), shion = self.element("bot-shion", in: app)
            return study.exists && shion.exists && study.frame.minY < shion.frame.minY
        }
        let demoAgain = waitUntil(timeout: 10) { self.findText("（CI）早上好", in: app) == nil }
        keep(window.screenshot(), "bots-3-today-study")
        XCTAssertTrue(studyLeads, "课程 does not lead the sidebar")
        XCTAssertTrue(demoAgain, "今天 still shows 詩音's paragraph from the plugin")

        // Hermes's default profile has a page, but no way to delete it
        openPage(of: "default", in: app)
        let deleteDefault = reveal("assistant-delete", in: app)
        keep(window.screenshot(), "bots-4-default-page")
        XCTAssertTrue(deleteDefault.exists, "no delete button on the default profile's page")
        XCTAssertFalse(deleteDefault.isEnabled, "the default profile can be deleted")

        // back to 詩音, and the default profile hidden
        settings = openAssistantSettings(app)
        choose("詩音", in: "chief-picker", window: settings, app: app)
        let shown = element("show-default", in: settings)
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "no 显示 toggle for the default profile")
        shown.click()
        Thread.sleep(forTimeInterval: 0.5)
        keep(settings.screenshot(), "bots-5-default-hidden")
        app.typeKey("w", modifierFlags: .command)
        let hidden = waitUntil(timeout: 10) { !self.element("bot-default", in: app).exists }
        XCTAssertTrue(hidden, "the hidden default profile is still in the sidebar")
        element("nav-today", in: app).click()
        let pluginBack = waitForText("（CI）早上好", in: app, timeout: 15)
        keep(window.screenshot(), "bots-6-shion-again")
        XCTAssertTrue(pluginBack, "詩音's paragraph did not come back with her")

        // a new assistant, from the sidebar's menu; its page opens once it is made
        element("bot-commute", in: app).rightClick()
        let new = app.menuItems["新建助手…"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 3), "no 新建助手 in the menu")
        new.click()
        let name = element("new-assistant-name", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5), "no 新建助手 sheet")
        name.click()
        name.typeText("mail-ci")
        let title = element("new-assistant-title", in: app)
        title.click()
        title.typeText("邮件（CI）")
        let description = element("new-assistant-description", in: app)
        description.click()
        description.typeText("邮件")
        let soul = element("new-assistant-soul", in: app)
        soul.click()
        soul.typeText("你是邮件助手（CI）。")
        keep(window.screenshot(), "bots-7-new")
        element("new-assistant-create", in: app).click()
        let made = element("bot-mail-ci", in: app).waitForExistence(timeout: 20)
        let page = element("assistant-description", in: app).waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 1)
        keep(window.screenshot(), "bots-8-new-page")
        XCTAssertTrue(made, "the new assistant is not in the sidebar")
        XCTAssertTrue(page, "the new assistant's page did not open")
        XCTAssertTrue(waitForText("邮件（CI）", in: app, timeout: 5), "the new assistant is not named by its title")
        XCTAssertTrue(says(element("assistant-description", in: app), "邮件"), "the description it was made with is not shown")

        // its description, then its SOUL (replacing it asks first)
        let field = element("assistant-description", in: app)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("收发邮件（CI）")
        let save = element("assistant-basics-save", in: app)
        XCTAssertTrue(save.waitForExistence(timeout: 5), "no 保存 for the description")
        save.click()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("assistant-basics-save", in: app).exists }, "the description was not saved")
        let editor = reveal("assistant-soul", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "no SOUL editor")
        XCTAssertTrue(waitUntil(timeout: 10) { self.contains(editor, "你是邮件助手（CI）") }, "the SOUL it was made with is not shown")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("你是邮件助手（CI 改过）。")
        let saveSoul = reveal("assistant-soul-save", in: app)
        saveSoul.click()
        let replace = dialogButton("替换", in: app)
        XCTAssertTrue(replace.waitForExistence(timeout: 5), "replacing the SOUL did not ask first")
        keep(window.screenshot(), "bots-9-soul-asks")
        press(replace)
        XCTAssertTrue(waitUntil(timeout: 10) { saveSoul.exists && !saveSoul.isEnabled }, "the SOUL was not saved")

        // an MCP server, tested
        reveal("mcp-add", in: app).click()
        let serverName = element("mcp-new-name", in: app)
        XCTAssertTrue(serverName.waitForExistence(timeout: 5), "no 添加 MCP 服务器 sheet")
        serverName.click()
        serverName.typeText("notes-ci")
        let url = element("mcp-new-url", in: app)
        url.click()
        url.typeText("https://mcp.example.dev/notes")
        element("mcp-new-create", in: app).click()
        let added = element("mcp-notes-ci", in: app).waitForExistence(timeout: 10)
        XCTAssertTrue(added, "the MCP server is not listed")
        reveal("mcp-test-notes-ci", in: app).click()
        let works = waitForText("能用 · 2 个工具", in: app, timeout: 15)
        keep(window.screenshot(), "bots-10-mcp")
        XCTAssertTrue(works, "testing the MCP server did not say it works")

        // a skill turned off
        reveal("skill-arxiv", in: app)
        let skill = switchOf("skill-arxiv", in: app)
        XCTAssertTrue(skill.exists, "no arxiv skill")
        XCTAssertEqual(isOn(skill), true, "arxiv starts off: \(String(describing: skill.value))")
        skill.click()
        let off = waitUntil(timeout: 10) { self.isOn(skill) == false }
        keep(window.screenshot(), "bots-11-skill")
        XCTAssertTrue(off, "the skill did not turn off: \(String(describing: skill.value))")

        // the page again, as the server now has it
        element("assistant-chat", in: app).click()
        XCTAssertTrue(waitForText("新的 Bot Chat。", in: app, timeout: 15), "the new assistant's Bot Chat did not open")
        element("assistant-settings", in: app).click()
        XCTAssertTrue(element("assistant-description", in: app).waitForExistence(timeout: 10), "the page did not open again")
        let reread = waitUntil(timeout: 10) { self.says(self.element("assistant-description", in: app), "收发邮件（CI）") }
        keep(window.screenshot(), "bots-12-again")
        XCTAssertTrue(reread, "the description did not stay: \(String(describing: element("assistant-description", in: app).value))")
        XCTAssertTrue(waitUntil(timeout: 10) { self.contains(self.reveal("assistant-soul", in: app), "CI 改过") }, "the SOUL did not stay")
        XCTAssertTrue(reveal("mcp-test-notes-ci", in: app).exists, "the MCP server did not stay")
        reveal("skill-arxiv", in: app)
        XCTAssertEqual(isOn(switchOf("skill-arxiv", in: app)), false, "the skill did not stay off")

        // and deleted, after asking
        reveal("assistant-delete", in: app).click()
        let confirm = dialogButton("删除", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "deleting did not ask first")
        keep(window.screenshot(), "bots-13-delete-asks")
        press(confirm)
        let gone = waitUntil(timeout: 20) { !self.element("bot-mail-ci", in: app).exists }
        keep(window.screenshot(), "bots-14-deleted")
        XCTAssertTrue(gone, "the deleted assistant is still in the sidebar")
        app.terminate()
    }

    // MARK: steps

    @MainActor
    private func settingsWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
    }

    /// Settings, on its 助手 tab.
    @MainActor
    private func openAssistantSettings(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = settingsWindow(app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings window")
        let picker = element("chief-picker", in: settings)
        if !picker.waitForExistence(timeout: 1) {
            let tabs = [settings.toolbarButtons["助手"], settings.toolbars.buttons["助手"], settings.buttons["助手"],
                        settings.radioButtons["助手"]]
            if let tab = tabs.first(where: { $0.exists }) {
                tab.click()
            } else {
                let any = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "助手")).firstMatch
                XCTAssertTrue(any.waitForExistence(timeout: 3), "no 助手 tab in Settings")
                any.click()
            }
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no 总秘书 picker on the 助手 tab")
        return settings
    }

    /// A picker's item, from its pop-up menu.
    @MainActor
    private func choose(_ item: String, in identifier: String, window: XCUIElement, app: XCUIApplication) {
        let picker = element(identifier, in: window)
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

    /// An element of the long assistant page, scrolled into view: the page is a form, which lays out
    /// only what is near the screen. The wheel turns at the page's right margin, where no row (the
    /// SOUL editor scrolls by itself) takes it. Which sign of a delta goes down is the runner's
    /// business, so both are tried.
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
    /// same names, and XCTest cannot click those (`app.buttons[…]` found the Touch Bar's first).
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

    /// The first text element showing `text`, plain or selectable; nil when none is there.
    @MainActor
    private func findText(_ text: String, in app: XCUIApplication) -> XCUIElement? {
        let either = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        return [app.staticTexts.matching(either).firstMatch, app.textViews.matching(either).firstMatch]
            .first { $0.exists }
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
