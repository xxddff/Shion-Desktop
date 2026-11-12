import AppKit
import XCTest

/// Stop, retry, a failed turn, find, the server check and the last data, end to end against
/// ci/fake_hermes.py (fake_control.py plays the parts Hermes has for them). Signs in as SignInTests
/// does, then: Settings' 服务器体检 against the stand-in (only 詩音's profile has the shion plugin); in
/// 詩音's chat a long reply stopped with ⌘. (session.interrupt for the turn's run) and kept as
/// 已停止; 重试 on it (a fenced rewind, then the same words again); a turn the stand-in fails as a
/// provider's rate limit does, explained in Chinese with Hermes's words under 详情, and retried; a
/// successful tool reply without 重试, preserved drafts, Shift Return, learning cards and an
/// isolated skill review; ⌘F over the loaded rows,
/// and back into older pages for a hit not loaded yet; then 断开, and the window keeps the server's
/// data, read-only. A picture at each step (chatctl-*.png).
final class ChatControlTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"

    @MainActor
    func testStopRetryFindAndLastData() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "today",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))

        // signed in through the stand-in's browser sheet, as SignInTests does
        app.typeKey(",", modifierFlags: .command)
        let settings = settingsWindow(app)
        guard settings.waitForExistence(timeout: 5) else {
            keep(XCUIScreen.main.screenshot(), "chatctl-0-no-settings")
            return XCTFail("No Settings window")
        }
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        settings.buttons["sign-in"].click()
        let state = element("connection-state", in: settings)
        guard XCTWaiter().wait(for: [phase("已连接 ·", of: state)], timeout: 60) == .completed else {
            keep(XCUIScreen.main.screenshot(), "chatctl-0-not-connected")
            return XCTFail("Not connected: \(state.label) / \(String(describing: state.value))")
        }

        // 服务器体检: every check against the stand-in
        tab("服务器体检", in: settings).click()
        let notifications = element("check-notifications", in: settings)
        let done = NSPredicate(format: "label != %@ AND value != %@", "检查中…", "检查中…")
        let checked = notifications.waitForExistence(timeout: 10)
            && XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: notifications)], timeout: 30) == .completed
        keep(settings.screenshot(), "chatctl-1-check")
        XCTAssertTrue(checked, "the server check did not finish")
        expect("check-access", in: settings, "service token 放行了")
        expect("check-login", in: settings, startsWith: "有效 · ci-user · ")
        expect("check-protocol", in: settings, "hermes gateway")
        expect("check-capabilities", in: settings, "Shion 用到的都有")
        // the stand-in has the plugin in 詩音's profile and the default one only (fake_profiles.py)
        expect("check-plugin", in: settings, endsWith: "个助手没有")
        expect("check-plugin-commute", in: settings, "没装或没启用")
        expect("check-plugin-shion", in: settings, startsWith: "ci · 今天是 ")
        expect("check-timezone", in: settings, "服务器缺时区数据")
        expect("check-kanban", in: settings, "在 · 2 块看板")
        expect("check-limits", in: settings, "整台服务器 4 件（按内存推算） · 每个助手 1 件")
        tab("服务器", in: settings).click()
        app.typeKey("w", modifierFlags: .command)

        // a long reply, stopped with ⌘. part way: what had come stays, marked 已停止
        let chief = element("bot-shion", in: app)
        XCTAssertTrue(chief.waitForExistence(timeout: 10), "no assistants from the server")
        chief.click()
        XCTAssertTrue(waitForText("CI 替身服务器连上了", in: app, timeout: 15), "詩音's chat did not open")
        let composer = element("composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        // Switching Shion pages preserves the draft. Shift Return inserts at the caret.
        composer.click()
        composer.typeText("draft-151")
        element("nav-todos", in: app).click()
        chief.click()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "draft-151")
        composer.click()
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeKey(.return, modifierFlags: .shift)
        composer.typeText("second-line")
        XCTAssertEqual(composer.value as? String, "draft-151\nsecond-line")
        XCTAssertFalse(element("stop", in: app).exists, "Shift Return sent the draft")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        composer.typeText("讲一个长故事")
        element("send", in: app).click()
        let stop = element("stop", in: app)
        let running = stop.waitForExistence(timeout: 10) && waitForText("山里有座庙", in: app, timeout: 10)
        keep(app.windows.firstMatch.screenshot(), "chatctl-2-running")
        XCTAssertTrue(running, "no stop button while the reply streamed")
        app.typeKey(".", modifierFlags: .command)
        let stopped = element("stopped", in: app)
        if !stopped.waitForExistence(timeout: 8) {
            XCTFail("⌘. did not stop the reply")
            if stop.exists { stop.click() }
        }
        let marked = stopped.waitForExistence(timeout: 8)
        keep(app.windows.firstMatch.screenshot(), "chatctl-3-stopped")
        guard marked else { return XCTFail("the stopped reply is not marked 已停止") }
        XCTAssertTrue(element("send", in: app).waitForExistence(timeout: 5), "the send button did not come back")

        // 重试: the turn is rewound on the server and the same words go again
        let retry = element("retry", in: app)
        guard retry.waitForExistence(timeout: 5) else {
            return XCTFail("no 重试 under the last reply")
        }
        retry.click()
        let retried = waitForText("（重试）故事讲完了", in: app, timeout: 20)
        keep(app.windows.firstMatch.screenshot(), "chatctl-4-retried")
        XCTAssertTrue(retried, "the retried turn did not reply")
        XCTAssertFalse(element("stopped", in: app).exists, "the stopped reply is still there after 重试")
        // selectable text is a text view to accessibility, its words in the value
        let prompts = max(app.staticTexts.matching(NSPredicate(format: "label == %@", "讲一个长故事")).count,
                          app.textViews.matching(NSPredicate(format: "value == %@", "讲一个长故事")).count)
        XCTAssertLessThanOrEqual(prompts, 1, "the prompt shows \(prompts) times after 重试")

        // a turn Hermes ends with an error (a provider's rate limit): the line says what went wrong
        // and what to do in Shion's words, Hermes's own under 详情, its notice not in English; 重试
        // is under it, as Hermes says trying again may help, and asks nothing: no tool was called
        composer.click()
        composer.typeText("出个错看看")
        element("send", in: app).click()
        let failure = element("turn-failed", in: app)
        let explained = failure.waitForExistence(timeout: 15)
            && waitForText("这一轮出错了：OpenRouter 那边请求太多了", in: app, timeout: 5)
        XCTAssertTrue(explained, "the failed turn does not say why")
        XCTAssertTrue(waitForText("等一会儿再试。", in: app, timeout: 2), "no advice under the error")
        XCTAssertFalse(waitForText("没有说明", in: app, timeout: 1), "the failed turn says 没有说明")
        let details = element("failure-details", in: app)
        if details.waitForExistence(timeout: 3) {
            details.click()
            XCTAssertTrue(waitForText("rate-limited every one of 3 attempts", in: app, timeout: 3), "详情 does not show Hermes's words")
        } else {
            XCTFail("no 详情 under the error")
        }
        XCTAssertFalse(waitForText("Your request was not processed", in: app, timeout: 1), "Hermes's notice shows in English")
        keep(app.windows.firstMatch.screenshot(), "chatctl-4b-failed")
        let again = element("retry", in: app)
        if again.waitForExistence(timeout: 5) {
            again.click()
            XCTAssertNil(question(in: app, timeout: 1), "重试 asked first although the turn called no tool")
            XCTAssertTrue(waitForText("（重试）这次没出错。", in: app, timeout: 15), "重试 on the failed turn did not reply")
            XCTAssertFalse(element("turn-failed", in: app).exists, "the error is still there after 重试")
            let asked = max(app.staticTexts.matching(NSPredicate(format: "label == %@", "出个错看看")).count,
                            app.textViews.matching(NSPredicate(format: "value == %@", "出个错看看")).count)
            XCTAssertLessThanOrEqual(asked, 1, "the failed prompt shows \(asked) times after 重试")
        } else {
            XCTFail("no 重试 under a failure Hermes says can be retried")
        }

        // Successful replies offer copy/reply, and never replay completed tool calls.
        composer.click()
        composer.typeText("查一下明天的天气")
        element("send", in: app).click()
        XCTAssertTrue(waitForText("明天晴，最高 18 度", in: app, timeout: 15))
        XCTAssertFalse(element("retry", in: app).exists, "a successful reply still offers retry")

        // A successful silent marker has no bubble, while learning events are cards.
        composer.click()
        composer.typeText("RUN151-learning")
        element("send", in: app).click()
        XCTAssertTrue(waitForText("已生效 · 待审核", in: app, timeout: 15))
        XCTAssertTrue(waitForText("用户记忆已更新（CI）", in: app, timeout: 10))
        XCTAssertTrue(waitForText("已整理技能与记忆（CI）", in: app, timeout: 10))
        XCTAssertFalse(app.staticTexts["[SILENT]"].exists)
        XCTAssertFalse(app.textViews.matching(NSPredicate(format: "value == %@", "[SILENT]")).firstMatch.exists)
        element("review-open-ci-review", in: app).click()
        XCTAssertTrue(waitForText("审核结论：技能描述清楚（CI）", in: app, timeout: 15))
        keep(app.windows.firstMatch.screenshot(), "chatctl-review-session")
        element("review-close", in: app).click()
        // Same skill, another card: Hermes's title-first create must not reuse the first chat.
        composer.click()
        composer.typeText("RUN151-learning-again")
        element("send", in: app).click()
        let nextReview = element("review-open-ci-review-next", in: app)
        XCTAssertTrue(nextReview.waitForExistence(timeout: 15))
        nextReview.click()
        XCTAssertTrue(waitForText("审核结论：第二次技能变更（CI）", in: app, timeout: 15))
        XCTAssertFalse(waitForText("审核结论：技能描述清楚（CI）", in: app, timeout: 1),
                       "different review cards share a model conversation")
        guard let secondSheet = question(in: app, timeout: 5) else { return XCTFail("no second review sheet") }
        element("review-approve-ci-review-next", in: secondSheet).click()
        XCTAssertTrue(waitForText("已批准 · 已记录决定", in: app, timeout: 10))
        keep(app.windows.firstMatch.screenshot(), "chatctl-review-second-version")
        element("review-close", in: app).click()
        let firstReview = element("review-open-ci-review", in: app)
        for _ in 0..<8 {
            if firstReview.exists && firstReview.isHittable { break }
            element("transcript", in: app).scroll(byDeltaX: 0, deltaY: 220)
            Thread.sleep(forTimeInterval: 0.2)
        }
        firstReview.click()
        XCTAssertTrue(waitForText("审核结论：技能描述清楚（CI）", in: app, timeout: 10), "the review conversation did not resume")
        XCTAssertFalse(waitForText("审核结论：第二次技能变更（CI）", in: app, timeout: 1),
                       "reopening the first card shows the later review's discussion")
        guard let firstSheet = question(in: app, timeout: 5) else { return XCTFail("no first review sheet") }
        element("review-approve-ci-review", in: firstSheet).click()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("review-approve-ci-review", in: firstSheet).exists },
                      "the older review cannot be closed after approving the newer one")
        element("review-close", in: app).click()

        // Outgoing assistant-message cards are tools within this turn. Both a failure and a
        // stopped reply remain retryable, and warn about message_agent, live and after reloading.
        for (prompt, stopTurn) in [("助手消息后出错（CI）", false), ("助手消息后停止（CI）", true)] {
            composer.click()
            composer.typeText(prompt)
            element("send", in: app).click()
            XCTAssertTrue(waitForText("发给 little：", in: app, timeout: 10), "no outgoing peer card")
            if stopTurn {
                XCTAssertTrue(element("stop", in: app).waitForExistence(timeout: 10))
                app.typeKey(".", modifierFlags: .command)
                XCTAssertTrue(element("stopped", in: app).waitForExistence(timeout: 10))
            } else {
                XCTAssertTrue(element("turn-failed", in: app).waitForExistence(timeout: 10))
            }
            for reloaded in [false, true] {
                if reloaded {
                    // Navigation keeps loadedChats cached. Disconnect and connect to rebuild
                    // the transcript from server history, including the tool card's provenance.
                    app.typeKey(",", modifierFlags: .command)
                    let prefs = settingsWindow(app)
                    XCTAssertTrue(prefs.waitForExistence(timeout: 5))
                    tab("服务器", in: prefs).click()
                    prefs.buttons["断开"].click()
                    let state = element("connection-state", in: prefs)
                    XCTAssertEqual(XCTWaiter().wait(for: [phase("未连接，现在是上次的数据", of: state)], timeout: 10), .completed)
                    prefs.buttons["连接"].click()
                    XCTAssertEqual(XCTWaiter().wait(for: [phase("已连接 ·", of: state)], timeout: 40), .completed)
                    app.typeKey("w", modifierFlags: .command)
                    chief.click()
                }
                let retryPeer = element("retry", in: app)
                XCTAssertTrue(retryPeer.waitForExistence(timeout: 10), "peer tool hid retry (reloaded: \(reloaded))")
                retryPeer.click()
                guard let ask = question(in: app, timeout: 5) else { return XCTFail("retry did not warn about the sent message") }
                XCTAssertTrue(waitForText("message_agent", in: app, timeout: 3), "the side-effect warning lost the peer tool")
                button(reloaded ? "retry-confirm" : "retry-cancel", reloaded ? "重试" : "取消", in: ask).click()
            }
            let reply = stopTurn ? "（重试）故事讲完了" : "（重试）这次没出错。"
            XCTAssertTrue(waitForText(reply, in: app, timeout: 20), "retry did not use the original user prompt")
        }
        keep(app.windows.firstMatch.screenshot(), "chatctl-peer-retry")

        // ⌘F over the rows loaded: 第 120 to 129 条 are on the newest page
        app.typeKey("f", modifierFlags: .command)
        let field = element("find-field", in: app)
        if !field.waitForExistence(timeout: 5) {
            keep(app.windows.firstMatch.screenshot(), "chatctl-5-no-find")
            XCTFail("⌘F did not open the find bar")
            element("find", in: app).click()
        }
        guard field.waitForExistence(timeout: 5) else {
            return XCTFail("the toolbar's find button did not open the find bar either")
        }
        field.click()
        field.typeText("第 12")
        let count = element("find-count", in: app)
        let counted = count.waitForExistence(timeout: 5)
        keep(app.windows.firstMatch.screenshot(), "chatctl-5-find")
        XCTAssertTrue(counted, "no count in the find bar")
        let first = position(count)
        XCTAssertNotNil(first, "count reads \(count.label) / \(String(describing: count.value))")
        if let first {
            XCTAssertEqual(first.0, first.1, "the newest hit is not the first one in view")
            field.typeText("\r")
            XCTAssertTrue(waitUntil(timeout: 3) { self.position(count)?.0 == first.0 - 1 }, "Return did not go to the older hit")
        }
        // 第 3 条 is pages back: ↑ reads older pages until it turns up. Each comes 1.5 s after it
        // is asked for (the stand-in's network): the second (no hit) lands with what shows staying
        // where it was, and with the third the chat goes to the hit, which is then in view, not
        // only laid out
        field.typeKey("a", modifierFlags: .command)
        field.typeText("第 3 条")
        let transcript = element("transcript", in: app)
        var places: [String] = []
        let before = topRow(of: transcript)
        mark("find-older")
        element("find-older", in: app).click()
        Thread.sleep(forTimeInterval: 2.3)
        let reading = before.flatMap { row in rows(of: transcript)[row.label] }
        places.append("finding: \(before?.label ?? "no row") at the top at \(before.map { "\($0.y)" } ?? "-") before 上一个, "
                      + "\(reading.map { "\($0)" } ?? "gone") with the second page in")
        if let before {
            XCTAssertEqual(reading ?? .nan, before.y, accuracy: 4, "what shows moved as finding read the second page. \(places.last ?? "")")
        }
        let dug = waitForText("第 3 条（你）", in: app, timeout: 30)
        Thread.sleep(forTimeInterval: 0.5)
        keep(app.windows.firstMatch.screenshot(), "chatctl-6-find-older")
        mark("found")
        XCTAssertTrue(dug, "older pages were not read for the hit")
        let found = rows(of: transcript)["第 3 条（你）"]
        let area = transcript.frame
        places.append("the hit: 第 3 条 at \(found.map { "\($0)" } ?? "not laid out") in \(area)")
        XCTAssertTrue(found.map { $0 >= area.minY - 2 && $0 <= area.maxY - 10 } ?? false,
                      "the chat did not go to the hit. \(places.last ?? "")")
        note(places.joined(separator: "\n"), "chatctl-positions")
        app.typeKey(.escape, modifierFlags: [])

        // 断开: the window keeps the server's data, read-only, and says from when
        app.typeKey(",", modifierFlags: .command)
        let prefs = settingsWindow(app)
        XCTAssertTrue(prefs.waitForExistence(timeout: 5))
        tab("服务器", in: prefs).click()
        mark("disconnect")
        prefs.buttons["断开"].click()
        let offline = element("connection-state", in: prefs)
        XCTAssertEqual(XCTWaiter().wait(for: [phase("未连接，现在是上次的数据", of: offline)], timeout: 10), .completed,
                       "after 断开: \(offline.label) / \(String(describing: offline.value))")
        keep(prefs.screenshot(), "chatctl-7-settings-offline")
        mark("disconnected")
        app.typeKey("w", modifierFlags: .command)
        // opened again, the chat starts at its newest row
        element("nav-today", in: app).click()
        mark("reopen")
        element("bot-shion", in: app).click()
        mark("reopened")
        let kept = waitForText("明天晴，最高 18 度", in: app, timeout: 5)
        let note = waitForText("上次的数据 · ", in: app, timeout: 5)
        keep(app.windows.firstMatch.screenshot(), "chatctl-8-offline-chat")
        mark("reopened-shot")
        XCTAssertTrue(kept, "the chat went back to the demo after 断开")
        XCTAssertTrue(note, "the sidebar does not say the data is the last the server gave")
        // what is said now waits for a connection (ReconnectTests); a todo stays read-only
        XCTAssertTrue(element("composer", in: app).isEnabled, "the composer takes nothing to send later while not connected")
        composer.click()
        composer.typeText("offline-draft")
        XCTAssertEqual(composer.value as? String, "offline-draft", "the offline composer is not editable")
        element("nav-todos", in: app).click()
        let todos = waitForText("CI：交实验报告", in: app, timeout: 5)
        keep(app.windows.firstMatch.screenshot(), "chatctl-9-offline-todos")
        mark("todos")
        XCTAssertTrue(todos, "the plugin's todos are not kept")
        XCTAssertFalse(element("todo-toggle-td_ci_report", in: app).isEnabled, "a todo can be ticked while not connected")
        app.terminate()
    }

    // MARK: helpers

    /// A mark in the stand-in's log (fake_hermes-ChatControlTests.log, kept even when the run is
    /// cut short): where the test got to, if the app stops answering (run 146).
    private func mark(_ step: String) {
        StandIn.mark("chatctl-\(step)")
    }

    @MainActor
    private func settingsWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
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

    /// A Settings tab by its name (a toolbar button, a button or a radio button, as BotsTests finds it).
    @MainActor
    private func tab(_ name: String, in settings: XCUIElement) -> XCUIElement {
        let tabs = [settings.toolbarButtons[name], settings.toolbars.buttons[name], settings.buttons[name],
                    settings.radioButtons[name]]
        return tabs.first(where: { $0.exists })
            ?? settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    private func phase(_ prefix: String, of element: XCUIElement) -> XCTNSPredicateExpectation {
        XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix), object: element)
    }

    @MainActor
    private func says(_ element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    @MainActor
    private func expect(_ identifier: String, in root: XCUIElement, _ text: String) {
        let found = element(identifier, in: root)
        XCTAssertTrue(found.waitForExistence(timeout: 3), "no \(identifier)")
        XCTAssertEqual(says(found), text, identifier)
    }

    @MainActor
    private func expect(_ identifier: String, in root: XCUIElement, startsWith text: String) {
        let found = element(identifier, in: root)
        XCTAssertTrue(found.waitForExistence(timeout: 3), "no \(identifier)")
        XCTAssertTrue(says(found).hasPrefix(text), "\(identifier): \(says(found))")
    }

    @MainActor
    private func expect(_ identifier: String, in root: XCUIElement, endsWith text: String) {
        let found = element(identifier, in: root)
        XCTAssertTrue(found.waitForExistence(timeout: 3), "no \(identifier)")
        XCTAssertTrue(says(found).hasSuffix(text), "\(identifier): \(says(found))")
    }

    /// The question over the window (an alert sheet), if one comes up within `timeout`. Its buttons
    /// are looked up in it, not among the window's: the chat's own 重试 has the same name, and so do
    /// the Touch Bar's buttons.
    @MainActor
    private func question(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let places = [app.windows.sheets.firstMatch, app.sheets.firstMatch, app.windows.dialogs.firstMatch,
                      app.dialogs.firstMatch]
        var found: XCUIElement?
        _ = waitUntil(timeout: timeout) {
            found = places.first { $0.exists }
            return found != nil
        }
        return found
    }

    /// What the question is to XCUI, for chatctl-question.txt: where it was found, what kind of
    /// element, and whether its buttons kept the identifiers the app gave them.
    @MainActor
    private func describe(_ ask: XCUIElement, in app: XCUIApplication) -> String {
        let places = [("a sheet of the window", app.windows.sheets.firstMatch), ("a sheet", app.sheets.firstMatch),
                      ("a dialog in the window", app.windows.dialogs.firstMatch), ("a dialog", app.dialogs.firstMatch)]
        let found = places.filter { $0.1.exists }.map { $0.0 }
        let kind: String
        switch ask.elementType {
        case .sheet: kind = "sheet"
        case .dialog: kind = "dialog"
        case .alert: kind = "alert"
        case .window: kind = "window"
        default: kind = "type \(ask.elementType.rawValue)"
        }
        let buttons = ask.buttons.allElementsBoundByIndex.map { button in
            "「\(button.label)」 identifier \(button.identifier.isEmpty ? "(none)" : button.identifier)"
        }
        return """
            found as: \(found.joined(separator: ", "))
            element: \(kind)
            buttons: \(buttons.joined(separator: "; "))
            retry-confirm kept: \(ask.buttons["retry-confirm"].exists), retry-cancel kept: \(ask.buttons["retry-cancel"].exists)
            """
    }

    /// Text worth reading after the run, beside the pictures (`name.txt`).
    /// Where each 第 N 条 row the transcript has laid out starts on the screen, by its text, from
    /// one snapshot of it (quick enough to read between two pages landing).
    @MainActor
    private func rows(of transcript: XCUIElement) -> [String: CGFloat] {
        guard let root = try? transcript.snapshot() else { return [:] }
        var rows: [String: CGFloat] = [:]
        func visit(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText || node.elementType == .textView,
               let text = [node.label, node.value as? String ?? ""].first(where: { $0.hasPrefix("第 ") && $0.contains(" 条（") }),
               rows[text] == nil {
                rows[text] = node.frame.minY
            }
            node.children.forEach(visit)
        }
        visit(root)
        return rows
    }

    /// The topmost 第 N 条 row wholly in what shows of the transcript, and where it starts.
    @MainActor
    private func topRow(of transcript: XCUIElement) -> (label: String, y: CGFloat)? {
        let area = transcript.frame
        return rows(of: transcript)
            .filter { $0.value >= area.minY - 1 && $0.value <= area.maxY - 20 }
            .min { $0.value < $1.value }
            .map { (label: $0.key, y: $0.value) }
    }

    private func note(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A button in `container`, by its identifier if the alert kept it, else by its name.
    @MainActor
    private func button(_ identifier: String, _ name: String, in container: XCUIElement) -> XCUIElement {
        let byIdentifier = container.buttons[identifier]
        return byIdentifier.exists ? byIdentifier : container.buttons[name]
    }

    /// The find bar's "3/10" as (3, 10).
    @MainActor
    private func position(_ count: XCUIElement) -> (Int, Int)? {
        let parts = says(count).split(separator: "/").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return false
    }

    /// Text anywhere in the app, plain or selectable (see SignInTests).
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
