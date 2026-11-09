import Foundation
import RFB

/// A small RFC 6455 client for `ws://` (no TLS), with extra request headers. It exists because
/// Foundation's WebSocket does not work on Linux with the distribution libcurl; on Apple
/// platforms, and for `wss://`, use `URLSessionWebSocketTransport` (what the App uses).
///
/// Binary frames only (a text frame is a protocol error on the RFB socket), answers pings,
/// reports the peer's close code. Messages are sent unfragmented.
public final class PlainWebSocketTransport: RFBTransport, @unchecked Sendable {
    private let socket: POSIXSocket
    private var pump: ReadPump!
    private let state = NSLock()
    private var sentClose = false

    /// The largest message accepted (Hermes' bridge sends at most 64 KiB per frame).
    static let maxMessage = 16 << 20

    /// `url` must be `ws://host[:port]/path?query` (any letter case); with headers, only to a
    /// loopback host (the testbed). Header values are sent, never logged. Connecting and the
    /// upgrade each give up after `timeout` seconds.
    public init(url: URL, headers: [(String, String)] = [], timeout: Double = 15) throws {
        let (secure, url) = try WebSocketURLPolicy.check(url, sendsHeaders: !headers.isEmpty)
        guard !secure, let host = url.host else {
            throw RFBSocketError("PlainWebSocketTransport takes ws:// URLs only (no TLS)")
        }
        let port = UInt16(url.port ?? 80)
        socket = try POSIXSocket(connectingTo: .tcp(host: host, port: port), timeout: timeout)

        var keyBytes = [UInt8](repeating: 0, count: 16)
        for i in keyBytes.indices { keyBytes[i] = UInt8.random(in: 0...255) }
        let key = Data(keyBytes).base64EncodedString()
        var target = url.path.isEmpty ? "/" : url.path
        if let q = url.query { target += "?" + q }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        var request = "GET \(target) HTTP/1.1\r\nHost: \(hostHeader)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        for (name, value) in headers {
            guard !name.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ":" }),
                  !value.contains(where: { $0 == "\r" || $0 == "\n" }) else {
                throw RFBSocketError("invalid header \(name)")
            }
            request += "\(name): \(value)\r\n"
        }
        request += "\r\n"
        try socket.writeAll(Array(request.utf8))

        // Read the response head; anything after it is already frame data.
        var head: [UInt8] = []
        var leftover: [UInt8] = []
        socket.setReadTimeout(timeout)
        while true {
            let chunk: [UInt8]
            do {
                chunk = try socket.read()
            } catch {
                socket.close()
                throw RFBSocketError("no WebSocket upgrade answer within \(Int(timeout)) s")
            }
            if chunk.isEmpty { throw RFBSocketError("connection closed during the WebSocket upgrade") }
            head += chunk
            if let end = head.firstRange(of: [13, 10, 13, 10]) {
                leftover = Array(head[end.upperBound...])
                head = Array(head[..<end.lowerBound])
                break
            }
            if head.count > 64 * 1024 { throw RFBSocketError("oversized upgrade response") }
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        guard status == 101 else {
            socket.close()
            throw RFBError.connectionRefused("WebSocket upgrade answered HTTP \(status)")
        }
        let accept = lines.dropFirst().first { $0.lowercased().hasPrefix("sec-websocket-accept:") }?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        let expected = Data(SHA1.hash(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard accept == expected else {
            socket.close()
            throw RFBSocketError("bad Sec-WebSocket-Accept")
        }

        socket.setReadTimeout(0)
        let s = socket
        let reader = FrameReader(socket: s, initial: leftover)
        reader.onControl = { [weak self] opcode, payload in self?.control(opcode, payload) }
        pump = ReadPump { try reader.nextMessage() }
    }

    public func send(_ bytes: [UInt8]) async throws {
        try socket.writeAll(Self.frame(opcode: 0x2, payload: bytes))
    }

    public func receive() async throws -> [UInt8]? { try await pump.next() }

    public func close(_ code: RFBCloseCode) async {
        if code == .abort {
            socket.close()
            return
        }
        sendClose(code == .normal ? 1000 : 1001)
        // Give the server a moment to answer, then drop the socket.
        try? await Task.sleep(nanoseconds: 200_000_000)
        socket.close()
    }

    private func sendClose(_ code: UInt16) {
        let first = state.withLock { () -> Bool in defer { sentClose = true }; return !sentClose }
        if first { try? socket.writeAll(Self.frame(opcode: 0x8, payload: [UInt8(code >> 8), UInt8(code & 0xFF)])) }
    }

    private func control(_ opcode: UInt8, _ payload: [UInt8]) {
        switch opcode {
        case 0x9: try? socket.writeAll(Self.frame(opcode: 0xA, payload: payload))  // ping → pong
        case 0x8:  // echo the close, as the protocol asks
            let code = payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : 1000
            sendClose(code)
        default: break
        }
    }

    /// A masked client frame.
    static func frame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 {
            out.append(0x80 | UInt8(n))
        } else if n <= 0xFFFF {
            out.append(0x80 | 126); out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF))
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        out += mask
        out.reserveCapacity(out.count + n)
        for (i, b) in payload.enumerated() { out.append(b ^ mask[i & 3]) }
        return out
    }
}

