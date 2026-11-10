import AppKit
import XCTest

/// 日报's screen time on the demo's day (its usage by kind and the apps used most), light and dark.
/// The board's answers while a dropped connection is being got back (`-ShionReadOnlyDemo YES` on
/// the demo's data, the sidebar saying 重新连接中…): in 等你确认 the card's reply box, 回复 and
/// 让它继续 greyed out. (A card's own comment box is there only while the board is live: ExtrasTests
/// takes it greyed out with the stand-in's connection dropped.)
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
            if bringIntoView(element("login-item", in: settings), in: settings, atTop: true) {
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
                if bringIntoView(element("landing-reply", in: settings), in: settings, atTop: true) {
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
    func testScreenTime() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, route: "reports")
            let window = app.windows.firstMatch
            // its heading just under the toolbar, the kinds and the apps under it (the whole chart
            // is taller than the runner's window)
            if bringIntoView(element("usage-total", in: window), in: window, atTop: true) {
                let kinds = element("usage-categories", in: window)
                XCTAssertTrue((kinds.value as? String)?.contains("学习 2 小时 31 分") == true,
                              "the demo's kinds: \(String(describing: kinds.value))")
                Thread.sleep(forTimeInterval: 0.5)
                keep(window.screenshot(), "reports-usage-\(appearance)")
            } else {
                keep(window.screenshot(), "reports-usage-\(appearance)-missing")
                XCTFail("no screen time under the demo's 生活日报 (\(appearance))")
            }
            app.terminate()
        }
    }

    @MainActor
    func testReadOnlyCards() throws {
        continueAfterFailure = true
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, route: "confirm",
                             extra: ["-ShionDemoSignIn", "YES", "-ShionReconnectDemo", "YES", "-ShionReadOnlyDemo", "YES"])
            let window = app.windows.firstMatch
            // the demo's card that waits on your answer: 课程's, for a verification code
            if bringIntoView(element("card-ask-g5d2", in: window), in: window) {
                XCTAssertFalse(element("card-ask-reply-g5d2", in: window).isEnabled, "the reply box takes words while read-only")
                XCTAssertFalse(element("card-ask-resume-g5d2", in: window).isEnabled, "让它继续 is not greyed out")
                Thread.sleep(forTimeInterval: 0.5)
                keep(window.screenshot(), "readonly-confirm-\(appearance)")
            } else {
                keep(window.screenshot(), "readonly-confirm-\(appearance)-missing")
                XCTFail("no card waiting on you in 等你确认 (\(appearance))")
            }
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
    private func launch(appearance: String, route: String = "today", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", route,
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
