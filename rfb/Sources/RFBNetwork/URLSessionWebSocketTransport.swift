import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RFB

/// RFB over `URLSessionWebSocketTask`, with the Cloudflare Access headers on the upgrade request.
/// What the App uses.
///
/// A receive is always pending (into a bounded queue). That is what makes the server's close
/// code come through: on macOS, a close started by the server (Hermes' 4000 "control taken")
/// with no receive pending showed up only as "socket is not connected" and `closeCode` stayed 0;
/// with one pending, `didCloseWith` reports 4000 (CI, 2026-11-09).
///
/// ```swift
/// var request = URLRequest(url: displayURL)   // wss://host/api/display/ws?display_ticket=…
/// request.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
/// request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
/// let transport = try URLSessionWebSocketTransport(request: request)
/// ```
///
/// Errors come out as `WebSocketTransportError` (domain and code) or `RFBConnectionClosed`, never
/// as Foundation's own errors, whose descriptions carry the URL and so the ticket. Redirects are
/// refused, so the ticket and the Access headers only go to the host asked for.
///
/// On Linux, swift-corelibs-foundation implements WebSockets through libcurl, and the libcurl of
/// most distributions (Ubuntu 24.04 included) is built without them; use `PlainWebSocketTransport`
/// there.
public final class URLSessionWebSocketTransport: NSObject, RFBTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private let inbox = Inbox()
    private var closeInfo: RFBConnectionClosed?
    private var closeWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0
    /// The task finished (didCompleteWithError); nothing more will arrive.
    private var completed = false
    private let log: (@Sendable (String) -> Void)?

    /// The request's URL is logged nowhere; it carries the single-use ticket. Throws for a URL
    /// that is not `ws://` / `wss://`, or for headers over plain `ws://` to another machine.
    /// `log` hears close codes and errors (for debugging; no secrets).
    public init(request: URLRequest, configuration: URLSessionConfiguration = .ephemeral,
                log: (@Sendable (String) -> Void)? = nil) throws {
        _ = try WebSocketURLPolicy.check(request.url, sendsHeaders: !(request.allHTTPHeaderFields ?? [:]).isEmpty)
        self.log = log
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        // A full 1440x900 Raw update is ~5 MB; ZRLE frames are far smaller but leave headroom.
        task.maximumMessageSize = 64 * 1024 * 1024
        inbox.onDrain = { [weak self] in self?.receiveNext() }
        task.resume()
        receiveNext()
    }

    /// Keeps one receive pending, so a close frame is taken in as soon as it arrives.
    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                if self.inbox.push([UInt8](data)) { self.receiveNext() }
            case .success(.string):
                self.inbox.finish(.failure(RFBError.protocolViolation("text frame on the RFB socket")))
            case .success:
                self.inbox.finish(.failure(RFBError.protocolViolation("unknown WebSocket message")))
            case .failure(let error):
                Task { self.inbox.finish(.failure(await self.closed(or: error))) }
            }
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        do {
            try await task.send(.data(Data(bytes)))
        } catch {
            throw await closed(or: error)
        }
    }

    public func receive() async throws -> [UInt8]? {
        try await inbox.next()
    }

    public func close(_ code: RFBCloseCode) async {
        switch code {
        case .normal: task.cancel(with: .normalClosure, reason: nil)
        case .goingAway: task.cancel(with: .goingAway, reason: nil)
        case .abort: task.cancel()  // no close code of ours; prefer NWWebSocketTransport for a hard drop
        }
        session.finishTasksAndInvalidate()
    }

    /// The HTTP status of the upgrade response, e.g. 403 when Cloudflare Access refused it.
    public var upgradeStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }

    /// A failed receive/send usually means the server closed; the close code may land on the
    /// delegate a moment after the error, so wait briefly for it. Either way the connection is
    /// over, so the session is let go (it holds this delegate until invalidated). Never returns
    /// Foundation's error itself: its description carries the URL.
    private func closed(or error: Error) async -> Error {
        defer { session.finishTasksAndInvalidate() }
        let clean = WebSocketTransportError(error)
        log?("receive/send failed: \(clean); closeCode now \(task.closeCode.rawValue)")
        if let info = currentClose() { return info }
        let code = task.closeCode.rawValue
        if code != URLSessionWebSocketTask.CloseCode.invalid.rawValue {
            return RFBConnectionClosed(code: code, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        await waitForClose(timeoutNanoseconds: 1_000_000_000)
        if let info = currentClose() { return info }
        let late = task.closeCode.rawValue
        if late != URLSessionWebSocketTask.CloseCode.invalid.rawValue {
            return RFBConnectionClosed(code: late, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        if let status = upgradeStatus, status != 101 {
            return RFBError.connectionRefused("WebSocket upgrade answered HTTP \(status)")
        }
        return RFBConnectionClosed(code: nil, reason: clean.description)
    }

    private func currentClose() -> RFBConnectionClosed? { lock.withLock { closeInfo } }

    /// Returns when the delegate reports the close, or after the timeout. Each waiter is resumed
    /// exactly once: whoever removes it from `closeWaiters` (under the lock) resumes it.
    private func waitForClose(timeoutNanoseconds: UInt64) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let id = lock.withLock { () -> Int? in
                if closeInfo != nil || completed { return nil }
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

    private func wakeCloseWaiters(_ update: () -> Void) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            update()
            defer { closeWaiters = [:] }
            return Array(closeWaiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {}

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        log?("didCloseWith \(closeCode.rawValue)")
        let info = RFBConnectionClosed(code: closeCode.rawValue, reason: reason.map { String(decoding: $0, as: UTF8.self) } ?? "")
        wakeCloseWaiters { closeInfo = info }
    }

    /// The task is over. If a close frame came in, its code may only be readable now.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let ws = task as? URLSessionWebSocketTask
        log?("didCompleteWithError \(error.map { "\(WebSocketTransportError($0))" } ?? "nil"); closeCode \(ws?.closeCode.rawValue ?? -1)")
        var info: RFBConnectionClosed?
        if let ws, ws.closeCode.rawValue != URLSessionWebSocketTask.CloseCode.invalid.rawValue {
            info = RFBConnectionClosed(code: ws.closeCode.rawValue,
                                       reason: ws.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        wakeCloseWaiters {
            completed = true
            if closeInfo == nil, let info { closeInfo = info }
        }
    }

    /// Never follow a redirect: the ticket and the Access headers stay with the host asked for.
    #if canImport(Darwin)
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    #else
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    #endif
}
