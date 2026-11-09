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

    @Test func bridgeCloseCodes() {
        #expect(RFBConnectionClosed(code: 4000).bridgeReason == .controlTaken)
        #expect(RFBConnectionClosed(code: 4401).bridgeReason == .badTicket)
        #expect(RFBConnectionClosed(code: 4001).bridgeReason == .desktopGone)
        #expect(RFBConnectionClosed(code: 1006).bridgeReason == nil)
    }

    @Test func recordingSeesBothDirections() async throws {
        let log = EventLogBytes()
        let replay = ReplayTransport(ServerScript.handshake(width: 2, height: 2, name: "x").bytes, chunkSizes: [5])
        let client = RFBClient(transport: RecordingTransport(replay) { log.add($0, $1) })
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
