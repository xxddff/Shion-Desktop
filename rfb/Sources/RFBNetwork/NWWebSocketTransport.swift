#if canImport(Network)
import Foundation
import Network
import RFB

/// RFB over a Network.framework WebSocket (`NWConnection` + `NWProtocolWebSocket`), with extra
/// request headers for Cloudflare Access.
///
/// Unlike `URLSessionWebSocketTask`, which reports a server-initiated close only as "socket is
/// not connected", this hands us the server's close frame with its code, so the App can tell
/// Hermes' 4000 (another viewer took control: go back to watching) from a dropped link (control
/// stays with you).
///
/// ```swift
/// let transport = NWWebSocketTransport(url: displayURL, headers: [
///     ("CF-Access-Client-Id", id), ("CF-Access-Client-Secret", secret)])
/// ```
public final class NWWebSocketTransport: RFBTransport, @unchecked Sendable {
    private enum Phase {
        case connecting
        case ready
        case failed(Error)
    }

    /// What one receive produced, reduced to Sendable values inside the callback.
    private enum Incoming: Sendable {
        case data(Data)
        case close(Int?, String)
        case text
        case control
        case failed(String)
        case ended
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "rfb.nw-websocket")
    private let lock = NSLock()
    private var phase = Phase.connecting
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var closeReceived: RFBConnectionClosed?
    private let log: (@Sendable (String) -> Void)?

    /// `url` is `ws://` or `wss://`; it carries the single-use ticket and is logged nowhere.
    /// Header values are sent, never logged. Not ready within `connectTimeout` seconds counts as
    /// refused. `log` hears connection states and close codes (for debugging; no secrets).
    public init(url: URL, headers: [(String, String)] = [], connectTimeout: Double = 15,
                log: (@Sendable (String) -> Void)? = nil) {
        self.log = log
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 64 * 1024 * 1024
        options.setAdditionalHeaders(headers.map { (name: $0.0, value: $0.1) })
        let parameters: NWParameters = url.scheme == "wss" ? .tls : .tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
        connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
            self?.settle(.failure(RFBError.connectionRefused("WebSocket not connected after \(Int(connectTimeout)) s")))
        }
    }

    /// Resolves the connect phase once: the first outcome wins.
    private func settle(_ outcome: Result<Void, Error>) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>]? in
            guard case .connecting = phase else { return nil }
            switch outcome {
            case .success: phase = .ready
            case .failure(let error): phase = .failed(error)
            }
            defer { readyWaiters = [] }
            return readyWaiters
        }
        guard let waiters else { return }
        if case .failure(let error) = outcome {
            log?("not connected: \(error)")
            connection.cancel()
        }
        waiters.forEach { $0.resume(with: outcome) }
    }

    private func stateChanged(_ state: NWConnection.State) {
        log?("state \(state)")
        let outcome: Result<Void, Error>?
        switch state {
        case .ready:
            outcome = .success(())
        case .failed(let error):
            outcome = .failure(RFBError.connectionRefused("WebSocket connection failed: \(error)"))
        case .waiting(let error):
            // Before it is ready, "waiting" means it could not connect (refused, no route, a
            // rejected upgrade); do not sit there retrying.
            outcome = .failure(RFBError.connectionRefused("WebSocket connection failed: \(error)"))
        case .cancelled:
            outcome = .failure(RFBError.endOfStream)
        default:
            outcome = nil
        }
        guard let outcome else { return }
        settle(outcome)
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let now = lock.withLock { () -> Result<Void, Error>? in
                switch phase {
                case .ready: return .success(())
                case .failed(let error): return .failure(error)
                case .connecting:
                    readyWaiters.append(c)
                    return nil
                }
            }
            if let now { c.resume(with: now) }
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        try await waitUntilReady()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "rfb", metadata: [metadata])
        let failure: String? = await withCheckedContinuation { c in
            connection.send(content: Data(bytes), contentContext: context, isComplete: true,
                            completion: .contentProcessed { error in c.resume(returning: error.map { "\($0)" }) })
        }
        if let failure {
            if let closed = lock.withLock({ closeReceived }) { throw closed }
            throw RFBConnectionClosed(code: nil, reason: failure)
        }
    }

    public func receive() async throws -> [UInt8]? {
        try await waitUntilReady()
        if let closed = lock.withLock({ closeReceived }) { throw closed }
        while true {
            let incoming = await withCheckedContinuation { (c: CheckedContinuation<Incoming, Never>) in
                connection.receiveMessage { content, context, _, error in
                    if let error {
                        c.resume(returning: .failed("\(error)"))
                        return
                    }
                    guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata else {
                        if let content {
                            c.resume(returning: Incoming.data(content))
                        } else {
                            c.resume(returning: Incoming.ended)
                        }
                        return
                    }
                    switch metadata.opcode {
                    case .binary, .cont:
                        c.resume(returning: .data(content ?? Data()))
                    case .close:
                        let reason = content.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        c.resume(returning: .close(Self.number(metadata.closeCode), reason))
                    case .text:
                        c.resume(returning: .text)
                    case .ping, .pong:
                        c.resume(returning: .control)
                    @unknown default:
                        c.resume(returning: .control)
                    }
                }
            }
            switch incoming {
            case .data(let data):
                return [UInt8](data)
            case .close(let code, let reason):
                log?("close frame, code \(code.map(String.init) ?? "none")")
                let closed = RFBConnectionClosed(code: code, reason: reason)
                lock.withLock { closeReceived = closed }
                connection.cancel()
                throw closed
            case .text:
                throw RFBError.protocolViolation("text frame on the RFB socket")
            case .control:
                continue
            case .failed(let message):
                log?("receive failed: \(message)")
                if let closed = lock.withLock({ closeReceived }) { throw closed }
                throw RFBConnectionClosed(code: nil, reason: message)
            case .ended:
                return nil
            }
        }
    }

    public func close(_ code: RFBCloseCode) async {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(code == .normal ? .normalClosure : .goingAway)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        // Give the close frame a moment to leave, then drop the connection.
        try? await Task.sleep(nanoseconds: 200_000_000)
        connection.cancel()
    }

    private static func number(_ code: NWProtocolWebSocket.CloseCode) -> Int? {
        switch code {
        case .protocolCode(let defined): return Int(defined.rawValue)
        case .applicationCode(let value): return Int(value)
        case .privateCode(let value): return Int(value)
        @unknown default: return nil
        }
    }
}
#endif
