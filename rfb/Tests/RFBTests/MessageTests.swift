import Foundation
import Testing
@testable import RFB

@Suite struct MessageTests {
    @Test func fixedLayouts() throws {
        #expect(try ClientMessage.setPixelFormat(.bgrx).encoded() ==
                [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        #expect(try ClientMessage.setEncodings([.zrle, .desktopSize, .extendedClipboard]).encoded() ==
                [2, 0, 0, 3, 0, 0, 0, 16, 0xFF, 0xFF, 0xFF, 0x21, 0xC0, 0xA1, 0xE5, 0xCE])
        #expect(try ClientMessage.framebufferUpdateRequest(incremental: true, x: 1, y: 2, width: 1440, height: 900).encoded() ==
                [3, 1, 0, 1, 0, 2, 0x05, 0xA0, 0x03, 0x84])
        #expect(try ClientMessage.keyEvent(down: true, keysym: 0xFF0D).encoded() == [4, 1, 0, 0, 0, 0, 0xFF, 0x0D])
        #expect(try ClientMessage.keyEvent(down: false, keysym: 0x61).encoded() == [4, 0, 0, 0, 0, 0, 0, 0x61])
        #expect(try ClientMessage.pointerEvent(buttons: [.left, .wheelDown], x: 300, y: 2).encoded() ==
                [5, 0x11, 0x01, 0x2C, 0, 2])
        #expect(try ClientMessage.clientCutText(latin1: Array("hé".utf8)).encoded() == [6, 0, 0, 0, 0, 0, 0, 3, 0x68, 0xC3, 0xA9])
        #expect(try ClientMessage.enableContinuousUpdates(enable: true, x: 0, y: 0, width: 800, height: 500).encoded() ==
                [150, 1, 0, 0, 0, 0, 0x03, 0x20, 0x01, 0xF4])
        #expect(try ClientMessage.fence(flags: [.blockBefore], payload: [9, 8]).encoded() ==
                [248, 0, 0, 0, 0, 0, 0, 1, 2, 9, 8])
    }

    @Test func clipboardSizeLimit() throws {
        let max = ClientMessage.maxCutText
        #expect(throws: Never.self) { try ClientMessage.clientCutText(latin1: Array(repeating: 0x41, count: max)).encoded() }
        #expect(throws: RFBError.self) { try ClientMessage.clientCutText(latin1: Array(repeating: 0x41, count: max + 1)).encoded() }
        // Extended: the uncompressed text (with CRLF and the NUL) must fit too, not only the
        // compressed message: Xvnc's -MaxCutText applies to both.
        let fits = String(repeating: "a", count: max - 1)
        #expect(throws: Never.self) { try ClientMessage.extendedClipboard(.provide(text: fits)).encoded() }
        let tooLong = String(repeating: "a", count: max)
        #expect(throws: RFBError.self) { try ClientMessage.extendedClipboard(.provide(text: tooLong)).encoded() }
        let lines = String(repeating: "\n", count: max / 2)  // each LF becomes CRLF
        #expect(throws: RFBError.self) { try ClientMessage.extendedClipboard(.provide(text: lines)).encoded() }
    }

    @Test func extendedClipboardProvideRoundTrip() throws {
        let text = "你好，世界\nこんにちは 👋\r\nend"
        let wire = try ClientMessage.extendedClipboard(.provide(text: text)).encoded()
        #expect(wire[0] == 6)
        let length = Int32(bitPattern: UInt32(wire[4]) << 24 | UInt32(wire[5]) << 16 | UInt32(wire[6]) << 8 | UInt32(wire[7]))
        #expect(length < 0 && Int(-length) == wire.count - 8)
        let decoded = try ExtendedClipboardMessage.decode(Array(wire[8...]))
        #expect(decoded.action == .provide)
        #expect(decoded.text == "你好，世界\nこんにちは 👋\nend")
        // On the wire: CRLF line endings, trailing NUL.
        #expect(ExtendedClipboardMessage.wireText("a\nb\r\nc") == Array("a\r\nb\r\nc\0".utf8))
    }

    @Test func extendedClipboardControlMessages() throws {
        // Exactly what Xvnc 1.13 sent in the recording: caps with text, request/peek/notify/provide, max 0.
        let caps = try ExtendedClipboardMessage.decode([0x1F, 0x00, 0x00, 0x01, 0, 0, 0, 0])
        #expect(caps.action == .caps)
        #expect(caps.formats == .text)
        #expect(caps.supportedActions == [.request, .peek, .notify, .provide])
        #expect(caps.maxSizes == [0])
        #expect(try ExtendedClipboardMessage.notify(.text).encoded() == [0x08, 0, 0, 1])
        #expect(try ExtendedClipboardMessage.request(.text).encoded() == [0x02, 0, 0, 1])
        #expect(try RFBClient.clientClipboardCaps.encoded() == [0x1B, 0, 0, 1, 0, 4, 0, 0])
    }
}

