import AppKit
import XCTest

/// Settings → 通用 (开机启动, 关窗后只留在菜单栏, where a notification's click lands, the Shortcuts
/// actions), light and dark, and once more with a login item waiting for approval and the menu
/// bar option on; then the menu bar with the Dock icon away: the main window closed, the count of
/// what waits on you next to the menu bar icon, 打开 Shion in the panel bringing the window and
/// the icon back (whole screen, so the Dock shows). Whether the Dock has the icon is asked of the
/// system (Shion's activation policy), not read off the Dock. Screenshot runs keep both settings
/// in memory and leave the system's login items alone.
final class ExtrasScreenshotTests: XCTestCase {
    @MainActor
    func testGeneralSettings() throws {
        continueAfterFailure = true
        let runs: [(appearance: String, extra: [String], name: String)] = [
            ("light", [], "settings-general-light"),
            ("dark", [], "settings-general-dark"),
            ("light", ["-ShionLoginItemDemo", "requiresApproval", "-ShionMenuBarOnly", "YES"], "settings-general-approval-light"),
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
            selectTab("通用", in: settings)
            let toggle = settings.descendants(matching: .any)["login-item"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no 开机启动 on the 通用 tab")
            if run.extra.contains("requiresApproval") {
                XCTAssertTrue(settings.descendants(matching: .any)["login-items"].waitForExistence(timeout: 3),
                              "no button to System Settings → 登录项 while approval is needed")
            }
            Thread.sleep(forTimeInterval: 0.8)
            keep(settings.screenshot(), run.name)
            if run.name == "settings-general-light" {
                // the rest of the tab: where clicks land, and the Shortcuts actions
                let form = settings.scrollViews.firstMatch
                form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()
                form.scroll(byDeltaX: 0, deltaY: -1200)
                Thread.sleep(forTimeInterval: 0.8)
                keep(settings.screenshot(), "settings-general-2-light")
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
