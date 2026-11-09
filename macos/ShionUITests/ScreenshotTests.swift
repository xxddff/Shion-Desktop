import AppKit
import XCTest

/// Opens every page in light and dark and keeps a screenshot of the window for each. CI exports
/// the attachments as PNGs (see .github/workflows/macos.yml), so the UI can be reviewed from
/// pictures. The app pins its demo date in snapshot mode, so runs are comparable.
final class ScreenshotTests: XCTestCase {
    private let routes = ["today", "confirm", "todos", "calendar", "reports", "board", "desktop", "chat-shion"]

    @MainActor
    func testEveryPage() throws {
        continueAfterFailure = true
        if let screen = NSScreen.main {
            print("Screen: \(screen.frame.size) at \(screen.backingScaleFactor)x")
        }
        for appearance in ["light", "dark"] {
            for route in routes {
                capture(route: route, appearance: appearance)
            }
        }
    }

    @MainActor
    private func capture(route: String, appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", route,
            "-ShionAppearance", appearance,
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 20) else {
            XCTFail("No window for \(route) (\(appearance))")
            app.terminate()
            return
        }
        // let the first layout, fonts and materials settle
        Thread.sleep(forTimeInterval: 1.5)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "\(route)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
