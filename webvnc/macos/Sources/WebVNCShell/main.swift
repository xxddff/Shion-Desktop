import AppKit
import WebKit

// webvnc-shell: the web viewer (web/) in a WKWebView, with the loopback relay (option A) and the
// in-app channel (option C), checked against webvnc/linux/replay_messages.py (noVNC sessions
// recorded on the Linux testbed; no Xvnc on macOS). Writes results.json and the decoded pictures
// to --out.
//
//   webvnc-shell --web-root webvnc/web --python python3 --replay webvnc/linux/replay_messages.py \
//     --static-sample webvnc/testdata/novnc-static.messages.z \
//     --static-expected webvnc/testdata/novnc-static.expected.png [--scroll-sample FILE] --out DIR

struct Args {
    var webRoot = "webvnc/web"
    var python = "python3"
    var replay = "webvnc/linux/replay_messages.py"
    var staticSample = "webvnc/testdata/novnc-static.messages.z"
    var staticExpected = "webvnc/testdata/novnc-static.expected.png"
    var scrollSample: String?
    var out = "webvnc-shell-out"

    static func parse() -> Args {
        var a = Args()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            let value = it.next() ?? ""
            switch arg {
            case "--web-root": a.webRoot = value
            case "--python": a.python = value
            case "--replay": a.replay = value
            case "--static-sample": a.staticSample = value
            case "--static-expected": a.staticExpected = value
            case "--scroll-sample": a.scrollSample = value.isEmpty ? nil : value
            case "--out": a.out = value
            default: print("unknown argument \(arg)"); exit(2)
            }
        }
        return a
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw Failure(description: message()) }
}

/// Stands in for the App's menus: ⌘Q must reach the menu (recorded here, not quitting), and Edit's
/// Paste (⌘V) is what makes WebKit fire the page's paste event.
final class MenuTarget: NSObject {
    var quitPressed = 0
    @objc func quit(_ sender: Any?) { quitPressed += 1 }
}

@MainActor
func makeMenu(_ target: MenuTarget) -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    let quit = NSMenuItem(title: "Quit", action: #selector(MenuTarget.quit(_:)), keyEquivalent: "q")
    quit.target = target
    appMenu.addItem(quit)
    appItem.submenu = appMenu
    main.addItem(appItem)
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editItem.submenu = edit
    main.addItem(editItem)
    return main
}

@MainActor
final class SelfTest {
    let a: Args
    let menu: MenuTarget
    var results: [[String: Any]] = []
    var info: [String: Any] = [:]
    let headers = [("CF-Access-Client-Id", "test-client-id"), ("CF-Access-Client-Secret", "test-client-secret")]
    var webRoot: URL { URL(fileURLWithPath: a.webRoot).standardizedFileURL }
    var outDir: URL { URL(fileURLWithPath: a.out) }
    var pageOrigin = "\(BundleSchemeHandler.scheme)://app"

    init(args: Args, menu: MenuTarget) {
        a = args
        self.menu = menu
    }

    func check(_ name: String, required: Bool = true, _ body: () async throws -> [String: Any]) async {
        let started = Date()
        do {
            let detail = try await body()
            results.append(["name": name, "ok": true, "required": required, "detail": detail, "ms": ms(since: started)])
            print("PASS  \(name)  \(jsonString(detail).replacingOccurrences(of: "\n", with: " ").prefix(600))")
        } catch {
            results.append(["name": name, "ok": false, "required": required, "detail": "\(error)", "ms": ms(since: started)])
            print("\(required ? "FAIL" : "WARN")  \(name)  \(error)")
        }
        fflush(stdout)
    }