/// A server byte stream built by hand.
struct ServerScript {
    var bytes: [UInt8] = []

    static func handshake(width: UInt16 = 64, height: UInt16 = 64, name: String = "test") -> ServerScript {
        var s = ServerScript()
        s.bytes += Array("RFB 003.008\n".utf8)
        s.bytes += [1, 1]          // one security type: None
        s.bytes.put(UInt32(0))    // SecurityResult OK
        s.bytes.put(width); s.bytes.put(height)
        s.bytes += PixelFormat.bgrx.encoded
        s.bytes.put(UInt32(name.utf8.count)); s.bytes += Array(name.utf8)
        return s
    }

    mutating func update(_ rects: [(RFBRect, RFBEncoding, [UInt8])]) {
        bytes += [0, 0]; bytes.put(UInt16(rects.count))
        for (r, e, payload) in rects {
            bytes.put(UInt16(r.x)); bytes.put(UInt16(r.y)); bytes.put(UInt16(r.width)); bytes.put(UInt16(r.height))
            bytes.put(e.rawValue)
            bytes += payload
        }
    }

    mutating func fence(_ flags: FenceFlags, _ payload: [UInt8]) {
        bytes += [248, 0, 0, 0]; bytes.put(flags.rawValue); bytes.append(UInt8(payload.count)); bytes += payload
    }
}

@Suite struct ProtocolTests {
    @Test func answersFenceRequests() async throws {
        var s = ServerScript.handshake()
        s.fence([.request, .blockBefore, .syncNext], [1, 2, 3])
        s.fence([.blockAfter], [4])  // an answer, not a request: ignored
        let (client, transport, _) = try await replay(s.bytes)
        let fences = transport.sent.filter { $0.first == 248 }
        #expect(fences == [[248, 0, 0, 0, 0, 0, 0, 1, 3, 1, 2, 3]])
        #expect(await client.statistics.fencesAnswered == 1)
    }

    @Test func enablesContinuousUpdatesOnlyWhenOffered() async throws {
        var s = ServerScript.handshake(width: 10, height: 20)
        s.bytes.append(150)  // EndOfContinuousUpdates: "supported"
        let (_, transport, events) = try await replay(s.bytes)
        #expect(transport.sent.contains([150, 1, 0, 0, 0, 0, 0, 10, 0, 20]))
        #expect(events == [.continuousUpdates(true)])

        var off = RFBOptions()
        off.continuousUpdates = false
        let (_, quiet, _) = try await replay(s.bytes, options: off)
        #expect(!quiet.sent.contains { $0.first == 150 })
    }

