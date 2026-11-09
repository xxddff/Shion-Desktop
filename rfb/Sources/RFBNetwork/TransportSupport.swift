import Foundation
import RFB

/// A transport failure, described without anything that could carry a secret. Foundation's
/// errors put the full URL (with the display ticket, or `/api/ws?token=`) in their user info and
/// description, so they are never passed on or printed as they are: only their domain and code.
public struct WebSocketTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    public var domain: String
    public var code: Int
    public var detail: String

    public init(domain: String, code: Int, detail: String = "") {
        self.domain = domain
        self.code = code
        self.detail = detail
    }

    /// From any error: domain and code only, plus the POSIX meaning for POSIX codes.
    public init(_ error: any Error) {
        let ns = error as NSError
        domain = ns.domain
        code = ns.code
        detail = ns.domain == NSPOSIXErrorDomain ? String(cString: strerror(Int32(ns.code))) : ""
    }

    public var description: String {
        "\(domain) error \(code)" + (detail.isEmpty ? "" : " (\(detail))")
    }
}

enum WebSocketURLPolicy {
    /// `ws://` / `wss://` only (in any letter case). Request headers (the Access service token)
    /// never go out in plain text to another machine: plain `ws://` with headers only to loopback,
    /// which the tests and the testbed use.
    static func check(_ url: URL?, sendsHeaders: Bool) throws -> (secure: Bool, url: URL) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
            throw RFBError.refusedToSend("not a ws:// or wss:// URL")
        }
        if scheme == "ws" && sendsHeaders && !isLoopback(url.host) {
            throw RFBError.refusedToSend("request headers over plain ws:// to a remote host")
        }
        return (scheme == "wss", url)
    }

    static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}

/// Messages a transport received, waiting for `receive()`. The first terminal result (EOF or an
/// error) is kept and handed to every later call. Above `highWater` queued bytes the producer is
/// told to pause, and `onDrain` asks it to go on once the consumer caught up; so a receive is
/// always pending (a close frame is read the moment it arrives) without the queue growing
/// without bound.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[UInt8]] = []
    private var head = 0
    private var queuedBytes = 0
    private var paused = false
    private var terminal: Result<[UInt8]?, Error>?
    private var waiter: CheckedContinuation<Result<[UInt8]?, Error>, Never>?
    private let highWater: Int
    /// Called (outside the lock) when a paused producer may receive again.
    var onDrain: (@Sendable () -> Void)?

    init(highWater: Int = 8 << 20) {
        self.highWater = highWater
    }

    /// Producer. Returns false when it should stop receiving until `onDrain`.
    func push(_ message: [UInt8]) -> Bool {
        let (w, keepGoing) = lock.withLock { () -> (CheckedContinuation<Result<[UInt8]?, Error>, Never>?, Bool) in
            if terminal != nil { return (nil, false) }
            if let w = waiter {
                waiter = nil
                return (w, true)
            }
            queue.append(message)
            queuedBytes += message.count
            if queuedBytes > highWater { paused = true }
            return (nil, !paused)
        }
        w?.resume(returning: .success(message))
        return keepGoing
    }

    /// Producer: the stream ended (`nil`) or failed. Only the first terminal result counts.
    func finish(_ result: Result<[UInt8]?, Error>) {
        let w = lock.withLock { () -> CheckedContinuation<Result<[UInt8]?, Error>, Never>? in
            guard terminal == nil else { return nil }
            terminal = result
            defer { waiter = nil }
            return waiter
        }
        w?.resume(returning: result)
    }

    var isFinished: Bool { lock.withLock { terminal != nil } }

    /// Consumer (one at a time).
    func next() async throws -> [UInt8]? {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Result<[UInt8]?, Error>, Never>) in
            let ready = lock.withLock { () -> (Result<[UInt8]?, Error>?, Bool) in
                if head < queue.count {
                    let message = queue[head]
                    head += 1
                    queuedBytes -= message.count
                    if head > 64 && head * 2 > queue.count {
                        queue.removeFirst(head)
                        head = 0
                    }
                    var drained = false
                    if paused && queuedBytes <= highWater / 2 {
                        paused = false
                        drained = true
                    }
                    return (.success(message), drained)
                }
                if let terminal { return (terminal, false) }
                waiter = c
                return (nil, false)
            }
            if let message = ready.0 {
                if ready.1 { onDrain?() }
                c.resume(returning: message)
            }
        }
        return try result.get()
    }
}
