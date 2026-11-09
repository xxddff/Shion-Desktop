import Foundation
import Network
import Security

/// Option A: a WebSocket relay on 127.0.0.1 for exactly one page.
///
/// - an ephemeral port on the loopback interface only (`requiredInterfaceType = .loopback`,
///   `acceptLocalOnly`), like the App's sign-in LoopbackListener;
/// - the page must offer the subprotocol `shion.<token>` (128 random bits, compared in constant
///   time). Network.framework's WebSocket server shows the subprotocols and headers of the request
///   but not its path, so the token cannot ride in the URL;
/// - optionally the Origin must be the page's (`allowedOrigins`);
/// - the first page that passes gets the relay; the listener then closes;
/// - the bridge's close code goes back to the page; a clean close from the page (1000 / 1001) goes
///   upstream (the bridge hands the lease back), anything else drops the upstream link without a
///   close frame (the bridge keeps the lease).
final class Relay: @unchecked Sendable {
    struct Report {
        var seenOrigins: [String] = []
        var requestHeaderNames: [String] = []
        var rejected: [String] = []
        var accepted = false
        var downBytes = 0
        var upBytes = 0
        var pageClose: Int?
        var upstreamClose: Int?
        var sentPage: String?
        var sentUpstream: String?

        var json: [String: Any] {
            ["seenOrigins": seenOrigins, "requestHeaderNames": requestHeaderNames, "rejected": rejected,
             "accepted": accepted, "downBytes": downBytes, "upBytes": upBytes,
             "pageClose": orNull(pageClose), "upstreamClose": orNull(upstreamClose),
             "sentPage": orNull(sentPage), "sentUpstream": orNull(sentUpstream)]
        }
    }

    let token: String
    var subprotocol: String { "shion." + token }
    private(set) var port: UInt16 = 0
    private let upstreamURL: URL
    private let headers: [(String, String)]
    private let allowedOrigins: Set<String>
    private let queue = DispatchQueue(label: "webvnc.relay")
    private var listener: NWListener?
    private var page: NWConnection?
    private var upstream: Upstream?
    private var upstreamOpen = false
    private var pendingUp: [Data] = []
    private var taken = false
    private var ended = false
    private var report = Report()
    private var endWaiters: [CheckedContinuation<Report, Never>] = []

    init(upstream: URL, headers: [(String, String)], allowedOrigins: Set<String> = []) {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        upstreamURL = upstream
        self.headers = headers
        self.allowedOrigins = allowedOrigins
    }

    var url: URL { URL(string: "ws://127.0.0.1:\(port)/")! }

    func start() async throws -> UInt16 {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024 * 1024
        ws.setClientRequestHandler(queue) { [weak self] subprotocols, additionalHeaders in
            guard let self else { return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: nil) }
            return self.decide(subprotocols, additionalHeaders)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let port: UInt16 = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    c.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    resumed = true
                    c.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.incoming(connection) }
            listener.start(queue: queue)
        }
        self.port = port
        return port
    }

    /// The WebSocket handshake of every connection comes through here (on `queue`).
    private func decide(_ subprotocols: [String], _ additionalHeaders: [(name: String, value: String)]) -> NWProtocolWebSocket.Response {
        let names = additionalHeaders.map { $0.name.lowercased() }
        if report.requestHeaderNames.isEmpty { report.requestHeaderNames = names.sorted() }
        let origin = additionalHeaders.first { $0.name.lowercased() == "origin" }?.value
        report.seenOrigins.append(origin ?? "(none)")
        var reason: String?
        if taken {
            reason = "second connection"
        } else if !subprotocols.contains(where: { Self.equal($0, subprotocol) }) {
            reason = "no token"
        } else if !allowedOrigins.isEmpty, !(origin.map { allowedOrigins.contains($0) } ?? false) {
            reason = "origin"
        }
        if let reason {
            report.rejected.append(reason)
            return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: nil)
        }
        taken = true
        return NWProtocolWebSocket.Response(status: .accept, subprotocol: subprotocol, additionalHeaders: nil)
    }

    private static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private func incoming(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if self.taken, self.page == nil {
                    self.page = connection
                    self.report.accepted = true
                    self.listener?.cancel()   // one page only
                    self.connectUpstream()
                    self.receivePage()
                } else if connection !== self.page {
                    connection.cancel()
                }
            case .failed, .cancelled:
                if connection === self.page { self.pageEnded(nil) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func connectUpstream() {
        let up = Upstream(url: upstreamURL, headers: headers, queue: queue) { [weak self] event in
            guard let self else { return }
            switch event {
            case .open:
                self.upstreamOpen = true
                for data in self.pendingUp { self.upstream?.send(data) }
                self.pendingUp = []
            case .data(let data):
                self.report.downBytes += data.count
                self.sendPage(data)
            case .closed(let code, let reason):
                self.upstreamEnded(code, reason)
            case .refused:
                self.upstreamEnded(4403, "upstream refused the upgrade")
            }
        }
        upstream = up
        up.start()
    }

    private func receivePage() {
        page?.receiveMessage { [weak self] content, context, _, error in
            guard let self, !self.ended else { return }
            if error != nil {
                self.pageEnded(nil)
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .binary, .cont:
                    if let content, !content.isEmpty {
                        self.report.upBytes += content.count
                        if self.upstreamOpen { self.upstream?.send(content) } else { self.pendingUp.append(content) }
                    }
                    self.receivePage()
                case .close:
                    self.pageEnded(CloseCodes.number(metadata.closeCode))
                case .text:
                    self.pageEnded(nil)
                default:
                    self.receivePage()
                }
            } else {
                self.pageEnded(nil)
            }
        }
    }

    private func sendPage(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "rfb", metadata: [metadata])
        page?.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func pageEnded(_ code: Int?) {
        guard !ended else { return }
        ended = true
        report.pageClose = code
        if let code, code == 1000 || code == 1001 {
            report.sentUpstream = "\(code)"
        } else {
            report.sentUpstream = "abort"
        }
        upstream?.close(code: code)
        page?.cancel()
        finish()
    }

    private func upstreamEnded(_ code: Int?, _ reason: String) {
        guard !ended else { return }
        ended = true
        report.upstreamClose = code
        if let code, code != 1005, code != 1006 {
            report.sentPage = "\(code)"
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = CloseCodes.code(code)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            page?.send(content: Data(reason.utf8.prefix(120)), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.page?.cancel() }
        } else {
            report.sentPage = "abort"
            page?.forceCancel()
        }
        finish()
    }

    private func finish() {
        let waiters = endWaiters
        endWaiters = []
        let r = report
        for w in waiters { w.resume(returning: r) }
    }

    /// Waits until the relay has ended (or `timeout`), and returns what happened.
    func ended(timeout: Double = 10) async -> Report {
        await withCheckedContinuation { (c: CheckedContinuation<Report, Never>) in
            queue.async {
                if self.ended {
                    c.resume(returning: self.report)
                    return
                }
                self.endWaiters.append(c)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let i = self.endWaiters.firstIndex(where: { _ in true }) {
                        let w = self.endWaiters.remove(at: i)
                        w.resume(returning: self.report)
                    }
                }
            }
        }
    }

    func snapshot() async -> Report {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.report) } }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.page?.forceCancel()
            self.upstream?.close(code: nil)
        }
    }
}
