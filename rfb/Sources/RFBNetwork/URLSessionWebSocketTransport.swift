import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RFB

/// RFB over `URLSessionWebSocketTask`: what the App uses for Hermes' `/api/display/ws`, with the
/// Cloudflare Access service-token headers on the upgrade request.
///
/// ```swift
/// var request = URLRequest(url: displayURL)   // wss://host/api/display/ws?display_ticket=…
/// request.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
/// request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
/// let transport = URLSessionWebSocketTransport(request: request)
/// ```
///
/// On Linux, swift-corelibs-foundation implements WebSockets through libcurl, and the libcurl of
/// most distributions (Ubuntu 24.04 included) is built without them; use `PlainWebSocketTransport`
/// there.
public final class URLSessionWebSocketTransport: NSObject, RFBTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var closeInfo: RFBConnectionClosed?
    private var closeWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0

    /// The request's URL is logged nowhere; it carries the single-use ticket.
    public init(request: URLRequest, configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        // A full 1440x900 Raw update is ~5 MB; ZRLE frames are far smaller but leave headroom.
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
    }

    public func send(_ bytes: [UInt8]) async throws {
        do {
            try await task.send(.data(Data(bytes)))
        } catch {
            throw await closed(or: error)
        }
    }

    public func receive() async throws -> [UInt8]? {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw await closed(or: error)
        }
        switch message {
        case .data(let data): return [UInt8](data)
        case .string: throw RFBError.protocolViolation("text frame on the RFB socket")
        @unknown default: throw RFBError.protocolViolation("unknown WebSocket message")
        }
    }

    public func close(_ code: RFBCloseCode) async {
        task.cancel(with: code == .normal ? .normalClosure : .goingAway, reason: nil)
        session.finishTasksAndInvalidate()
    }

    /// The HTTP status of the upgrade response, e.g. 403 when Cloudflare Access refused it.
    public var upgradeStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }

    /// A failed receive/send usually means the server closed; the close code may land on the
    /// delegate a moment after the error, so wait briefly for it. Either way the connection is
    /// over, so the session is let go (it holds this delegate until invalidated).
    private func closed(or error: Error) async -> Error {
        defer { session.finishTasksAndInvalidate() }
        if let info = currentClose() { return info }
        let code = task.closeCode.rawValue
        if code != URLSessionWebSocketTask.CloseCode.invalid.rawValue {
            return RFBConnectionClosed(code: code, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        await waitForClose(timeoutNanoseconds: 500_000_000)
        if let info = currentClose() { return info }
        if let status = upgradeStatus, status != 101 {
            return RFBError.connectionRefused("WebSocket upgrade answered HTTP \(status)")
        }
        return error
    }

    private func currentClose() -> RFBConnectionClosed? { lock.withLock { closeInfo } }

    /// Returns when the delegate reports the close, or after the timeout. Each waiter is resumed
    /// exactly once: whoever removes it from `closeWaiters` (under the lock) resumes it.
    private func waitForClose(timeoutNanoseconds: UInt64) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let id = lock.withLock { () -> Int? in
                if closeInfo != nil { return nil }
                nextWaiter += 1
                closeWaiters[nextWaiter] = c
                return nextWaiter
            }
            guard let id else { return c.resume() }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                let waiter = self.lock.withLock { self.closeWaiters.removeValue(forKey: id) }
                waiter?.resume()
            }
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {}

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let info = RFBConnectionClosed(code: closeCode.rawValue, reason: reason.map { String(decoding: $0, as: UTF8.self) } ?? "")
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            closeInfo = info
            defer { closeWaiters = [:] }
            return Array(closeWaiters.values)
        }
        waiters.forEach { $0.resume() }
    }
}
