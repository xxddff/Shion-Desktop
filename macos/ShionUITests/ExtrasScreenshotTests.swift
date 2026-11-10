import AppKit
import XCTest

/// Settings → 这台 Mac, after this Mac's own data: 开机启动 and 关窗后只留在菜单栏, light and dark,
/// and once more with a login item waiting for approval and the menu bar option on; then where a
/// notification's click lands and the Shortcuts actions. Then the menu bar with the Dock icon
/// away: the main window closed, the count of what waits on you next to the menu bar icon, 打开
/// Shion in the panel bringing the window and the icon back (whole screen, so the Dock shows).
/// Whether the Dock has the icon is asked of the system (Shion's activation policy), not read off
/// the Dock. Screenshot runs keep both settings in memory and leave the system's login items alone.
final class ExtrasScreenshotTests: XCTestCase {
    @MainActor
    func testStartSettings() throws {
        continueAfterFailure = true
        let runs: [(appearance: String, extra: [String], name: String)] = [
            ("light", [], "settings-start-light"),
            ("dark", [], "settings-start-dark"),
            ("light", ["-ShionLoginItemDemo", "requiresApproval", "-ShionMenuBarOnly", "YES"], "settings-start-approval-light"),
        ]
        for run in runs {
            let app = launch(appearance: run.appearance, extra: run.extra)
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
            guard settings.waitForExistence(timeout: 5) else {
                keep(XCUIScreen.main.screenshot(), "\(run.name)-screen")
                XCTFail("No Settings window")
                app.terminate()
                continue
            }
            selectTab("这台 Mac", in: settings)
            // 启动 just under the toolbar, 关窗后只留在菜单栏 after it
            if reveal(element("login-item", in: settings), in: settings, atTop: true) {
                if run.extra.contains("requiresApproval") {
                    XCTAssertTrue(element("login-items", in: settings).waitForExistence(timeout: 3),
                                  "no button to System Settings → 登录项 while approval is needed")
                }
                Thread.sleep(forTimeInterval: 0.5)
                keep(settings.screenshot(), run.name)
            } else {
                keep(settings.screenshot(), "\(run.name)-missing")
                XCTFail("no 开机启动 on the 这台 Mac tab (\(run.name))")
            }
            if run.name == "settings-start-light" {
                // the end of the tab: where clicks land, and the Shortcuts actions
                if reveal(element("landing-reply", in: settings), in: settings, atTop: true) {
                    Thread.sleep(forTimeInterval: 0.5)
                    keep(settings.screenshot(), "settings-ways-in-light")
                } else {
                    keep(settings.screenshot(), "settings-ways-in-light-missing")
                    XCTFail("no 点通知打开 on the 这台 Mac tab")
                }
            }
            // Settings opens on the tab it was left on, next launch too: back to 服务器
            selectTab("服务器", in: settings)
            XCTAssertTrue(settings.textFields["server-address"].waitForExistence(timeout: 5), "Settings not back on 服务器")
            app.terminate()
        }
    }

    @MainActor
    func testMenuBarOnly() throws {
        continueAfterFailure = true
        let app = launch(appearance: "light", extra: ["-ShionMenuBarOnly", "YES"])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "no main window")
        XCTAssertTrue(dockIcon(true), "no Dock icon with the window open")

        // closed: only the menu bar, with the count next to the icon
        app.typeKey("w", modifierFlags: .command)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: window)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 5), .completed, "the main window did not close")
        XCTAssertTrue(dockIcon(false), "the Dock icon stayed with the window closed")
        Thread.sleep(forTimeInterval: 1.5)
        keep(XCUIScreen.main.screenshot(), "menubar-only-light")

        // the panel's 打开 Shion: the window and the Dock icon come back
        let item = app.descendants(matching: .statusItem).firstMatch
        guard item.waitForExistence(timeout: 5) else {
            XCTFail("No status item")
            return app.terminate()
        }
        item.click()
        Thread.sleep(forTimeInterval: 1.5)
        keep(XCUIScreen.main.screenshot(), "menubar-only-panel-light")
        let open = app.descendants(matching: .any)["menubar-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "no 打开 Shion in the panel while the Dock icon is away")
        if open.exists {
            open.click()
            XCTAssertTrue(app.windows.matching(NSPredicate(format: "identifier CONTAINS 'AppWindow'")).firstMatch.waitForExistence(timeout: 10),
                          "打开 Shion did not bring the main window back")
            XCTAssertTrue(dockIcon(true), "the Dock icon did not come back with the window")
            Thread.sleep(forTimeInterval: 1.5)
            keep(XCUIScreen.main.screenshot(), "menubar-only-back-light")
        }
        app.terminate()
    }

    /// Waits up to five seconds for Shion to have (or not have) its Dock icon: the regular
    /// activation policy has one, the accessory one none. The run loop turns meanwhile, which is
    /// when the system's word on another app's policy comes in.
    @MainActor
    private func dockIcon(_ shown: Bool) -> Bool {
        let wanted: NSApplication.ActivationPolicy = shown ? .regular : .accessory
        let end = Date().addingTimeInterval(5)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if NSRunningApplication.runningApplications(withBundleIdentifier: "dev.shion.Shion").first?.activationPolicy == wanted {
                return true
            }
        } while Date() < end
        return false
    }

    /// Scrolls Settings until `element` is in full view under the toolbar and above the Dock; with
    /// `atTop`, until it is just under the toolbar, so what follows it shows too. As
    /// LocalScreenshotTests scrolls the same tab: which sign of a wheel delta moves the page which
    /// way is the runner's business, so a step that goes the wrong way flips it.
    @MainActor
    private func reveal(_ element: XCUIElement, in window: XCUIElement, atTop: Bool = false) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        let area = window.scrollViews.firstMatch.exists ? window.scrollViews.firstMatch : window
        let toolbar = window.toolbars.firstMatch
        var up: CGFloat = -1  // the sign of a delta that moves the page up
        var signKnown = false
        // the window can reach down behind the Dock (the runner's screen is small). Screen points,
        // top-left origin, as XCUI's.
        let dock: CGFloat = NSScreen.main.map { $0.frame.maxY - $0.visibleFrame.minY } ?? .greatestFiniteMagnitude
        for _ in 0..<40 {
            let top = (toolbar.exists ? toolbar.frame.maxY : window.frame.minY) + 6
            let bottom = min(window.frame.maxY, dock) - 6
            let frame = element.frame
            let inView = frame.minY >= top && frame.maxY <= bottom
            let target = atTop ? top + 48 : min(max(frame.minY, top), bottom - frame.height)
            let distance = frame.minY - target  // more than 0: the page has to move up
            if inView, abs(distance) <= (atTop ? 16 : 0.5) { return true }
            area.hover()
            area.scroll(byDeltaX: 0, deltaY: (distance > 0 ? up : -up) * max(16, min(240, abs(distance))))
            Thread.sleep(forTimeInterval: 0.25)
            let moved = element.frame.minY - frame.minY
            if abs(moved) < 1 {
                // nothing moved: the wrong way at an end of the page, or the end it has to go to
                if !signKnown {
                    up = -up
                    signKnown = true
                    continue
                }
                return inView
            }
            signKnown = true
            if (distance > 0) != (moved < 0) { up = -up }
        }
        return false
    }

    @MainActor
    private func element(_ identifier: String, in root: XCUIElement) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: identifier).firstMatch
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

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "today",
            "-ShionAppearance", appearance,
            "-ApplePersistenceIgnoreState", "YES",
        ] + extra
        app.launch()
        _ = app.windows.firstMatch.waitForExistence(timeout: 20)
        return app
    }

    private func keep(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
