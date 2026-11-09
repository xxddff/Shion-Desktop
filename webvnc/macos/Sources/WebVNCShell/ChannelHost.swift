import Foundation
import WebKit

/// Option C: the app holds the bridge's WebSocket and moves the bytes through WebKit's script
/// bridge. Page → app: {type: 'send', data: base64} messages. App → page: callAsyncJavaScript, one
/// at a time and in order; what arrives while a call is in flight goes in the next one, one base64
/// string per bridge message (WKScriptMessage carries no binary data, so both ways are base64).
@MainActor
final class ChannelHost {
    struct Stats {
        var batches = 0
        var bytesDown = 0
        var bytesUp = 0
        var closeCode: Int?
        var sentClose: String?
        var json: [String: Any] {
            ["batches": batches, "bytesDown": bytesDown, "bytesUp": bytesUp,
             "closeCode": orNull(closeCode), "sentClose": orNull(sentClose)]
        }
    }

    private enum Op {
        case open
        case data(Data)
        case close(Int, String)
    }

    private(set) var stats = Stats()
    private let viewer: Viewer
    private var upstream: Upstream?
    private var ops: [Op] = []
    private var inFlight = false
    private let network = DispatchQueue(label: "webvnc.channel")

    init(upstream url: URL, headers: [(String, String)], viewer: Viewer) {
        self.viewer = viewer
        upstream = Upstream(url: url, headers: headers, queue: network) { [weak self] event in
            // FIFO onto the main thread: the page must see open, data and close in order
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
    }

    func start() {
        upstream?.start()
    }

    /// Called with every message the page posts.
    func pageMessage(_ message: [String: Any]) {
        guard let upstream else { return }
        switch message["type"] as? String {
        case "send":
            guard let text = message["data"] as? String, let data = Data(base64Encoded: text) else { return }
            stats.bytesUp += data.count
            network.async { upstream.send(data) }
        case "close":
            let code = message["code"] as? Int
            stats.sentClose = code.map(String.init) ?? "no status"
            network.async { upstream.close(code: code) }
        default:
            break
        }
    }

    private func handle(_ event: Upstream.Event) {
        switch event {
        case .open:
            ops.append(.open)
        case .data(let data):
            stats.bytesDown += data.count
            ops.append(.data(data))
        case .closed(let code, let reason):
            stats.closeCode = code
            ops.append(.close(code ?? 1006, reason))
        case .refused:
            ops.append(.close(4403, "upstream refused the upgrade"))
        }
        pump()
    }

    private func pump() {
        guard !inFlight, !ops.isEmpty else { return }
        let body: String
        var arguments: [String: Any] = [:]
        switch ops.removeFirst() {
        case .open:
            body = "window.shionVNC.channelOpened()"
        case .close(let code, let reason):
            body = "window.shionVNC.channelClosed(c, r)"
            arguments = ["c": code, "r": reason]
        case .data(let first):
            // one base64 string per bridge message (noVNC needs the message boundaries)
            var batch = [first.base64EncodedString()]
            while case .data(let more)? = ops.first {
                batch.append(more.base64EncodedString())
                ops.removeFirst()
            }
            stats.batches += 1
            body = "window.shionVNC.channelReceived(b)"
            arguments = ["b": batch]
        }
        inFlight = true
        Task {
            _ = await viewer.call(body, arguments)
            inFlight = false
            pump()
        }
    }
}
