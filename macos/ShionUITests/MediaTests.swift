import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Pictures and files end to end, against ci/fake_hermes.py (its media routes and turns are in
/// ci/fake_media.py, shaped like Hermes's): sign in, open 通勤's new Bot Chat, paste a 4096×3072
/// photo that has a location and a camera in it and send it (the stand-in says what arrived);
/// paste three files, a small one, one past the 2 MB at which Shion stages it on the Webapp, and
/// one the stand-in refuses once, which a click sends again; 重试 the files' turn (a picture's has
/// none: Hermes cannot replay one); ask for a screenshot (the stand-in clears it once Shion has
/// read it); ask for files handed over with MEDIA:; save one; show the web picture, which waited
/// for the click; then disconnect, connect, and read the chat again from the server's transcript.
/// A picture at each step (`media-*.png`).
final class MediaTests: XCTestCase {
    private let server = "http://127.0.0.1:8765"
    /// The files the test pastes. The stand-in makes them (PASTED_FILES in ci/fake_media.py): this
    /// runner is sandboxed and cannot write outside its own container, which Shion would have to
    /// ask to read.
    private let folder = URL(fileURLWithPath: "/tmp/shion-media-ci", isDirectory: true)

    @MainActor
    func testPicturesAndFiles() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ShionSnapshot", "YES",
            "-ShionRoute", "today",
            "-ShionAppearance", "light",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        signIn(app)

        element("bot-commute", in: app).click()
        XCTAssertTrue(waitForText("新的 Bot Chat。", in: app, timeout: 15), "通勤's chat did not open")
        let composer = element("composer", in: app)
        let send = element("send", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))

        // 1. a photo with a location and a camera: it goes up 2048 wide, without either
        try putPhoto(width: 4096, height: 3072)
        composer.click()
        composer.typeKey("v", modifierFlags: .command)
        let chip = element("draft-picture", in: app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the pasted picture is not in the composer")
        let ready = waitUntil(timeout: 20) { send.isEnabled }
        keep(window.screenshot(), "media-1-picture-ready")
        XCTAssertTrue(ready, "the picture did not finish uploading: \(chip.label)")
        composer.click()
        composer.typeText("看看这张图（CI）")
        send.click()
        let described = waitForText("JPEG 2048×1536，没有位置信息，没有拍摄信息", in: app, timeout: 15)
        let shown = waitUntil(timeout: 10) { self.value(of: "sent-picture", in: app) == "已显示" }
        keep(window.screenshot(), "media-2-picture-sent")
        XCTAssertTrue(described, "the stand-in did not get a 2048-wide JPEG without its location and camera")
        XCTAssertTrue(shown, "the sent picture does not show in the bubble")
        XCTAssertFalse(chip.exists, "the composer still holds the picture")
        // Hermes keeps the picture in the stored row as an image part, which it will not replay
        XCTAssertFalse(element("retry", in: app).waitForExistence(timeout: 2), "the picture's turn offers 重试")

        // 2. three files: a small one goes to file.attach as bytes, a 3 MB one is staged on the
        // Webapp first, and the third fails once and goes on a click
        putFiles(["ci-报告（CI）.pdf", "ci-大文件（CI）.pdf", "ci-重试（CI）.txt"])
        composer.click()
        composer.typeKey("v", modifierFlags: .command)
        let files = app.descendants(matching: .any).matching(identifier: "draft-file")
        XCTAssertTrue(waitUntil(timeout: 10) { files.count == 3 }, "the pasted files are not in the composer: \(files.count)")
        let refused = files.matching(NSPredicate(format: "label CONTAINS %@", "重试")).firstMatch
        // a chip says where it is in its label
        let failed = waitUntil(timeout: 20) { refused.label.contains("没传上去") }
        keep(window.screenshot(), "media-3-file-refused")
        XCTAssertTrue(failed, "the file the stand-in refuses does not say so: \(refused.label)")
        clickWhereDrawn(refused)
        let allUp = waitUntil(timeout: 30) { send.isEnabled }
        keep(window.screenshot(), "media-4-files-ready")
        XCTAssertTrue(allUp, "the files did not all go up")
        send.click()
        let named = waitForText("收到文件：ci-报告（CI）.pdf（40000 字节）", in: app, timeout: 15)
        let staged = waitForText("（3145728 字节）", in: app, timeout: 5)
        let retried = waitForText("收到文件：ci-重试（CI）.txt（1200 字节）", in: app, timeout: 5)
        keep(window.screenshot(), "media-5-files-sent")
        XCTAssertTrue(named, "the small file did not arrive under its name")
        XCTAssertTrue(staged, "the big file did not arrive")
        XCTAssertTrue(retried, "the file sent again did not arrive")
        XCTAssertTrue(card("ci-报告（CI）.pdf", in: app).exists, "your message does not show the file")
        XCTAssertFalse(waitForText("@file:", in: app, timeout: 1), "a reference shows as text")

        // 2b. the files' turn answered: there is nothing to try again, so no 重试 under it
        XCTAssertFalse(element("retry", in: app).waitForExistence(timeout: 2), "a turn that answered offers 重试")
        let reports = app.descendants(matching: .any).matching(identifier: "file-card")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "ci-报告（CI）.pdf，"))
        XCTAssertEqual(reports.count, 1, "the file shows \(reports.count) times")

        // 3. a screenshot a tool took: under its call; the stand-in clears it once read
        composer.click()
        composer.typeText("截个图（CI）")
        send.click()
        XCTAssertTrue(waitForText("browser_navigate · ci.example/login（CI）", in: app, timeout: 10), "no tool call")
        let shot = waitUntil(timeout: 15) { self.value(of: "tool-shot", in: app) == "已显示" }
        keep(window.screenshot(), "media-7-screenshot")
        XCTAssertTrue(shot, "the screenshot does not show under the call")

        // 4. files handed over: MEDIA: tags, a path in the words, a web picture that waits
        composer.click()
        composer.typeText("把课件发给我（CI）")
        send.click()
        let slides = card("第8回课件（CI）.pdf", in: app)
        XCTAssertTrue(slides.waitForExistence(timeout: 15), "the PDF handed over is not a card")
        let chart = waitUntil(timeout: 15) { self.value(of: "reply-picture", in: app) == "已显示" }
        let written = card("ci-data.csv", in: app).waitForExistence(timeout: 10)
        let waits = element("show-web-picture", in: app).waitForExistence(timeout: 5)
            && value(of: "web-picture", in: app) == "点了才显示"
        keep(window.screenshot(), "media-8-handed-over")
        XCTAssertTrue(chart, "the picture handed over does not show")
        XCTAssertTrue(written, "the file named in the words is not a card")
        XCTAssertTrue(waits, "the web picture is not waiting for a click")
        XCTAssertFalse(waitForText("MEDIA:", in: app, timeout: 1), "a MEDIA: tag shows as text")
        // the reply is taller than the window at 1×: the card is above what shows at the bottom
        XCTAssertTrue(bringIntoView(slides, in: element("transcript", in: app)), "the PDF card cannot be scrolled to")
        clickWhereDrawn(slides)
        let saved = waitUntil(timeout: 15) { slides.label.contains("已存到「下载」") }
        keep(window.screenshot(), "media-9-saved")
        XCTAssertTrue(saved, "the PDF was not saved: \(slides.label)")

        // the web picture, now that it is asked for: W3C's logo, fetched from the web itself, so
        // a runner without the web leaves it 图片没取到, which is noted rather than failed
        let show = element("show-web-picture", in: app)
        XCTAssertTrue(bringIntoView(show, in: element("transcript", in: app)), "「显示图片」 cannot be scrolled to")
        clickWhereDrawn(show)
        let web = app.descendants(matching: .any).matching(identifier: "reply-picture")
            .matching(NSPredicate(format: "label == %@", "网上找的示例图")).firstMatch
        let fetched = waitUntil(timeout: 15) { web.exists && (web.value as? String) == "已显示" }
        keep(window.screenshot(), "media-10-web-picture")
        XCTAssertFalse(element("web-picture", in: app).exists, "the web picture still waits after the click")
        if !fetched {
            print("the web picture did not arrive: \(web.exists ? String(describing: web.value) : "gone")")
        }

        // 5. read again from the server: the transcript has the pictures' notes and the files'
        // references, not the screenshot, which only the Mac has now
        app.typeKey(",", modifierFlags: .command)
        let prefs = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(prefs.waitForExistence(timeout: 5), "no Settings window")
        serverTab(prefs)
        let link = element("connection-state", in: prefs)
        prefs.buttons["断开"].click()
        XCTAssertEqual(XCTWaiter().wait(for: [phase("未连接", link)], timeout: 10), .completed, "did not disconnect")
        prefs.buttons["连接"].click()
        XCTAssertEqual(XCTWaiter().wait(for: [phase("已连接", link)], timeout: 30), .completed, "did not connect again")
        app.typeKey("w", modifierFlags: .command)
        element("bot-commute", in: app).click()
        let reread = card("第8回课件（CI）.pdf", in: app).waitForExistence(timeout: 20)
        let transcript = element("transcript", in: app)
        // shown, then brought into view for its picture: a row can be there, and say so, off screen
        let shotRow = element("tool-shot", in: app)
        let shotAgain = scrollUp(until: { self.value(of: "tool-shot", in: app) == "已显示" }, in: transcript,
                                 probe: card("第8回课件（CI）.pdf", in: app))
        _ = bringIntoView(shotRow, in: transcript)
        keep(window.screenshot(), "media-11-reread-screenshot")
        let pictureAgain = scrollUp(until: { self.value(of: "sent-picture", in: app) == "已显示" }, in: transcript,
                                    probe: shotRow)
        _ = bringIntoView(element("sent-picture", in: app), in: transcript)
        keep(window.screenshot(), "media-12-reread-picture")
        XCTAssertTrue(reread, "the chat did not read again")
        XCTAssertTrue(shotAgain, "the screenshot the server cleared is gone after reading again")
        XCTAssertTrue(pictureAgain, "the picture you sent does not show after reading again")
        XCTAssertTrue(waitForText("看看这张图（CI）", in: app, timeout: 2), "the words sent with the picture are missing")
        XCTAssertFalse(waitForText("[Image attached at:", in: app, timeout: 1), "the picture's note shows as text")
        XCTAssertFalse(waitForText("@file:", in: app, timeout: 1), "a reference shows as text after reading again")
        app.terminate()
    }

    // MARK: what the test pastes

    /// A JPEG with a location (Tokyo Station), a camera and a time in it.
    @MainActor
    private func putPhoto(width: Int, height: Int) throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.8, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 35.6812, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 139.7671, kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "CI", kCGImagePropertyTIFFModel: "CI Camera"] as [CFString: Any],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:09 09:00:00"] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let board = NSPasteboard.general
        _ = board.clearContents()
        XCTAssertTrue(board.setData(data as Data, forType: NSPasteboard.PasteboardType("public.jpeg")))
    }

    /// Files as Finder copies them: their addresses.
    @MainActor
    private func putFiles(_ names: [String]) {
        let board = NSPasteboard.general
        _ = board.clearContents()
        XCTAssertTrue(board.writeObjects(names.map { folder.appendingPathComponent($0) as NSURL }))
    }

    // MARK: helpers

    @MainActor
    private func signIn(_ app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings window")
        serverTab(settings)
        type(server, into: settings.textFields["server-address"])
        type("ci-client", into: settings.textFields["access-id"])
        type("ci-secret", into: settings.secureTextFields["access-secret"])
        settings.buttons["sign-in"].click()
        let state = element("connection-state", in: settings)
        let connected = XCTWaiter().wait(for: [phase("已连接", state)], timeout: 45)
        if connected != .completed {
            keep(XCUIScreen.main.screenshot(), "media-0-not-connected")
        }
        XCTAssertEqual(connected, .completed, "Not connected: \(state.label) / \(String(describing: state.value))")
        app.typeKey("w", modifierFlags: .command)
    }

    /// Settings opens on the tab it was last left on (BotsTests leaves 助手): 服务器.
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

    /// Towards older rows until `condition` holds: which sign of a wheel delta scrolls up is the
    /// runner's business, so a nudge first, to see which way a row on screen moves.
    @MainActor
    private func scrollUp(until condition: () -> Bool, in transcript: XCUIElement, probe: XCUIElement) -> Bool {
        if waitUntil(timeout: 2, condition) { return true }
        var direction: CGFloat = 1
        if probe.exists {
            let before = probe.frame.minY
            transcript.hover()
            transcript.scroll(byDeltaX: 0, deltaY: 200)
            Thread.sleep(forTimeInterval: 0.5)
            direction = probe.exists && probe.frame.minY > before + 1 ? 1 : -1
        }
        for _ in 0..<16 {
            if waitUntil(timeout: 1, condition) { return true }
            transcript.hover()
            transcript.scroll(byDeltaX: 0, deltaY: direction * 300)
        }
        return waitUntil(timeout: 2, condition)
    }

    /// A file card, by its name: its label goes on with what its second line says.
    @MainActor
    private func card(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "file-card")
            .matching(NSPredicate(format: "label BEGINSWITH %@", name + "，")).firstMatch
    }

    /// Scrolls the transcript until `target` is drawn clear of its edges and of the composer that
    /// floats over its foot. A wheel step's sign is the runner's business: one that moves the
    /// content the wrong way is turned round.
    @MainActor
    private func bringIntoView(_ target: XCUIElement, in transcript: XCUIElement) -> Bool {
        let area = transcript.frame
        func clear() -> Bool {
            target.exists && target.frame.minY >= area.minY + 8 && target.frame.maxY <= area.maxY - 130
        }
        var delta: CGFloat = 150
        for _ in 0..<16 {
            if clear() { return true }
            guard target.exists else { return false }
            let before = target.frame.midY
            // above the band, the content has to come down; below it, go up
            let down = target.frame.minY < area.minY + 8
            transcript.hover()
            transcript.scroll(byDeltaX: 0, deltaY: delta)
            Thread.sleep(forTimeInterval: 0.4)
            let moved = target.exists ? target.frame.midY - before : 0
            if (down && moved < 0) || (!down && moved > 0) {
                delta = -delta
            }
        }
        return clear()
    }

    /// A click at the middle of where the element is drawn. XCUITest's own click hit-tests the
    /// element first, which a SwiftUI element that folds its children in
    /// (`.accessibilityElement(children: .ignore)`) inside a scroll view does not pass ("Unable to
    /// find hit point"), though the mouse reaches it as it reaches anything on screen.
    @MainActor
    private func clickWhereDrawn(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    @MainActor
    private func value(of identifier: String, in app: XCUIApplication) -> String? {
        let found = element(identifier, in: app)
        return found.exists ? found.value as? String : nil
    }

    private func phase(_ prefix: String, _ element: XCUIElement) -> XCTNSPredicateExpectation {
        XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix),
                                  object: element)
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
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    /// Text anywhere in the app, plain or selectable; `value` only on text elements.
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