/// Parses server frames into whole binary messages (reassembling fragments).
private final class FrameReader: @unchecked Sendable {
    private let socket: POSIXSocket
    private var buffer: [UInt8]
    private var offset = 0
    var onControl: (@Sendable (UInt8, [UInt8]) -> Void)?

    init(socket: POSIXSocket, initial: [UInt8]) {
        self.socket = socket
        self.buffer = initial
    }

    private func need(_ n: Int) throws -> Bool {
        while buffer.count - offset < n {
            let chunk = try socket.read()
            if chunk.isEmpty { return false }
            if offset > 0 { buffer.removeFirst(offset); offset = 0 }
            buffer += chunk
        }
        return true
    }

    private func take(_ n: Int) -> [UInt8] {
        defer { offset += n }
        return Array(buffer[offset..<offset + n])
    }

    /// The next binary message; nil at EOF without a close frame; throws on a close frame.
    func nextMessage() throws -> [UInt8]? {
        var message: [UInt8] = []
        var inMessage = false
        while true {
            guard try need(2) else { return nil }
            let b0 = buffer[offset], b1 = buffer[offset + 1]
            offset += 2
            let fin = b0 & 0x80 != 0
            let opcode = b0 & 0x0F
            let masked = b1 & 0x80 != 0
            var length = Int(b1 & 0x7F)
            if length == 126 {
                guard try need(2) else { return nil }
                let l = take(2); length = Int(l[0]) << 8 | Int(l[1])
            } else if length == 127 {
                guard try need(8) else { return nil }
                let wide = take(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard wide <= UInt64(PlainWebSocketTransport.maxMessage) else {
                    throw RFBError.protocolViolation("WebSocket frame of \(wide) bytes")
                }
                length = Int(wide)
            }
            guard message.count + length <= PlainWebSocketTransport.maxMessage else {
                throw RFBError.protocolViolation("WebSocket message over \(PlainWebSocketTransport.maxMessage) bytes")
            }
            var mask: [UInt8] = []
            if masked { guard try need(4) else { return nil }; mask = take(4) }
            guard try need(length) else { return nil }
            var payload = take(length)
            if masked { for i in payload.indices { payload[i] ^= mask[i & 3] } }

            switch opcode {
            case 0x8:
                onControl?(opcode, payload)
                let code = payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : nil
                let reason = payload.count > 2 ? String(decoding: payload[2...], as: UTF8.self) : ""
                throw RFBConnectionClosed(code: code, reason: reason)
            case 0x9, 0xA:
                onControl?(opcode, payload)
            case 0x1:
                throw RFBError.protocolViolation("text frame on the RFB socket")
            case 0x2, 0x0:
                guard opcode == 0x2 || inMessage else { throw RFBError.protocolViolation("stray continuation frame") }
                inMessage = true
                message += payload
                if fin { return message }
            default:
                throw RFBError.protocolViolation("WebSocket opcode \(opcode)")
            }
        }
    }
}

/// SHA-1, only for Sec-WebSocket-Accept.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var m = message
        let bitLength = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { m.append(UInt8((bitLength >> UInt64(shift)) & 0xFF)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(m[j]) << 24 | UInt32(m[j + 1]) << 16 | UInt32(m[j + 2]) << 8 | UInt32(m[j + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = x << 1 | x >> 31
            }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
                }
                let t = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = b << 30 | b >> 2; b = a; a = t
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap { v in [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    }
}
