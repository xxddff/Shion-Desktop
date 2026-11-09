import Foundation
import Network

/// The WebSocket to Hermes' display bridge, with the Access service-token headers
/// (Network.framework, the same setup as rfb/'s NWWebSocketTransport). Used by the relay
/// (option A) and the in-app channel (option C); the page never sees this connection, its URL
/// (with the ticket) or the headers. Events arrive on `queue`, in order.
///
/// Known issue (macOS 27, CI): a close the server starts (Hermes' 4000) never comes through, and the
/// last message before it is lost; the connection goes to ENOTCONN instead. rfb/ saw the same and
/// moved the App to its URLSessionWebSocketTransport; the App would use that here too (README,
/// finding 11).
final class Upstream: @unchecked Sendable {
    enum Event {
        case open
        case data(Data)
        /// The bridge's close frame (4000 control taken, 4401 ticket, 4001 desktop gone, 1000…),
        /// or nil when the link dropped without one.
        case closed(Int?, String)
        /// Never opened: the upgrade was refused (Access, the bridge) or nothing answered.
        case refused(String)
    }

    let queue: DispatchQueue
    private let connection: NWConnection
    private let onEvent: (Event) -> Void
    private var opened = false
    private var ended = false

    init(url: URL, headers: [(String, String)], subprotocols: [String] = [], queue: DispatchQueue,
         onEvent: @escaping (Event) -> Void) {
        self.queue = queue
        self.onEvent = onEvent
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 64 * 1024 * 1024
        options.setAdditionalHeaders(headers.map { (name: $0.0, value: $0.1) })
        if !subprotocols.isEmpty { options.setSubprotocols(subprotocols) }
        let parameters: NWParameters = url.scheme?.lowercased() == "wss" ? .tls : .tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }

    func start(timeout: Double = 15) {
        connection.stateUpdateHandler = { [weak self] state in self?.changed(state) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.opened, !self.ended else { return }
            self.end(.refused("not connected after \(Int(timeout)) s"))
            self.connection.forceCancel()
        }
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !opened, !ended else { return }
            opened = true
            onEvent(.open)
            receiveNext()
        case .waiting(let error), .failed(let error):
            // Before it is ready, "waiting" is a refused upgrade or no route (Network.framework does
            // not hand over the HTTP status): do not sit there retrying.
            if opened { end(.closed(nil, "\(error)")) } else { end(.refused("\(error)")) }
            connection.cancel()
        case .cancelled:
            end(opened ? .closed(nil, "cancelled") : .refused("cancelled"))
        default:
            break
        }
    }

    private func end(_ event: Event) {
        guard !ended else { return }
        ended = true
        onEvent(event)
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, !self.ended else { return }
            if let error {
                self.end(.closed(nil, "\(error)"))
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .binary, .cont:
                    if let content, !content.isEmpty { self.onEvent(.data(content)) }
                    self.receiveNext()
                case .close:
                    let reason = content.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    self.end(.closed(CloseCodes.number(metadata.closeCode), reason))
                    self.connection.cancel()
                case .text:
                    self.end(.closed(nil, "text frame on the RFB socket"))
                    self.connection.cancel()
                default:
                    self.receiveNext()
                }
            } else if let content {
                self.onEvent(.data(content))
                self.receiveNext()
            } else {
                self.end(.closed(nil, "end of stream"))
            }
        }
    }

    func send(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "rfb", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// 1000 / 1001: a clean close (the bridge hands the lease back). Anything else drops the link
    /// without a close frame, like a lost network: the bridge keeps a held lease.
    func close(code: Int?) {
        guard let code, code == 1000 || code == 1001 else {
            ended = true
            connection.forceCancel()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = CloseCodes.code(code)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.ended = true
            self?.connection.cancel()
        }
    }
}

enum CloseCodes {
    static func number(_ code: NWProtocolWebSocket.CloseCode) -> Int? {
        switch code {
        case .protocolCode(let defined): return Int(defined.rawValue)
        case .applicationCode(let value): return Int(value)
        case .privateCode(let value): return Int(value)
        @unknown default: return nil
        }
    }

    static func code(_ number: Int) -> NWProtocolWebSocket.CloseCode {
        switch number {
        case 4000...4999: return .privateCode(UInt16(number))
        case 3000...3999: return .applicationCode(UInt16(number))
        default: return .protocolCode(NWProtocolWebSocket.CloseCode.Defined(rawValue: UInt16(clamping: number)) ?? .normalClosure)
        }
    }
}
