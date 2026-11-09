// swift-tools-version: 6.0
import PackageDescription

// A minimal macOS shell around the web viewer (web/): an AppKit window with a WKWebView that loads
// the page from disk through a URL scheme handler, the loopback relay (option A) and the in-app
// channel (option C), and a self-test against rfb/testbed/replay_server.py. A prototype, not the
// App: Swift 5 language mode, so the concurrency checks stay warnings.
let package = Package(
    name: "WebVNCShell",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "webvnc-shell", path: "Sources/WebVNCShell"),
    ],
    swiftLanguageModes: [.v5]
)
