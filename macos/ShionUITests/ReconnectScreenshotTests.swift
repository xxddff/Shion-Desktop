import AppKit
import XCTest

/// The connection being got back, light and dark, on the demo (`-ShionReconnectDemo YES`; nothing is
/// dialled): the sidebar says 重新连接中… and when it tries again, and 詩音's chat has a message that
/// did not go out (没发出去 with 重发), one sent as the connection went (等连上后确认), and two said
/// since that wait under it, saying when they were written (reconnect-chat-*.png). ReconnectTests
/// goes through the same against the stand-in.
final class ReconnectScreenshotTests: XCTestCase {
    @MainActor
    func testReconnecting() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-ShionSnapshot", "YES",
                "-ShionRoute", "chat-shion",
                "-ShionAppearance", appearance,
                "-ApplePersistenceIgnoreState", "YES",
                // a server in the sidebar, as when a connection that had worked went
                "-ShionDemoSignIn", "YES",
                "-ShionReconnectDemo", "YES",
            ]
            app.launch()
            let window = app.windows.firstMatch
            guard window.waitForExistence(timeout: 20) else {
                XCTFail("No window (\(appearance))")
                app.terminate()
                continue
            }
            let waiting = app.descendants(matching: .any).matching(identifier: "waiting")
            XCTAssertTrue(waiting.firstMatch.waitForExistence(timeout: 10), "nothing waits under the chat (\(appearance))")
            XCTAssertEqual(waiting.count, 2, "not two sentences waiting (\(appearance))")
            for identifier in ["unsent", "resend", "unsure"] {
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists,
                              "no \(identifier) (\(appearance))")
            }
            let note = NSPredicate(format: "label CONTAINS %@", "重新连接中…")
            XCTAssertTrue(app.descendants(matching: .any).matching(note).firstMatch.exists,
                          "the sidebar does not say 重新连接中… (\(appearance))")
            Thread.sleep(forTimeInterval: 1)
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = "reconnect-chat-\(appearance)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
}
