import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A connected stream socket (TCP or Unix) with a background read loop. Blocking I/O on its own
/// thread keeps this simple and portable; it is meant for the probe and tests, not the App.
final class POSIXSocket: @unchecked Sendable {
    enum Address: Sendable {
        case tcp(host: String, port: UInt16)
        case unix(path: String)
    }

    private let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false

    init(connectingTo address: Address, timeout: Double = 15) throws {
        switch address {
        case .tcp(let host, let port):
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            #if canImport(Glibc)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            #else
            hints.ai_socktype = SOCK_STREAM
            #endif
            var info: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, String(port), &hints, &info)
            guard rc == 0, let first = info else {
                throw RFBSocketError("cannot resolve \(host): \(String(cString: gai_strerror(rc)))")
            }
            defer { freeaddrinfo(info) }
            var lastError = "no address"
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            var connected: Int32 = -1
            while let ai = cursor {
                let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
                if s >= 0 {
                    if Self.connectWithTimeout(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen, timeout: timeout) == 0 {
                        connected = s
                        break
                    }
                    lastError = String(cString: strerror(errno))
                    _ = systemClose(s)
                }
                cursor = ai.pointee.ai_next
            }
            guard connected >= 0 else { throw RFBSocketError("cannot connect to \(host):\(port): \(lastError)") }
            fd = connected
            var one: Int32 = 1
            let tcpNoDelay: Int32 = 1  // TCP_NODELAY, the same value on Linux and Darwin
            setsockopt(fd, Int32(IPPROTO_TCP), tcpNoDelay, &one, socklen_t(MemoryLayout<Int32>.size))
        case .unix(let path):
            #if canImport(Glibc)
            let s = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
            #else
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            #endif
            guard s >= 0 else { throw RFBSocketError("socket: \(String(cString: strerror(errno)))") }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            guard bytes.count < capacity else { throw RFBSocketError("socket path too long") }
            withUnsafeMutableBytes(of: &addr.sun_path) { p in
                p.copyBytes(from: bytes)
                p[bytes.count] = 0
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0 else {
                let message = String(cString: strerror(errno))
                _ = systemClose(s)
                throw RFBSocketError("cannot connect to \(path): \(message)")
            }
            fd = s
        }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    deinit { close() }

    /// connect(2) that gives up after `timeout` seconds (errno ETIMEDOUT); 0 on success.
    private static func connectWithTimeout(_ s: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: socklen_t,
                                timeout: Double) -> Int32 {
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(s, F_SETFL, flags) }
        #if canImport(Glibc)
        var rc = Glibc.connect(s, address, length)
        #else
        var rc = Darwin.connect(s, address, length)
        #endif
        guard rc != 0, errno == EINPROGRESS else { return rc }
        var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(max(timeout, 0) * 1000))
        guard ready == 1 else {
            errno = ETIMEDOUT
            return -1
        }
        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(s, SOL_SOCKET, SO_ERROR, &failure, &size)
        if failure != 0 {
            errno = failure
            rc = -1
        } else {
            rc = 0
        }
        return rc
    }

    /// Makes a blocking read give up after `seconds` (0: wait forever).
    func setReadTimeout(_ seconds: Double) {
        var tv = timeval()
        tv.tv_sec = .init(seconds)
        tv.tv_usec = .init((seconds - Double(Int(seconds))) * 1_000_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func writeAll(_ bytes: [UInt8]) throws {
        try writeLock.withLock {
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBytes { p -> Int in
                    #if canImport(Glibc)
                    return Glibc.send(fd, p.baseAddress! + sent, bytes.count - sent, Int32(MSG_NOSIGNAL))
                    #else
                    return Darwin.send(fd, p.baseAddress! + sent, bytes.count - sent, 0)
                    #endif
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw RFBSocketError("send: \(String(cString: strerror(errno)))")
                }
                sent += n
            }
        }
    }

    /// Blocking read of up to `max` bytes; empty at EOF.
    func read(max: Int = 64 * 1024) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, max, 0) }
            if n < 0 {
                if errno == EINTR { continue }
                if stateLock.withLock({ isClosed }) { return [] }
                throw RFBSocketError("recv: \(String(cString: strerror(errno)))")
            }
            return Array(buf[0..<n])
        }
    }

    func close() {
        let first = stateLock.withLock { () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }
        if first {
            shutdown(fd, Int32(SHUT_RDWR))
            _ = systemClose(fd)
        }
    }
}

private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Glibc)
    Glibc.close(fd)
    #else
    Darwin.close(fd)
    #endif
}

/// A socket-level failure of `SocketTransport` / `PlainWebSocketTransport`. Its text names the
/// host and port at most, never a URL path or query.
public struct RFBSocketError: Error, Sendable, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}

/// Runs blocking reads on a dedicated thread and hands chunks to async callers in order.
final class ReadPump: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<[UInt8]?, Error>] = []
    private var waiter: CheckedContinuation<Result<[UInt8]?, Error>, Never>?
    /// EOF or the error that ended the read loop; every later `next()` gets it again.
    private var terminal: Result<[UInt8]?, Error>?

    init(_ read: @escaping @Sendable () throws -> [UInt8]?) {
        let thread = Thread { [weak self] in
            while true {
                let result: Result<[UInt8]?, Error>
                do { result = .success(try read()) } catch { result = .failure(error) }
                guard let self else { return }
                self.deliver(result)
                if case .success(let chunk) = result, chunk != nil { continue }
                return
            }
        }
        thread.name = "rfb-read"
        thread.start()
    }

    private func deliver(_ r: Result<[UInt8]?, Error>) {
        let w = lock.withLock { () -> CheckedContinuation<Result<[UInt8]?, Error>, Never>? in
            if case .success(let chunk) = r, chunk != nil {} else { terminal = r }
            if let w = waiter { waiter = nil; return w }
            queue.append(r)
            return nil
        }
        w?.resume(returning: r)
    }

    /// One caller at a time (the client's actor).
    func next() async throws -> [UInt8]? {
        let r = await withCheckedContinuation { (c: CheckedContinuation<Result<[UInt8]?, Error>, Never>) in
            let ready = lock.withLock { () -> Result<[UInt8]?, Error>? in
                if !queue.isEmpty { return queue.removeFirst() }
                if let terminal { return terminal }
                waiter = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
        return try r.get()
    }
}
