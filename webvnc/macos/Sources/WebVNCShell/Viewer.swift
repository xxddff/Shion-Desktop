import AppKit
import WebKit

/// The picture's web view. ⌘ shortcuts that belong to the Mac never reach the page; every other
/// key equivalent goes to the page first (WebKit offers it to the page, which turns ⌘ into Ctrl
/// for the remote), and back to the menu only if the page leaves it.
final class ScreenWebView: WKWebView {
    /// ⌘Q ⌘H ⌘M ⌘, ⌘Tab ⌘` ⌘Space (the same list the page keeps for itself)
    static let macKeys: Set<String> = ["q", "h", "m", ",", "\t", "`", " "]
    var routedToMac: [String] = []

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased(), Self.macKeys.contains(key) {
            routedToMac.append(key)
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Serves web/ from disk under shion-webvnc:// (what the App would serve from its bundle), with a
/// Content-Security-Policy header on the page on top of the page's own meta policy.
@MainActor
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "shion-webvnc"
    let root: URL
    var csp: String
    var served: [String] = []

    init(root: URL, csp: String) {
        self.root = root.standardizedFileURL
        self.csp = csp
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path.isEmpty || url.path == "/" ? "viewer.html" : String(url.path.dropFirst())
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
            return
        }
        served.append(path)
        var headers = ["Content-Type": Self.mime(file.pathExtension), "Content-Length": "\(data.count)", "Cache-Control": "no-store"]
        if file.pathExtension == "html" { headers["Content-Security-Policy"] = csp }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    static func mime(_ ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }
}

/// What the page posts through window.webkit.messageHandlers.shion.
@MainActor
final class PageBridge: NSObject, WKScriptMessageHandler {
    var onMessage: @MainActor ([String: Any]) -> Void = { _ in }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] {
            onMessage(body)
        }
    }
}

/// One window with the page, and the means to drive it.
@MainActor
final class Viewer {
    static let cspRelay = "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; connect-src ws://127.0.0.1:*"
    static let cspChannel = "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; connect-src 'none'"

    let webView: ScreenWebView
    let window: NSWindow
    let schemes: BundleSchemeHandler
    private let bridge = PageBridge()
    private(set) var messages: [[String: Any]] = []
    var onMessage: (@MainActor ([String: Any]) -> Void)?
    let started = Date()

    init(webRoot: URL, csp: String) {
        schemes = BundleSchemeHandler(root: webRoot, csp: csp)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemes, forURLScheme: BundleSchemeHandler.scheme)
        configuration.userContentController.add(bridge, name: "shion")
        configuration.websiteDataStore = .nonPersistent()
        webView = ScreenWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "webvnc"
        // We own the window: AppKit's default (release on close) over-releases it under ARC
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        bridge.onMessage = { [weak self] message in
            guard let self else { return }
            var m = message
            m["t"] = Int(Date().timeIntervalSince(self.started) * 1000)
            self.messages.append(m)
            self.onMessage?(m)
        }
    }

    func loadFromScheme() {
        webView.load(URLRequest(url: URL(string: "\(BundleSchemeHandler.scheme)://app/viewer.html")!))
    }

    func loadFromFile() {
        webView.loadFileURL(schemes.root.appendingPathComponent("viewer.html"), allowingReadAccessTo: schemes.root)
    }

    /// Runs `body` as an async function body in the page and returns its result.
    func call(_ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
        await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): c.resume(returning: value)
                case .failure(let error): c.resume(returning: ["error": "\(error)"])
                }
            }
        }
    }

    func first(_ type: String, where predicate: ([String: Any]) -> Bool = { _ in true }) -> [String: Any]? {
        messages.first { $0["type"] as? String == type && predicate($0) }
    }

    func waitFor(_ type: String, timeout: Double = 15, where predicate: @escaping ([String: Any]) -> Bool = { _ in true }) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let m = first(type, where: predicate) { return m }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    func close() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "shion")
        webView.stopLoading()
        window.contentView = nil
        window.close()
    }
}
