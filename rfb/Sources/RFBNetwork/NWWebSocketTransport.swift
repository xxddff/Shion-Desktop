#if canImport(Network)
import Foundation
import Network
import RFB

/// RFB over a Network.framework WebSocket (`NWConnection` + `NWProtocolWebSocket`), with extra
/// request headers for Cloudflare Access. What the App uses.
///
/// A receive is always pending (into a bounded queue), so the server's close frame is read the
/// moment it arrives, even while the client is busy sending; this is how Hermes' 4000 (another
/// viewer took control) reaches the caller as a close code instead of a failed send. Errors are
/// Network.framework's (no URL in them) or `RFBConnectionClosed`.
///
/// ```swift
/// let transport = try NWWebSocketTransport(url: displayURL, headers: [
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
    private let inbox = Inbox()
    private let log: (@Sendable (String) -> Void)?

    /// `url` is `ws://` or `wss://` (any letter case); it carries the single-use ticket and is
    /// logged nowhere. Header values are sent, never logged; over plain `ws://` only to loopback.
    /// Not ready within `connectTimeout` seconds counts as refused. `log` hears connection states
    /// and close codes (for debugging; no secrets).
    public init(url: URL, headers: [(String, String)] = [], connectTimeout: Double = 15,
                log: (@Sendable (String) -> Void)? = nil) throws {
        let (secure, url) = try WebSocketURLPolicy.check(url, sendsHeaders: !headers.isEmpty)
        self.log = log
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 64 * 1024 * 1024
        options.setAdditionalHeaders(headers.map { (name: $0.0, value: $0.1) })
        let parameters: NWParameters = secure ? .tls : .tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
        inbox.onDrain = { [weak self] in self?.receiveNext() }
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
        switch outcome {
        case .success:
            receiveNext()
        case .failure(let error):
            log?("not connected: \(error)")
            inbox.finish(.failure(error))
            connection.cancel()
        }
        waiters.forEach { $0.resume(with: outcome) }
    }

    private func stateChanged(_ state: NWConnection.State) {
        log?("state \(state)")
        switch state {
        case .ready:
            settle(.success(()))
        case .failed(let error):
            settle(.failure(RFBError.connectionRefused("WebSocket connection failed: \(error)")))
            // Once connected, a failure ends the inbox too (unless a close frame did already).
            inbox.finish(.failure(lock.withLock { closeReceived } ?? RFBConnectionClosed(code: nil, reason: "\(error)")))
        case .waiting(let error):
            // Before it is ready, "waiting" means it could not connect (refused, no route, a
            // rejected upgrade); do not sit there retrying.
            settle(.failure(RFBError.connectionRefused("WebSocket connection failed: \(error)")))
        case .cancelled:
            settle(.failure(RFBError.endOfStream))
            inbox.finish(.failure(lock.withLock { closeReceived } ?? RFBConnectionClosed(code: nil, reason: "cancelled")))
        default:
            break
        }
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

    /// Keeps one receive pending; data goes to the inbox, a close frame ends it with its code.
    private func receiveNext() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            let incoming: Incoming
            if let error {
                incoming = .failed("\(error)")
            } else if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .binary, .cont:
                    incoming = .data(content ?? Data())
                case .close:
                    incoming = .close(Self.number(metadata.closeCode), content.map { String(decoding: $0, as: UTF8.self) } ?? "")
                case .text:
                    incoming = .text
                case .ping, .pong:
                    incoming = .control
                @unknown default:
                    incoming = .control
                }
            } else if let content {
                incoming = .data(content)
            } else {
                incoming = .ended
            }
            self.handle(incoming)
        }
    }

    private func handle(_ incoming: Incoming) {
        switch incoming {
        case .data(let data):
            if inbox.push([UInt8](data)) { receiveNext() }
        case .control:
            receiveNext()
        case .close(let code, let reason):
            log?("close frame, code \(code.map(String.init) ?? "none")")
            let closed = RFBConnectionClosed(code: code, reason: reason)
            lock.withLock { closeReceived = closed }
            inbox.finish(.failure(closed))
            connection.cancel()
        case .text:
            inbox.finish(.failure(RFBError.protocolViolation("text frame on the RFB socket")))
            connection.cancel()
        case .failed(let message):
            log?("receive failed: \(message)")
            inbox.finish(.failure(lock.withLock { closeReceived } ?? RFBConnectionClosed(code: nil, reason: message)))
        case .ended:
            inbox.finish(.success(nil))
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
        return try await inbox.next()
    }

    public func close(_ code: RFBCloseCode) async {
        if code == .abort {
            connection.forceCancel()
            return
        }
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
