import AppKit
import XCTest

/// The cards for a password or a key an assistant asked for, light and dark, on made-up requests
/// (`-ShionSecretsDemo YES`): 课程's chat with one that expired and two that wait (the sudo password
/// for a command, NOTION_API_KEY for the notion skill), 等你确认 with the two, and 今天's
/// 「需要你」 rows; and what Settings says about them. Nothing is dialled. The real thing, against
/// the stand-in, is SecretsTests.
final class SecretScreenshotTests: XCTestCase {
    @MainActor
    func testSecretCards() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            for (route, name) in [("chat-study", "secrets-chat"), ("confirm", "secrets-confirm"), ("today", "secrets-today")] {
                let app = XCUIApplication()
                app.launchArguments = [
                    "-ShionSnapshot", "YES",
                    "-ShionRoute", route,
                    "-ShionAppearance", appearance,
                    "-ShionSecretsDemo", "YES",
                    "-ApplePersistenceIgnoreState", "YES",
                ]
                app.launch()
                let window = app.windows.firstMatch
                if window.waitForExistence(timeout: 20) {
                    let card = app.descendants(matching: .any).matching(identifier: "secret-card-demo-sudo-2").firstMatch
                    if route != "today" && !card.waitForExistence(timeout: 5) {
                        XCTFail("No card for the demo's sudo password on \(route) (\(appearance))")
                    }
                    Thread.sleep(forTimeInterval: 1)
                    keep(window.screenshot(), name: "\(name)-\(appearance)")
                } else {
                    XCTFail("No window for \(route) (\(appearance))")
                }
                app.terminate()
            }
        }
    }

    /// The ⌥Space window's exchange with what 詩音 asked on the way, answered: its line stays under
    /// the reply (你回答：好). Whole screen, as the window floats over the others.
    @MainActor
    func testQuickWindowLines() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-ShionSnapshot", "YES",
                "-ShionRoute", "today",
                "-ShionAppearance", appearance,
                "-ShionQuickDemo", "YES",
                "-ShionSecretsDemo", "YES",
                "-ApplePersistenceIgnoreState", "YES",
            ]
            app.launch()
            _ = app.windows.firstMatch.waitForExistence(timeout: 20)
            let line = app.descendants(matching: .any).matching(identifier: "ask-outcome-demo-reminder").firstMatch
            if !line.waitForExistence(timeout: 10) {
                XCTFail("No line for the answered question in the ⌥Space window (\(appearance))")
            }
            Thread.sleep(forTimeInterval: 1)
            keep(XCUIScreen.main.screenshot(), name: "secrets-quick-\(appearance)")
            app.terminate()
        }
    }

    /// Settings → 服务器, scrolled to what it says about passwords and keys, light and dark.
    @MainActor
    func testSecretSettings() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-ShionSnapshot", "YES",
                "-ShionRoute", "today",
                "-ShionAppearance", appearance,
                "-ApplePersistenceIgnoreState", "YES",
            ]
            app.launch()
            _ = app.windows.firstMatch.waitForExistence(timeout: 20)
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
            guard settings.waitForExistence(timeout: 5) else {
                XCTFail("No Settings window (\(appearance))")
                app.terminate()
                continue
            }
            // Settings opens on the tab it was left on
            if !settings.textFields["server-address"].waitForExistence(timeout: 2) {
                selectTab("服务器", in: settings)
            }
            let section = settings.descendants(matching: .any).matching(identifier: "secret-settings").firstMatch
            if reveal(section, in: settings) {
                Thread.sleep(forTimeInterval: 0.5)
            } else {
                XCTFail("Settings say nothing about passwords and keys (\(appearance))")
            }
            keep(settings.screenshot(), name: "settings-secrets-\(appearance)")
            app.terminate()
        }
    }

    /// Scrolls the window until `element` can be clicked: Form rows are there before they are in view.
    @MainActor
    private func reveal(_ element: XCUIElement, in window: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        let area = window.scrollViews.firstMatch.exists ? window.scrollViews.firstMatch : window
        for delta in [-300.0, 300.0] {
            for _ in 0..<10 {
                if element.isHittable { return true }
                area.hover()
                area.scroll(byDeltaX: 0, deltaY: delta)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        return element.isHittable
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

    private func keep(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
