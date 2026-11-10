import AppKit
import Carbon.HIToolbox
import XCTest

/// The ⌥Space window end to end, against ci/fake_hermes.py (its answers to the window are in
/// ci/fake_quick.py): a sentence typed before signing in waits, counted as written two hours
/// earlier, and goes out once connected with the time it was written; the
/// global shortcut over another app; 詩音's reply streaming into the window; an approval and a
/// question to answer in words, both handled in the window; the whole chat; and the window
/// starting afresh. Then the shortcut held by another app, as Settings → 快捷键 shows it. A
/// picture at each step (`quick-*.png`).
final class QuickAskTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"
    /// The stand-in streams its answer to these a few characters at a time (fake_quick.py).
    private let early = "小窗：到家了吗？"
    private let sentence = "小窗：明天几点出门？"
    /// …and asks on the way for this one: an approval, then 「交给哪位老师？」 with no choices.
    private let asking = "小窗：帮我把实验报告交了"

    @MainActor
    func testQuickAsk() throws {
        continueAfterFailure = false
        let app = launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        let field = app.textFields["quick-field"]

        // 0. before signing in: the sentence stays in the window, marked as waiting, with when it
        // was written (two hours ago, by -ShionQuickWrittenAgo)
        open(app, field)
        field.click()
        field.typeText(early)
        app.typeKey(.return, modifierFlags: [])
        let waiting = element("quick-waiting", in: app)
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "a sentence sent with no server did not show as waiting")
        XCTAssertTrue(waitForText("写的 · 等连上服务器后发出", in: app, timeout: 2), "the waiting sentence does not say when it was written and that it waits")
        Thread.sleep(forTimeInterval: 0.5)
        keep(XCUIScreen.main.screenshot(), "quick-0-waiting")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(XCTWaiter().wait(for: [gone(field)], timeout: 5), .completed, "Esc did not put the window away")

        // sign in as SignInTests does. Settings opens on 服务器 in test runs, though BotsTests,
        // which runs before this, leaves it on 助手
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings window")
        let onServer = settings.textFields["server-address"].waitForExistence(timeout: 3)
        continueAfterFailure = true
        XCTAssertTrue(onServer, "Settings did not open on 服务器")
        continueAfterFailure = false
        if !onServer {
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
            keep(XCUIScreen.main.screenshot(), "quick-0-not-connected")
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element("bot-shion", in: app).waitForExistence(timeout: 10), "no assistants from the server")

        // 1. connected, it went out by itself, after the time it was written (「（17:05 写的）…」): the
        // stand-in echoes what it got (「收到：（…」), and nothing waits any more
        open(app, field)
        let answer = element("quick-answer", in: app)
        let sentEarly = waitForText("收到：（", in: answer, timeout: 20)
        Thread.sleep(forTimeInterval: 0.5)
        keep(XCUIScreen.main.screenshot(), "quick-1-sent-on-connect")
        XCTAssertTrue(sentEarly, "the waiting sentence was not answered once connected")
        XCTAssertTrue(waitForText("写的）" + early, in: answer, timeout: 1), "the late sentence went out without the time it was written")
        XCTAssertFalse(waiting.exists, "the sentence still shows as waiting")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(XCTWaiter().wait(for: [gone(field)], timeout: 5), .completed, "Esc did not put the window away")

        // 2. the global shortcut with another app in front: the window comes up over it, and the
        // same shortcut puts it away again. Only the system's hot key can do this (the menu's copy
        // of the shortcut only works while Shion is the active app).
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        Thread.sleep(forTimeInterval: 1.5)
        finder.typeKey(" ", modifierFlags: .option)
        let global = field.waitForExistence(timeout: 6)
        keep(XCUIScreen.main.screenshot(), "quick-2-over-finder")
        print("over Finder: window \(global ? "up" : "not up")")
        // a failure here is kept and the rest still runs, so the window is checked even if the shortcut is not
        continueAfterFailure = true
        XCTAssertTrue(global, "⌥Space with Finder in front did not bring up the window")
        if global {
            // pressed where the keys now are, the window's field: typing at Finder could hand the
            // keyboard back to Finder first, and then the shortcut brings the window back instead
            field.typeKey(" ", modifierFlags: .option)
            XCTAssertEqual(XCTWaiter().wait(for: [gone(field)], timeout: 5), .completed, "pressing ⌥Space again did not put it away")
        } else {
            // Finder had the keys: ⌥Space is its full-screen Quick Look, should anything be selected
            finder.typeKey(.escape, modifierFlags: [])
        }
        continueAfterFailure = false

        // 3. from Shion: the sentence goes to 詩音 and her reply streams in under it
        app.activate()
        Thread.sleep(forTimeInterval: 1)
        open(app, field)
        field.click()
        field.typeText(sentence)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "the sentence did not show in the window")
        let reply = "收到：" + sentence
        // the cursor of a reply still arriving, before the whole of it is there
        let streaming = waitForText("▍", in: answer, timeout: 10)
        let whole = waitForText(reply, in: answer, timeout: 0)
        keep(XCUIScreen.main.screenshot(), "quick-3-streaming")
        XCTAssertTrue(streaming, "the reply did not stream into the window")
        XCTAssertFalse(whole, "the whole reply was there at once")
        let replied = waitForText(reply, in: answer, timeout: 15)
        Thread.sleep(forTimeInterval: 0.5)
        keep(XCUIScreen.main.screenshot(), "quick-4-replied")
        XCTAssertTrue(replied, "the reply did not finish in the window")
        XCTAssertFalse(waitForText("▍", in: answer, timeout: 0), "the reply still looks unfinished")

        // 4. 詩音 asks on the way, and both are answered in the window: the approval by its button,
        // the question with no choices by typing in the field
        field.click()
        field.typeText(asking)
        app.typeKey(.return, modifierFlags: [])
        let approval = element("quick-ask-ap-quick", in: app)
        XCTAssertTrue(approval.waitForExistence(timeout: 10), "the approval did not show in the window")
        Thread.sleep(forTimeInterval: 0.5)
        keep(XCUIScreen.main.screenshot(), "quick-5-approval")
        let allow = approval.buttons["允许这一次"]
        XCTAssertTrue(allow.exists, "no 允许这一次 on the approval")
        allow.click()
        let question = element("quick-ask-cl-quick", in: app)
        XCTAssertTrue(question.waitForExistence(timeout: 10), "the question did not show in the window")
        XCTAssertFalse(approval.exists, "the approval stayed after it was answered")
        continueAfterFailure = true
        XCTAssertEqual(field.placeholderValue, "回答詩音…", "the field does not say it answers the question")
        continueAfterFailure = false
        Thread.sleep(forTimeInterval: 0.5)
        keep(XCUIScreen.main.screenshot(), "quick-6-question")
        field.click()
        field.typeText("中村老师")
        app.typeKey(.return, modifierFlags: [])
        let handed = waitForText("交给中村老师了。", in: answer, timeout: 15)
        Thread.sleep(forTimeInterval: 0.5)
        keep(XCUIScreen.main.screenshot(), "quick-7-answered")
        XCTAssertTrue(handed, "the typed answer did not reach 詩音")
        XCTAssertFalse(question.exists, "the question stayed after it was answered")
        // what was chosen and typed stays in the window, a line each (AppStore+Trail.swift)
        continueAfterFailure = true
        XCTAssertTrue(waitForText("已允许这一次", in: answer, timeout: 5), "the approval left no line in the window")
        XCTAssertTrue(waitForText("你回答：中村老师", in: answer, timeout: 5), "the answer left no line in the window")
        continueAfterFailure = false

        // 5. the whole chat: the window goes, 詩音's chat opens in the main window with the exchange
        element("quick-open", in: app).click()
        XCTAssertEqual(XCTWaiter().wait(for: [gone(field)], timeout: 5), .completed, "the window stayed after opening the chat")
        let titled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "title CONTAINS %@", "詩音"), object: window)
        XCTAssertEqual(XCTWaiter().wait(for: [titled], timeout: 5), .completed, "詩音's chat did not open: \(window.title)")
        let inChat = waitForText("交给中村老师了。", in: element("transcript", in: app), timeout: 10)
        keep(window.screenshot(), "quick-8-full-chat")
        XCTAssertTrue(inChat, "the exchange is not in 詩音's chat")
        continueAfterFailure = true
        XCTAssertTrue(waitForText("你回答：中村老师", in: element("transcript", in: app), timeout: 5),
                      "the answer's line is not in 詩音's chat")
        continueAfterFailure = false

        // 6. an answered sentence went with the window: it comes back empty, and Esc puts it away
        open(app, field)
        XCTAssertFalse(element("quick-answer", in: app).waitForExistence(timeout: 1), "the window came back with the old answer")
        keep(XCUIScreen.main.screenshot(), "quick-9-again")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(XCTWaiter().wait(for: [gone(field)], timeout: 5), .completed, "Esc did not put the window away")
        app.terminate()
    }

    /// Another app holds the shortcut (this runner plays it, registering ⌥Space exclusively as
    /// GlobalHotKey.swift does): Settings → 快捷键 says so. Once let go, 再试一次 takes it, and
    /// the shortcut brings the window up.
    @MainActor
    func testShortcutTaken() throws {
        continueAfterFailure = false
        // the other test, stopped early, may have left Shion up and holding the key
        XCUIApplication().terminate()
        // the system's hot keys go through the window server, which an app is connected to
        _ = NSApplication.shared
        var held: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: 0x5445_5354, id: 1),
                                         GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &held)
        XCTAssertEqual(status, OSStatus(noErr), "the runner could not take ⌥Space: \(status)")
        defer {
            if let held {
                UnregisterEventHotKey(held)
            }
        }
        let app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings window")
        selectTab("快捷键", in: settings)
        let problem = element("quick-shortcut-problem", in: settings)
        let said = problem.waitForExistence(timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        keep(settings.screenshot(), "quick-taken")
        XCTAssertTrue(said, "Settings does not say the shortcut is taken")
        XCTAssertTrue(waitForText("被别的 App 占用了", in: settings, timeout: 1), "not the words for a taken shortcut")

        // the other app lets it go
        if let held {
            UnregisterEventHotKey(held)
        }
        held = nil
        element("quick-shortcut-retry", in: settings).click()
        XCTAssertEqual(XCTWaiter().wait(for: [gone(problem)], timeout: 5), .completed, "再试一次 did not take the shortcut")
        keep(settings.screenshot(), "quick-taken-retried")
        let field = app.textFields["quick-field"]
        app.typeKey(" ", modifierFlags: .option)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌥Space did not bring up the window once Shion had it")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(XCTWaiter().wait(for: [gone(field)], timeout: 5), .completed, "Esc did not put the window away")
        app.terminate()
    }

    /// Screenshot data, the global shortcut registered as in normal use, and a sentence that has
    /// to wait counted as written two hours before it was.
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionHotKey", "YES",
            "-ShionQuickWrittenAgo", "7200",
            "-ShionRoute", "today",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    /// The window by the shortcut, or by the 前往 menu when the shortcut does not reach it.
    @MainActor
    private func open(_ app: XCUIApplication, _ field: XCUIElement) {
        if !field.exists {
            app.typeKey(" ", modifierFlags: .option)
        }
        if field.waitForExistence(timeout: 4) {
            return
        }
        print("⌥Space did not bring the window up; using 前往 → 跟…说…")
        app.menuBars.menuBarItems["前往"].click()
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH '跟' AND title ENDSWITH '说…'")).firstMatch.click()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no ⌥Space window from the menu either")
    }

    @MainActor
    private func gone(_ element: XCUIElement) -> XCTNSPredicateExpectation {
        XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
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
    /// accessibility). `value` is only read on text elements: a toggle's is a number, which a
    /// CONTAINS predicate would throw on. A timeout of 0 looks once.
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
            if timeout > 0 {
                Thread.sleep(forTimeInterval: 0.3)
            }
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
