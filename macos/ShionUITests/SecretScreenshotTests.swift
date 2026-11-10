import AppKit
import XCTest

/// The cards for a password or a key an assistant asked for, light and dark, on made-up requests
/// (`-ShionSecretsDemo YES`): 课程's chat with one that expired and two that wait (the sudo password
/// for a command, NOTION_API_KEY for the notion skill), 等你确认 with the two, and 今天's
/// 「需要你」 rows. Nothing is dialled. The real thing, against the stand-in, is SecretsTests.
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

    private func keep(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