    func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    func save() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let all: [String: Any] = ["info": info, "results": results]
        try? Data(jsonString(all).utf8).write(to: outDir.appendingPathComponent("results.json"))
    }

    /// A page from the URL scheme, ready to connect.
    func openPage(csp: String) async throws -> Viewer {
        let viewer = Viewer(webRoot: webRoot, csp: csp)
        viewer.loadFromScheme()
        guard await viewer.waitFor("ready", timeout: 20) != nil else { throw Failure(description: "the page did not load") }
        return viewer
    }

    func connect(_ viewer: Viewer, _ options: [String: Any]) async {
        _ = await viewer.call("return window.shionVNC.connect(o)", ["o": options])
    }

    func report(_ viewer: Viewer) async -> [String: Any] {
        (await viewer.call("return window.shionVNC.report()") as? [String: Any]) ?? [:]
    }

    /// Waits until the page has had no new bytes for `quiet` seconds (the replay has been played).
    func waitUntilQuiet(_ viewer: Viewer, quiet: Double = 1.5, timeout: Double = 30) async -> [String: Any] {
        var last = -1
        var since = Date()
        let deadline = Date().addingTimeInterval(timeout)
        var r: [String: Any] = [:]
        while Date() < deadline {
            r = await report(viewer)
            let bytes = r["bytesIn"] as? Int ?? 0
            if bytes != last {
                last = bytes
                since = Date()
            } else if Date().timeIntervalSince(since) >= quiet {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return r
    }

    func comparePicture(_ viewer: Viewer, name: String) async -> [String: Any] {
        guard let url = await viewer.call("return window.shionVNC.picturePNG()") as? String,
              let png = Picture.data(fromDataURL: url) else { return ["error": "no picture"] }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
        guard let expected = try? Data(contentsOf: URL(fileURLWithPath: a.staticExpected)) else { return ["error": "no expected picture"] }
        return Picture.compare(png, expected)
    }

    func run() async -> Bool {
        info["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
        info["webkit"] = Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "?"
        info["WKJSScriptingBuffer"] = Runtime.describe("WKJSScriptingBuffer")
        let ucc = Runtime.describe("WKUserContentController")
        info["WKUserContentController buffer/handle methods"] = ((ucc["instanceMethods"] as? [String]) ?? []).filter {
            $0.localizedCaseInsensitiveContains("buffer") || $0.localizedCaseInsensitiveContains("handle")
        }
        print("info: \(jsonString(info))")
        NSApp.activate(ignoringOtherApps: true)

        // ---- loading
        await check("page: from the URL scheme (ES modules, CSP header)") {
            let viewer = try await openPage(csp: Viewer.cspRelay)
            defer { viewer.close() }
            var ready = viewer.first("ready") ?? [:]
            ready.removeValue(forKey: "type")
            pageOrigin = ready["origin"] as? String ?? pageOrigin
            let csp = await viewer.call("""
                let fetchBlocked = false
                try { await fetch('https://example.com/') } catch { fetchBlocked = true }
                const s = document.createElement('script'); s.textContent = 'window.__inline = 1'; document.head.append(s)
                await new Promise(r => setTimeout(r, 200))
                return { fetchBlocked, inlineRan: !!window.__inline, ua: navigator.userAgent }
                """) as? [String: Any] ?? [:]
            try expect((csp["fetchBlocked"] as? Bool) == true && (csp["inlineRan"] as? Bool) == false, "CSP did not hold: \(csp)")
            return ["ready": ready, "csp": csp, "served": viewer.schemes.served]
        }
        await check("page: from a file URL (loadFileURL)", required: false) {
            let viewer = Viewer(webRoot: webRoot, csp: Viewer.cspRelay)
            defer { viewer.close() }
            viewer.loadFromFile()
            let ready = await viewer.waitFor("ready", timeout: 8)
            try expect(ready != nil, "no ready message within 8 s: ES modules from file:// (or 'self' in the CSP) do not load")
            return ["ready": ready ?? [:]]
        }

        guard FileManager.default.fileExists(atPath: a.staticSample) else {
            print("no static sample at \(a.staticSample)")
            save()
            return false
        }
        let replay: ReplayServer
        do {
            replay = try ReplayServer(python: a.python, script: a.replay, sample: a.staticSample)
        } catch {
            print("replay server did not start: \(error)")
            save()
            return false
        }
        defer { replay.stop() }

        // ---- option A: the loopback relay
        await check("relay: the picture, and a clean close (1000) passes through to the bridge") {
            let relay = Relay(upstream: replay.url(then: "wait"), headers: headers)
            _ = try await relay.start()
            defer { relay.stop() }
            let viewer = try await openPage(csp: Viewer.cspRelay)
            defer { viewer.close() }
            await connect(viewer, ["transport": "relay", "url": relay.url.absoluteString, "protocols": [relay.subprotocol], "viewOnly": true])
            let first = await viewer.waitFor("firstFrame", timeout: 15)
            try expect(first != nil, "no first frame")
            let r = await waitUntilQuiet(viewer)
            let picture = await comparePicture(viewer, name: "relay-static")
            let before = replay.output.count
            _ = await viewer.call("return window.shionVNC.disconnect(true)")
            let rep = await relay.ended(timeout: 5)
            try? await Task.sleep(nanoseconds: 500_000_000)
            let replayLines = Array(replay.output.dropFirst(before))
            try expect(replayLines.contains("client closed 1000"), "the replay server saw \(replayLines)")
            let mean = picture["meanAbsDiff"] as? Double ?? 99
            try expect(mean < 2.0, "picture differs from Chromium's: \(picture)")
            return ["firstFrameMs": orNull(first?["ms"]), "updates": orNull(r["updates"]), "bytesIn": orNull(r["bytesIn"]),
                    "picture": picture, "relay": rep.json, "replay": replayLines]
        }
        await check("relay: another viewer took over (4000) reaches the page") {
            let relay = Relay(upstream: replay.url(then: "close4000"), headers: headers)
            _ = try await relay.start()
            defer { relay.stop() }
            let viewer = try await openPage(csp: Viewer.cspRelay)
            defer { viewer.close() }
            await connect(viewer, ["transport": "relay", "url": relay.url.absoluteString, "protocols": [relay.subprotocol], "viewOnly": true])
            let closed = await viewer.waitFor("state", timeout: 20) { $0["state"] as? String == "disconnected" }
            let rep = await relay.ended(timeout: 5)
            try expect(closed?["code"] as? Int == 4000, "page saw \(closed ?? [:]), relay \(rep.json)")
            return ["code": 4000, "reason": orNull(closed?["reason"]), "relay": rep.json]
        }
        await check("relay: refuses other local clients and a foreign Origin; one page only") {
            let relay = Relay(upstream: replay.url(then: "wait"), headers: headers, allowedOrigins: [pageOrigin])
            _ = try await relay.start()
            defer { relay.stop() }
            var attempts: [String: String] = [:]
            attempts["no subprotocol"] = await tryConnect(relay.url, subprotocols: [], origin: pageOrigin)
            attempts["wrong token"] = await tryConnect(relay.url, subprotocols: ["shion." + String(repeating: "0", count: 32)], origin: pageOrigin)
            attempts["token, foreign origin"] = await tryConnect(relay.url, subprotocols: [relay.subprotocol], origin: "https://evil.example")
            attempts["token, no origin"] = await tryConnect(relay.url, subprotocols: [relay.subprotocol], origin: nil)
            let viewer = try await openPage(csp: Viewer.cspRelay)
            defer { viewer.close() }
            await connect(viewer, ["transport": "relay", "url": relay.url.absoluteString, "protocols": [relay.subprotocol], "viewOnly": true])
            let first = await viewer.waitFor("firstFrame", timeout: 15)
            attempts["token and origin, second connection"] = await tryConnect(relay.url, subprotocols: [relay.subprotocol], origin: pageOrigin)
            _ = await viewer.call("return window.shionVNC.disconnect(true)")
            let rep = await relay.snapshot()
            try expect(first != nil, "the page itself was refused: \(rep.json)")
            for (k, v) in attempts { try expect(v != "accepted", "\(k) was accepted") }
            return ["attempts": attempts, "relay": rep.json]
        }

        // ---- option C: no socket in the page
        await check("channel: the picture, and a clean close (1000) passes through to the bridge") {
            let viewer = try await openPage(csp: Viewer.cspChannel)
            defer { viewer.close() }
            let host = ChannelHost(upstream: replay.url(then: "wait"), headers: headers, viewer: viewer)
            viewer.onMessage = { host.pageMessage($0) }
            await connect(viewer, ["transport": "channel", "viewOnly": true])
            host.start()
            let first = await viewer.waitFor("firstFrame", timeout: 15)
            try expect(first != nil, "no first frame")
            let r = await waitUntilQuiet(viewer)
            let picture = await comparePicture(viewer, name: "channel-static")
            let before = replay.output.count
            _ = await viewer.call("return window.shionVNC.disconnect(true)")
            try? await Task.sleep(nanoseconds: 800_000_000)
            let replayLines = Array(replay.output.dropFirst(before))
            try expect(replayLines.contains("client closed 1000"), "the replay server saw \(replayLines)")
            let mean = picture["meanAbsDiff"] as? Double ?? 99
            try expect(mean < 2.0, "picture differs from Chromium's: \(picture)")
            return ["firstFrameMs": orNull(first?["ms"]), "updates": orNull(r["updates"]), "bytesIn": orNull(r["bytesIn"]),
                    "picture": picture, "channel": host.stats.json]
        }
        await check("channel: 4000 reaches the page") {
            let viewer = try await openPage(csp: Viewer.cspChannel)
            defer { viewer.close() }
            let host = ChannelHost(upstream: replay.url(then: "close4000"), headers: headers, viewer: viewer)
            viewer.onMessage = { host.pageMessage($0) }
            await connect(viewer, ["transport": "channel", "viewOnly": true])
            host.start()
            let closed = await viewer.waitFor("state", timeout: 20) { $0["state"] as? String == "disconnected" }
            try expect(closed?["code"] as? Int == 4000, "page saw \(closed ?? [:])")
            return ["code": 4000, "channel": host.stats.json]
        }

        // ---- keys through the real WKWebView: ⌘ as Ctrl, ⌘Q stays with the Mac, ⌘V pastes
        await check("keys: plain key, ⌘A → Ctrl+A, ⌘Q to the menu (never the page), ⌘V → clipboard + Ctrl+V") {
            let relay = Relay(upstream: replay.url(then: "wait"), headers: headers)
            _ = try await relay.start()
            defer { relay.stop() }
            let viewer = try await openPage(csp: Viewer.cspRelay)
            defer { viewer.close() }
            await connect(viewer, ["transport": "relay", "url": relay.url.absoluteString, "protocols": [relay.subprotocol],
                                   "viewOnly": false, "debugKeys": true])
            try expect(await viewer.waitFor("firstFrame", timeout: 15) != nil, "no first frame")
            _ = await waitUntilQuiet(viewer, quiet: 0.8)
            viewer.window.makeKeyAndOrderFront(nil)
            _ = viewer.window.makeFirstResponder(viewer.webView)
            _ = await viewer.call("document.getElementById('ime').focus(); return document.activeElement && document.activeElement.id")
            let key = viewer.window.isKeyWindow
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("粘贴 ペースト ✓", forType: .string)
            var paths: [String] = []
            let sequence: [(String, UInt16, NSEvent.ModifierFlags)] = [("b", 11, []), ("a", 0, .command), ("q", 12, .command), ("v", 9, .command)]
            for (chars, code, flags) in sequence {
                paths.append(send(chars, code, flags, to: viewer))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            let r = await report(viewer)
            let keys = r["keys"] as? [String] ?? []
            let typed = viewer.messages.filter { $0["type"] as? String == "typed" }
            _ = await viewer.call("return window.shionVNC.disconnect(true)")
            let detail: [String: Any] = ["windowWasKey": key, "dispatch": paths, "keysSent": keys, "typed": typed,
                                         "routedToMac": viewer.webView.routedToMac, "quitMenuItem": menu.quitPressed]
            try expect(keys.starts(with: ["+62", "-62"]), "plain b: \(detail)")
            try expect(keys.contains("+ffe3") && keys.contains("+61"), "⌘A did not become Ctrl+A: \(detail)")
            try expect(!keys.contains("+71"), "⌘Q reached the remote: \(detail)")
            try expect(!keys.contains("+ffe9") && !keys.contains("+ffe7"), "⌘ went out as Alt/Meta: \(detail)")
            return detail
        }

        // ---- throughput: a recorded Chrome scroll (Tight + JPEG), as fast as WebKit takes it
        if let scroll = a.scrollSample, FileManager.default.fileExists(atPath: scroll) {
            let big = try? ReplayServer(python: a.python, script: a.replay, sample: scroll)
            // how many updates the recording holds (novnc-scroll.json next to it), else: until quiet
            let metaURL = URL(fileURLWithPath: scroll).deletingLastPathComponent().appendingPathComponent("novnc-scroll.json")
            let expectedUpdates = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: metaURL))) as? [String: Any])?["updates"] as? Int
            for transport in ["relay", "channel"] {
                await check("throughput: recorded scroll through the \(transport)", required: false) {
                    guard let big else { throw Failure(description: "replay server did not start") }
                    let viewer = try await openPage(csp: transport == "relay" ? Viewer.cspRelay : Viewer.cspChannel)
                    defer { viewer.close() }
                    var relay: Relay?
                    var host: ChannelHost?
                    let webBefore = CPU.webContentTotal()
                    let selfBefore = CPU.selfSeconds()
                    let started = Date()
                    if transport == "relay" {
                        let r = Relay(upstream: big.url(then: "wait"), headers: headers)
                        _ = try await r.start()
                        relay = r
                        await connect(viewer, ["transport": "relay", "url": r.url.absoluteString, "protocols": [r.subprotocol], "viewOnly": true])
                    } else {
                        let h = ChannelHost(upstream: big.url(then: "wait"), headers: headers, viewer: viewer)
                        viewer.onMessage = { h.pageMessage($0) }
                        host = h
                        await connect(viewer, ["transport": "channel", "viewOnly": true])
                        h.start()
                    }
                    var r: [String: Any] = [:]
                    var last = -1
                    var since = Date()
                    while Date().timeIntervalSince(started) < 120 {
                        r = await report(viewer)
                        let updates = r["updates"] as? Int ?? 0
                        if let expectedUpdates, updates >= expectedUpdates { break }
                        if updates != last {
                            last = updates
                            since = Date()
                        } else if Date().timeIntervalSince(since) > 3 {
                            break
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    let seconds = Date().timeIntervalSince(started)
                    let webCPU = CPU.webContentTotal() - webBefore
                    let shellCPU = CPU.selfSeconds() - selfBefore
                    _ = await viewer.call("return window.shionVNC.disconnect(true)")
                    relay?.stop()
                    let mb = Double(r["bytesIn"] as? Int ?? 0) / 1e6
                    return ["seconds": seconds, "updates": orNull(r["updates"]), "expectedUpdates": orNull(expectedUpdates),
                            "MB": mb, "MBps": mb / seconds, "webContentCPU": webCPU, "shellCPU": shellCPU,
                            "channel": orNull(host?.stats.json)]
                }
            }
            big?.stop()
        }

        save()
        let failed = results.filter { ($0["ok"] as? Bool) != true && ($0["required"] as? Bool) == true }
        print("\(results.count - failed.count)/\(results.count) passed")
        return failed.isEmpty
    }

    /// Another local client trying the relay: "accepted" or why not.
    func tryConnect(_ url: URL, subprotocols: [String], origin: String?) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            var headers: [(String, String)] = []
            if let origin { headers.append(("Origin", origin)) }
            let queue = DispatchQueue(label: "webvnc.probe")
            var done = false
            var client: Upstream?
            client = Upstream(url: url, headers: headers, subprotocols: subprotocols, queue: queue) { event in
                guard !done else { return }
                switch event {
                case .open:
                    done = true
                    client?.close(code: nil)
                    c.resume(returning: "accepted")
                case .refused(let why), .closed(_, let why):
                    done = true
                    c.resume(returning: "refused (\(why.prefix(60)))")
                case .data:
                    break
                }
            }
            client?.start(timeout: 5)
        }
    }

    /// Delivers a key event the way AppKit would: NSApp.sendEvent when the window is key;
    /// otherwise the same order by hand (the view's key equivalents, then the menu).
    func send(_ chars: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, to viewer: Viewer) -> String {
        let window = viewer.window
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { return "no event" }
        if window.isKeyWindow {
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
            return "NSApp.sendEvent"
        }
        if flags.contains(.command) {
            if !viewer.webView.performKeyEquivalent(with: down) {
                _ = NSApp.mainMenu?.performKeyEquivalent(with: down)
                return "view, then menu"
            }
            return "view"
        }
        window.sendEvent(down)
        window.sendEvent(up)
        return "window.sendEvent"
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let menuTarget = MenuTarget()
    app.mainMenu = makeMenu(menuTarget)
    let selfTest = SelfTest(args: Args.parse(), menu: menuTarget)
    DispatchQueue.main.asyncAfter(deadline: .now() + 420) {
        print("watchdog: giving up after 420 s")
        MainActor.assumeIsolated { selfTest.save() }
        exit(3)
    }
    Task { @MainActor in
        let ok = await selfTest.run()
        exit(ok ? 0 : 1)
    }
    app.run()
}
