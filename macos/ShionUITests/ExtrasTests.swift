import AppKit
import XCTest

/// Shortcuts actions and notification clicks end to end, against ci/fake_hermes.py (the turns
/// they need are in ci/fake_extras.py).
/// - The actions run as Shortcuts runs them once it has their parameters: their perform(), asked
///   for with a distributed notification (`dev.shion.test.intent`, IntentHook.swift), what they
///   said read from a file. Before signing in nothing goes out and each says why; after, the
///   sentence reaches 詩音 and her reply comes back (no notification for it), a slow reply is
///   「已发出」 and then a notification, today's todos are the plugin's, and the two that open a
///   page open it.
/// - Notifications are written down in a file instead of posted (`-ShionNotificationLog`) and
///   clicked with a distributed notification, as WorkTests answers them: a long reply opens its
///   chat at its top, a question and an approval are selected in 等你确认, a daily report opens.
/// - Shion started by a click (`-ShionLaunchNotification`) takes it once its window is up (it
///   writes that down) and lands there once signed in: the reply by the row Hermes stored it as,
///   the question still waiting, an older report read for it, a card on the other board. One
///   test each, after test2, whose turns they come back to.
/// A picture at each step (`extras-*.png`).
final class ExtrasTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"
    private let notes = "/tmp/shion-extras-notifications.jsonl"
    private let results = "/tmp/shion-extras-intents.jsonl"
    /// The row Hermes stored the long reply as, from its notification (test2 → test3).
    private static var longReplyRow: String?
    private let longFirst = "（CI 长回复）第 1 段："
    private let longLast = "（CI 长回复）第 30 段："

    // MARK: 1. Shortcuts actions

    @MainActor
    func test1ShortcutsActions() throws {
        continueAfterFailure = true
        let app = launch()
        let window = app.windows.firstMatch

        // not signed in: nothing goes out, and each says why
        for (id, intent, extra) in [("t0", "tell", ["text": "捷径：没登录时不该发出去"]), ("d0", "todos", [:]),
                                    ("a0", "open-assistant", ["query": "通勤"])] {
            let result = run(intent, id: id, extra)
            XCTAssertEqual(result?["ok"] as? Bool, false, "\(intent) did something without a server: \(String(describing: result))")
            XCTAssertTrue((result?["error"] as? String)?.contains("还没登录") == true, "\(intent) did not say why: \(String(describing: result))")
        }
        // a page opens without one
        XCTAssertEqual(run("open-confirm", id: "c0")?["ok"] as? Bool, true, "打开等你确认 failed without a server")
        XCTAssertTrue(waitForTitle(window, "等你确认"), "打开等你确认 did not open it: \(window.title)")
        keep(XCUIScreen.main.screenshot(), "extras-0-not-signed-in")

        guard signIn(app, "extras-1") else { return }
        element("nav-today", in: app).click()

        // 跟总秘书说: the reply within the wait comes back, and is no notification
        let told = run("tell", id: "t1", ["text": "捷径：明天几点出门？"], timeout: 25)
        XCTAssertEqual(told?["ok"] as? Bool, true, "跟总秘书说 failed: \(String(describing: told))")
        XCTAssertEqual(told?["said"] as? String, "收到：捷径：明天几点出门？", "the reply did not come back")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(noteList().contains { $0.body.contains("收到：捷径：明天几点出门？") }, "the reply the action handed back was notified too")

        // a reply slower than the wait: 已发出, then its notification as usual
        let slow = run("tell", id: "t2", ["text": "捷径慢：后天呢？"], timeout: 25)
        XCTAssertEqual(slow?["said"] as? String, "已发出", "a slow reply was not 已发出: \(String(describing: slow))")
        XCTAssertTrue(waitUntil(timeout: 15) { self.noteList().contains { $0.body.contains("（CI）慢慢回：后天呢？") } },
                      "the slow reply was not notified once the action had stopped waiting")

        // 今天的待办: the plugin's
        let todos = run("todos", id: "d1")
        XCTAssertEqual(todos?["ok"] as? Bool, true, "今天的待办 failed: \(String(describing: todos))")
        XCTAssertTrue((todos?["said"] as? String)?.contains("CI：交实验报告") == true, "today's todos: \(String(describing: todos?["said"]))")
        XCTAssertTrue((todos?["value"] as? [String])?.contains("CI：交实验报告") == true, "the todos it returned: \(String(describing: todos?["value"]))")

        // 打开助手 finds 通勤 by name; 打开等你确认
        XCTAssertEqual(run("open-assistant", id: "a1", ["query": "通勤"])?["ok"] as? Bool, true, "打开助手 failed")
        XCTAssertTrue(waitForTitle(window, "通勤"), "打开助手 did not open 通勤: \(window.title)")
        keep(window.screenshot(), "extras-2-opened-assistant")
        XCTAssertEqual(run("open-confirm", id: "c1")?["ok"] as? Bool, true, "打开等你确认 failed")
        XCTAssertTrue(waitForTitle(window, "等你确认"), "打开等你确认 did not open it: \(window.title)")

        // 詩音's chat, from the server: the sentence said before signing in never reached it
        element("bot-shion", in: app).click()
        XCTAssertTrue(waitForText("收到：捷径：明天几点出门？", in: app, timeout: 10), "the action's sentence is not in 詩音's chat")
        XCTAssertFalse(waitForText("捷径：没登录时不该发出去", in: app, timeout: 1), "a sentence went out before signing in")
        keep(window.screenshot(), "extras-3-chief-chat")

        // the actions and their phrases made it into the app's App Intents metadata
        checkMetadata()
        app.terminate()
    }

    // MARK: 2. clicks

    @MainActor
    func test2NotificationClicks() throws {
        continueAfterFailure = true
        let app = launch()
        let window = app.windows.firstMatch
        guard signIn(app, "extras-4") else { return }

        // a long reply, asked for in 詩音's chat and come a few seconds later, after you went to 今天
        element("bot-shion", in: app).click()
        // her chat from the server, open and read, before anything is sent into it
        XCTAssertTrue(waitForText("CI 替身服务器连上了", in: app, timeout: 15), "詩音's chat did not open")
        let composer = element("composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer in 詩音's chat")
        composer.click()
        composer.typeText("通知：讲长一点")
        element("send", in: app).click()
        element("nav-today", in: app).click()
        XCTAssertTrue(waitUntil(timeout: 25) { self.note("reply-shion")?.body.hasPrefix(self.longFirst) == true },
                      "no notification for the long reply: \(noteList().map(\.id))")
        let reply = note("reply-shion")
        Self.longReplyRow = reply?.info["row"]
        XCTAssertNotNil(reply?.info["row"], "the reply's notification does not name the row Hermes stored it as: \(String(describing: reply?.info))")
        XCTAssertNotNil(reply?.info["item"], "the reply's notification does not name the chat's row")
        // clicked: the chat, at the reply's top rather than at its end
        click("reply-shion")
        XCTAssertTrue(waitForTitle(window, "詩音"), "the click did not open 詩音's chat: \(window.title)")
        checkAtTop(app, window, "extras-5-reply")

        // a question and an approval from 詩音 (through 跟总秘书说, from 今天): each click selects its own
        element("nav-today", in: app).click()
        _ = run("tell", id: "q1", ["text": "通知：问我"], timeout: 20)
        _ = run("tell", id: "q2", ["text": "通知：要批准"], timeout: 20)
        XCTAssertTrue(waitUntil(timeout: 10) { self.note("cl-ci-dinner") != nil && self.note("ap-ci-print") != nil },
                      "no notifications for the question and the approval: \(noteList().map(\.id))")
        click("cl-ci-dinner")
        XCTAssertTrue(waitForTitle(window, "等你确认"), "the click did not open 等你确认: \(window.title)")
        XCTAssertTrue(waitUntil(timeout: 10) { self.selected("ask-cl-ci-dinner", in: app) }, "the question is not selected")
        XCTAssertFalse(selected("ask-ap-ci-print", in: app), "the approval is selected too")
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "extras-6-question")
        click("ap-ci-print")
        XCTAssertTrue(waitUntil(timeout: 10) { self.selected("ask-ap-ci-print", in: app) }, "the approval is not selected")
        XCTAssertFalse(selected("ask-cl-ci-dinner", in: app), "the question is still selected")
        Thread.sleep(forTimeInterval: 0.5)
        keep(window.screenshot(), "extras-7-approval")

        // 课程 writes today's life report: its notification opens it
        element("nav-today", in: app).click()
        _ = run("tell", id: "r1", ["text": "通知：写日报"], timeout: 20)
        XCTAssertTrue(waitUntil(timeout: 15) { self.note("report-life") != nil }, "no notification for the new report: \(noteList().map(\.id))")
        XCTAssertTrue(note("report-life")?.title.contains("生活日报") == true, "the report's notification: \(String(describing: note("report-life")))")
        click("report-life")
        XCTAssertTrue(waitForTitle(window, "日报"), "the click did not open 日报: \(window.title)")
        XCTAssertTrue(waitForText("CI 今天的日报：早睡了一小时", in: app, timeout: 10), "the new report is not shown")
        keep(window.screenshot(), "extras-8-report")
        app.terminate()
    }

    // MARK: 3–6. a click that starts Shion

    /// The reply, found by the row Hermes stored it as: the chat is read afresh, with the server's ids.
    @MainActor
    func test3ColdReply() throws {
        continueAfterFailure = true
        guard let row = Self.longReplyRow ?? note("reply-shion")?.info["row"] else {
            return XCTFail("no row id for the long reply from test2")
        }
        let app = launch(clicked: ["bot": "shion", "row": row, "words": "（CI 长回复）第 1 段：这是一条很长的回复，点通知时要从这"])
        let window = app.windows.firstMatch
        if tookClick(app, window, "詩音", "extras-9"), signIn(app, "extras-9") {
            XCTAssertTrue(waitForTitle(window, "詩音"), "the click did not open 詩音's chat: \(window.title)")
            checkAtTop(app, window, "extras-10-cold-reply")
        }
        app.terminate()
    }

    /// The question, still waiting: selected once 詩音's chat is attached again.
    @MainActor
    func test4ColdQuestion() throws {
        continueAfterFailure = true
        let app = launch(clicked: ["bot": "shion", "ask": "cl-ci-dinner"])
        let window = app.windows.firstMatch
        if tookClick(app, window, "等你确认", "extras-11"), signIn(app, "extras-11") {
            XCTAssertTrue(waitForTitle(window, "等你确认"), "the click did not open 等你确认: \(window.title)")
            XCTAssertTrue(waitUntil(timeout: 20) { self.selected("ask-cl-ci-dinner", in: app) }, "the question is not selected")
            Thread.sleep(forTimeInterval: 0.5)
            keep(window.screenshot(), "extras-12-cold-question")
        }
        app.terminate()
    }

    /// Yesterday's report, no longer the newest of its kind: read for the click.
    @MainActor
    func test5ColdReport() throws {
        continueAfterFailure = true
        let yesterday = Self.tokyoDay(offset: -1)
        let app = launch(clicked: ["report": "\(yesterday)-life", "date": yesterday, "kind": "life"])
        let window = app.windows.firstMatch
        if tookClick(app, window, "日报", "extras-13"), signIn(app, "extras-13") {
            XCTAssertTrue(waitForTitle(window, "日报"), "the click did not open 日报: \(window.title)")
            XCTAssertTrue(waitForText("CI 日报：昨天睡得早", in: app, timeout: 15), "yesterday's report is not shown")
            XCTAssertFalse(waitForText("CI 今天的日报", in: app, timeout: 1), "today's report is shown instead")
            keep(window.screenshot(), "extras-14-cold-report")
        }
        app.terminate()
    }

    /// A card on the other board: the board switches once it is read, and the card opens.
    @MainActor
    func test6ColdCard() throws {
        continueAfterFailure = true
        let app = launch(clicked: ["card": "t_receipt", "board": "side", "bot": "study"])
        let window = app.windows.firstMatch
        if tookClick(app, window, "看板", "extras-15"), signIn(app, "extras-15") {
            XCTAssertTrue(waitForTitle(window, "看板"), "the click did not open 看板: \(window.title)")
            XCTAssertTrue(waitForText("原件在「副业」文件夹里（CI）。", in: app, timeout: 20), "the card's detail did not open")
            XCTAssertTrue(waitForText("看板 side", in: app, timeout: 5), "the detail is not the other board's card")
            Thread.sleep(forTimeInterval: 0.5)
            keep(window.screenshot(), "extras-16-cold-card")
        }
        app.terminate()
    }

    // MARK: steps

    @MainActor
    private func launch(clicked: [String: String]? = nil) -> XCUIApplication {
        try? FileManager.default.removeItem(atPath: results)
        try? FileManager.default.removeItem(atPath: notes)
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "today",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
            "-ShionNotificationLog", notes,
            "-ShionIntentResults", results,
            "-ShionIntentReplyWait", "4",
        ]
        if let clicked, let json = try? JSONSerialization.data(withJSONObject: clicked) {
            app.launchArguments += ["-ShionLaunchNotification", String(decoding: json, as: UTF8.self)]
        }
        // the stand-in's todos and reports are dated in Tokyo: the app's today is Tokyo's too, at
        // whatever hour the runner (on UTC) gets to this
        app.launchEnvironment["TZ"] = "Asia/Tokyo"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "no window")
        return app
    }

    /// Started as a click would start it: the app took the click once its window was up (it
    /// writes that down), and the page is the click's before anything is read from the server.
    @MainActor
    private func tookClick(_ app: XCUIApplication, _ window: XCUIElement, _ title: String, _ shot: String) -> Bool {
        var taken: [String: Any]?
        _ = waitUntil(timeout: 15) {
            taken = self.logLines().first { $0["launched"] != nil }
            return taken != nil
        }
        print("launch click: \(String(describing: taken))")
        guard let taken, taken["launched"] is [String: Any] else {
            keep(XCUIScreen.main.screenshot(), "\(shot)-no-click")
            XCTFail("the app did not take the click it was started with: \(String(describing: taken))")
            return false
        }
        XCTAssertTrue(waitForTitle(window, title), "the click did not open \(title) before signing in: \(window.title), route \(String(describing: taken["route"]))")
        return true
    }

    /// Signs in as the other tests do; Settings opens on the tab it was last left on.
    @MainActor
    private func signIn(_ app: XCUIApplication, _ shot: String) -> Bool {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        guard settings.waitForExistence(timeout: 5) else {
            keep(XCUIScreen.main.screenshot(), "\(shot)-no-settings")
            XCTFail("no Settings window")
            return false
        }
        serverTab(settings)
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        settings.buttons["sign-in"].click()
        let state = element("connection-state", in: settings)
        let online = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "已连接", "已连接")
        let connected = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: online, object: state)], timeout: 45)
        guard connected == .completed else {
            keep(XCUIScreen.main.screenshot(), "\(shot)-not-connected")
            XCTFail("not connected: \(state.label) / \(String(describing: state.value))")
            return false
        }
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element("bot-shion", in: app).waitForExistence(timeout: 10), "no assistants from the server")
        return true
    }

    /// The long reply's first paragraph is in view and its last is not: the chat opened at the
    /// reply's top, not at its newest line.
    @MainActor
    private func checkAtTop(_ app: XCUIApplication, _ window: XCUIElement, _ shot: String) {
        let transcript = element("transcript", in: app)
        guard transcript.waitForExistence(timeout: 10) else {
            keep(window.screenshot(), shot)
            return XCTFail("no transcript")
        }
        let landed = waitUntil(timeout: 20) {
            guard let first = self.text(self.longFirst, in: app) else { return false }
            return self.inView(first, transcript)
        }
        Thread.sleep(forTimeInterval: 0.8)
        keep(window.screenshot(), shot)
        let first = text(longFirst, in: app)
        let last = text(longLast, in: app)
        print("transcript \(transcript.frame); first \(String(describing: first?.frame)); last \(String(describing: last?.frame))")
        XCTAssertTrue(landed, "the reply's first paragraph is not in view")
        if let last {
            XCTAssertFalse(inView(last, transcript), "the chat is at the reply's end, not its top")
        }
    }

    // MARK: Shortcuts actions

    /// Runs an action as Shortcuts would (IntentHook.swift) and waits for what it said.
    @MainActor
    private func run(_ intent: String, id: String, _ extra: [String: String] = [:], timeout: TimeInterval = 15) -> [String: Any]? {
        var request: [String: String] = ["id": id, "intent": intent]
        request.merge(extra) { _, new in new }
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("dev.shion.test.intent"), object: String(decoding: json, as: UTF8.self), userInfo: nil,
            deliverImmediately: true)
        var found: [String: Any]?
        _ = waitUntil(timeout: timeout) {
            found = self.intentResults().first { $0["id"] as? String == id }
            return found != nil
        }
        print("action \(intent) \(id): \(String(describing: found))")
        if found == nil {
            XCTFail("no result for \(intent) (\(id))")
        }
        return found
    }

    private func intentResults() -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: results, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    /// The four actions and their phrases are in the app's App Intents metadata: built and
    /// accepted by Xcode's extractor, which is what Shortcuts, Spotlight and Siri read. (The
    /// provider's type name is not written there; its phrases are.)
    private func checkMetadata() {
        var folder = Bundle(for: Self.self).bundleURL
        var app: URL?
        for _ in 0..<6 {
            folder.deleteLastPathComponent()
            let candidate = folder.appendingPathComponent("Shion.app")
            if FileManager.default.fileExists(atPath: candidate.path) {
                app = candidate
                break
            }
        }
        guard let app else { return XCTFail("no Shion.app next to the test bundle") }
        let metadata = app.appendingPathComponent("Contents/Resources/Metadata.appintents")
        let files = (FileManager.default.enumerator(atPath: metadata.path)?.allObjects as? [String]) ?? []
        print("App Intents metadata: \(files)")
        let text = files.compactMap { try? String(contentsOf: metadata.appendingPathComponent($0), encoding: .utf8) }.joined()
        // the four actions, their titles, and phrases only the App Shortcuts have
        for name in ["TellChiefIntent", "TodayTodosIntent", "OpenAssistantIntent", "OpenConfirmIntent",
                     "跟总秘书说", "今天的待办", "打开助手", "打开等你确认", "转告总秘书", "今天还有什么要做", "有什么等我确认"] {
            XCTAssertTrue(text.contains(name), "\(name) is not in the App Intents metadata")
        }
    }

    // MARK: notifications

    private struct Note {
        let id: String
        let title: String
        let body: String
        let info: [String: String]
    }

    private func noteList() -> [Note] {
        guard let text = try? String(contentsOfFile: notes, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String
            else { return nil }
            return Note(id: id, title: row["title"] as? String ?? "", body: row["body"] as? String ?? "",
                        info: row["info"] as? [String: String] ?? [:])
        }
    }

    /// Every line of the log: the notifications, the answers and clicks taken, the launch click.
    private func logLines() -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: notes, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    /// The latest notification with that id.
    private func note(_ id: String) -> Note? {
        noteList().last { $0.id == id }
    }

    /// Clicks a notification, as the system tells the app of a click, and waits for the app to take it.
    private func click(_ id: String) {
        guard let json = try? JSONSerialization.data(withJSONObject: ["id": id, "action": "click"]) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("dev.shion.test.answer"), object: String(decoding: json, as: UTF8.self), userInfo: nil,
            deliverImmediately: true)
        let taken = waitUntil(timeout: 10) {
            guard let text = try? String(contentsOfFile: self.notes, encoding: .utf8) else { return false }
            return text.split(separator: "\n").contains { line in
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
                return row["answered"] as? String == id && row["action"] as? String == "click"
            }
        }
        XCTAssertTrue(taken, "the app did not take the click on \(id)")
    }

    // MARK: helpers

    @MainActor
    private func selected(_ identifier: String, in app: XCUIApplication) -> Bool {
        let card = element(identifier, in: app)
        return card.exists && (card.isSelected || (card.value as? String) == "已选中")
    }

    @MainActor
    private func inView(_ element: XCUIElement, _ container: XCUIElement) -> Bool {
        let frame = element.frame
        let visible = container.frame
        return element.exists && frame.minY >= visible.minY - 2 && frame.minY < visible.maxY - 20
    }

    /// A text element, plain or selectable.
    @MainActor
    private func text(_ words: String, in app: XCUIApplication) -> XCUIElement? {
        let either = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)
        let queries = [app.staticTexts.matching(either), app.textViews.matching(either),
                       app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words))]
        return queries.map(\.firstMatch).first { $0.exists }
    }

    static func tokyoDay(offset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let day = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    @MainActor
    private func serverTab(_ settings: XCUIElement) {
        guard !settings.textFields["server-address"].waitForExistence(timeout: 1) else { return }
        let tabs = [settings.toolbarButtons["服务器"], settings.toolbars.buttons["服务器"], settings.buttons["服务器"],
                    settings.radioButtons["服务器"]]
        if let tab = tabs.first(where: { $0.exists }) {
            tab.click()
        } else {
            settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "服务器")).firstMatch.click()
        }
        XCTAssertTrue(settings.textFields["server-address"].waitForExistence(timeout: 5), "no 服务器 tab in Settings")
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

    @MainActor
    private func waitForTitle(_ window: XCUIElement, _ title: String, timeout: TimeInterval = 10) -> Bool {
        let titled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "title CONTAINS %@", title), object: window)
        return XCTWaiter().wait(for: [titled], timeout: timeout) == .completed
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        } while Date() < deadline
        return false
    }

    /// Text anywhere in the app, plain or selectable; `value` only on text elements.
    @MainActor
    private func waitForText(_ text: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if self.text(text, in: app) != nil { return true }
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