    @Test func refusesWhatItCannotSpeak() async throws {
        await #expect(throws: RFBError.unsupportedVersion("RFB 003.003")) {
            _ = try await RFBClient(transport: ReplayTransport(Array("RFB 003.003\n".utf8))).handshake()
        }
        var refused = Array("RFB 003.008\n".utf8) + [0]
        refused.put(UInt32(4)); refused += Array("busy".utf8)
        await #expect(throws: RFBError.connectionRefused("busy")) {
            _ = try await RFBClient(transport: ReplayTransport(refused)).handshake()
        }
        await #expect(throws: RFBError.unsupportedSecurity([2, 19])) {
            _ = try await RFBClient(transport: ReplayTransport(Array("RFB 003.008\n".utf8) + [2, 2, 19])).handshake()
        }
    }

    @Test func rawCopyRectAndLastRect() async throws {
        var s = ServerScript.handshake(width: 4, height: 3)
        var raw: [UInt8] = []
        for i in 0..<12 { raw += [UInt8(i), UInt8(i * 2), UInt8(i * 3), 0] }
        s.update([(RFBRect(x: 0, y: 0, width: 4, height: 3), .raw, raw)])
        // Overlapping copy one pixel to the right, then LastRect ends a 0xFFFF-count update.
        var copy: [UInt8] = []; copy.put(UInt16(0)); copy.put(UInt16(0))
        s.bytes += [0, 0, 0xFF, 0xFF]
        for (r, e, p) in [(RFBRect(x: 1, y: 0, width: 3, height: 3), RFBEncoding.copyRect, copy),
                          (RFBRect(x: 0, y: 0, width: 0, height: 0), .lastRect, [])] {
            s.bytes.put(UInt16(r.x)); s.bytes.put(UInt16(r.y)); s.bytes.put(UInt16(r.width)); s.bytes.put(UInt16(r.height))
            s.bytes.put(e.rawValue); s.bytes += p
        }
        s.bytes.append(2)  // Bell after the update: proves we found the boundary
        let (client, _, events) = try await replay(s.bytes)
        let fb = await client.framebuffer
        // Row 0 was pixels 0,1,2,3; after copying x 0..2 to 1..3 it is 0,0,1,2.
        #expect((0..<4).map { fb.rgb(x: $0, y: 0).2 } == [0, 0, 1, 2])
        #expect((0..<4).map { fb.rgb(x: $0, y: 2).2 } == [8, 8, 9, 10])
        #expect(events.last == .bell)
        #expect(events.filter { if case .framebufferUpdated = $0 { true } else { false } }.count == 2)
    }

    @Test func copyRectOverlapEveryDirection() throws {
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (2, 2), (-2, -1)] {
            var fb = Framebuffer(width: 8, height: 8)
            for y in 0..<8 { for x in 0..<8 { fb.pixels[(y * 8 + x) * 4] = UInt8(y * 8 + x) } }
            let original = fb
            let src = (x: 2, y: 2)
            let r = RFBRect(x: src.x + dx, y: src.y + dy, width: 4, height: 4)
            try fb.copy(from: src.x, src.y, to: r)
            for y in 0..<4 { for x in 0..<4 {
                #expect(fb.pixels[((r.y + y) * 8 + r.x + x) * 4] == original.pixels[((src.y + y) * 8 + src.x + x) * 4])
            } }
        }
    }

    @Test func rejectsRectsOutsideTheScreen() async throws {
        var s = ServerScript.handshake(width: 4, height: 4)
        s.update([(RFBRect(x: 2, y: 2, width: 4, height: 4), .raw, Array(repeating: 0, count: 64))])
        await #expect(throws: RFBError.self) {
            try await RFBClient(transport: ReplayTransport(s.bytes)).run()
        }
    }

    @Test func pointerIsClampedToTheScreen() async throws {
        let transport = ReplayTransport(ServerScript.handshake(width: 100, height: 50).bytes)
        let client = RFBClient(transport: transport)
        try await client.handshake()
        try await client.sendPointer(x: 500, y: -3, buttons: .right)
        try await client.sendScroll(x: 10, y: 10, direction: .wheelUp)
        #expect(transport.sent.suffix(3) == [[5, 4, 0, 99, 0, 0], [5, 8, 0, 10, 0, 10], [5, 0, 0, 10, 0, 10]])
    }
}
