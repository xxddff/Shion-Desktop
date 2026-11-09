import Foundation
import Testing
@testable import RFB
@testable import RFBNetwork

@Suite struct TransportTests {
    @Test func sha1() {
        func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
        #expect(hex(SHA1.hash([])) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(hex(SHA1.hash(Array("abc".utf8))) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        // RFC 6455's example handshake.
        let accept = Data(SHA1.hash(Array("dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11".utf8))).base64EncodedString()
        #expect(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func clientFramesAreMasked() {
        for n in [0, 5, 125, 126, 70000] {
            let payload = (0..<n).map { UInt8($0 & 0xFF) }
            let frame = PlainWebSocketTransport.frame(opcode: 2, payload: payload)
            #expect(frame[0] == 0x82)
            #expect(frame[1] & 0x80 != 0)
            let header = n < 126 ? 2 : n <= 0xFFFF ? 4 : 10
            let mask = Array(frame[header..<header + 4])
            let unmasked = frame[(header + 4)...].enumerated().map { $0.element ^ mask[$0.offset & 3] }
            #expect(unmasked == payload)
        }
    }

    @Test func foundationErrorsLoseTheirURL() {
        let secretURL = "wss://hermes.example/api/display/ws?display_ticket=SECRET-TICKET"
        let error = NSError(domain: NSURLErrorDomain, code: -1011, userInfo: [
            "NSErrorFailingURLStringKey": secretURL,
            NSLocalizedDescriptionKey: "bad response from \(secretURL)",
        ])
        let clean = WebSocketTransportError(error)
        #expect(clean.code == -1011)
        #expect(!clean.description.contains("SECRET"))
        #expect(!"\(clean)".contains("SECRET"))
        let posix = WebSocketTransportError(NSError(domain: NSPOSIXErrorDomain, code: 57))
        #expect(posix.description.contains("57") && !posix.detail.isEmpty)
    }

    @Test func plainTextHeadersOnlyToLoopback() throws {
        let remote = URL(string: "ws://hermes.example/api/display/ws?display_ticket=x")!
        #expect(throws: RFBError.self) { try WebSocketURLPolicy.check(remote, sendsHeaders: true) }
        #expect(try WebSocketURLPolicy.check(remote, sendsHeaders: false).secure == false)
        #expect(try WebSocketURLPolicy.check(URL(string: "WSS://hermes.example/x")!, sendsHeaders: true).secure)
        #expect(try WebSocketURLPolicy.check(URL(string: "WS://127.0.0.1:8765/x")!, sendsHeaders: true).secure == false)
        #expect(try WebSocketURLPolicy.check(URL(string: "ws://[::1]:8765/x")!, sendsHeaders: true).secure == false)
        #expect(try WebSocketURLPolicy.check(URL(string: "ws://localhost/x")!, sendsHeaders: true).secure == false)
        #expect(throws: RFBError.self) { try WebSocketURLPolicy.check(URL(string: "https://hermes.example/x")!, sendsHeaders: false) }
        // The transports apply it.
        #expect(throws: RFBError.self) {
            try PlainWebSocketTransport(url: remote, headers: [("CF-Access-Client-Id", "x")])
        }
    }

    /// A server frame claiming 2^63 bytes (the top bit set) must not trap or allocate.
    @Test(.enabled(if: ScriptServer.python != nil, "python3 not found"))
    func plainClientRefusesHugeFrames() async throws {
        let server = try ScriptServer(ScriptServer.upgradeThen("c.sendall(bytes([0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0]))"))
        defer { server.stop() }
        let transport = try PlainWebSocketTransport(url: URL(string: "ws://127.0.0.1:\(server.port)/")!)
        await #expect(throws: RFBError.self) { _ = try await transport.receive() }
    }

    /// A server that accepts the connection but never answers the upgrade.
    @Test(.enabled(if: ScriptServer.python != nil, "python3 not found"))
    func plainClientGivesUpOnASilentServer() throws {
        let server = try ScriptServer("c, _ = s.accept()\ntime.sleep(10)")
        defer { server.stop() }
        let started = Date()
        #expect(throws: RFBSocketError.self) {
            try PlainWebSocketTransport(url: URL(string: "ws://127.0.0.1:\(server.port)/")!, timeout: 1)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func bridgeCloseCodes() {
        #expect(RFBConnectionClosed(code: 4000).bridgeReason == .controlTaken)
        #expect(RFBConnectionClosed(code: 4401).bridgeReason == .badTicket)
        #expect(RFBConnectionClosed(code: 4001).bridgeReason == .desktopGone)
        #expect(RFBConnectionClosed(code: 1006).bridgeReason == nil)
    }

    @Test func recordingSeesBothDirections() async throws {
        let log = EventLogBytes()
        let replay = ReplayTransport(ServerScript.handshake(width: 2, height: 2, name: "x").bytes, chunkSizes: [5])
        var options = RFBOptions()
        options.pipelineHandshake = false
        let client = RFBClient(transport: RecordingTransport(replay) { log.add($0, $1) }, options: options)
        let info = try await client.handshake()
        #expect(info.name == "x" && info.width == 2)
        #expect(log.received == ServerScript.handshake(width: 2, height: 2, name: "x").bytes)
        #expect(log.sent == Array("RFB 003.008\n".utf8) + [1, 1])
    }
}

final class EventLogBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var r: [UInt8] = [], s: [UInt8] = []
    func add(_ d: RecordingTransport.Direction, _ b: [UInt8]) { lock.withLock { if d == .received { r += b } else { s += b } } }
    var received: [UInt8] { lock.withLock { r } }
    var sent: [UInt8] { lock.withLock { s } }
}

/// A throwaway TCP server in python3 (standard library only): listens on a free loopback port,
/// prints it, then runs `body` with the listening socket `s`.
final class ScriptServer: @unchecked Sendable {
    static var python: String? { BridgeFilterTests.python }

    /// Accepts one connection as `c`, answers its WebSocket upgrade, then runs `then`.
    static func upgradeThen(_ then: String) -> String {
        """
        c, _ = s.accept()
        data = b""
        while b"\\r\\n\\r\\n" not in data:
            data += c.recv(4096)
        key = [l.split(b":", 1)[1].strip() for l in data.split(b"\\r\\n") if l.lower().startswith(b"sec-websocket-key:")][0]
        accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        c.sendall(b"HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\nSec-WebSocket-Accept: " + accept + b"\\r\\n\\r\\n")
        \(then)
        time.sleep(10)
        """
    }

    private let process = Process()
    private let output = Pipe()
    let port: Int

    init(_ body: String) throws {
        let script = """
        import base64, hashlib, signal, socket, time
        signal.pthread_sigmask(signal.SIG_SETMASK, [])
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        print("port", s.getsockname()[1], flush=True)

        """ + body
        process.executableURL = URL(fileURLWithPath: Self.python!)
        process.arguments = ["-I", "-B", "-c", script]
        process.standardOutput = output
        try process.run()
        // The first line is all we need; read it directly.
        var line = Data()
        let handle = output.fileHandleForReading
        while !line.contains(0x0A) {
            let chunk = handle.readData(ofLength: 1)
            if chunk.isEmpty { break }
            line += chunk
        }
        let text = String(decoding: line, as: UTF8.self)
        guard text.hasPrefix("port "), let port = Int(text.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate()
            throw RFBSocketError("script server did not start")
        }
        self.port = port
    }

    func stop() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
