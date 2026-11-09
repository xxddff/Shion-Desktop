import Testing
@testable import RFB

/// Everything the server sizes is bounded before memory is committed to it.
@Suite struct LimitTests {
    static func rectHeader(_ r: RFBRect, _ encoding: RFBEncoding) -> [UInt8] {
        var out: [UInt8] = []
        out.put(UInt16(r.x)); out.put(UInt16(r.y)); out.put(UInt16(r.width)); out.put(UInt16(r.height))
        out.put(encoding.rawValue)
        return out
    }

    static func isLimit(_ error: any Error) -> Bool {
        if case RFBError.limitExceeded = error { return true }
        return false
    }

    static func isViolation(_ error: any Error) -> Bool {
        if case RFBError.protocolViolation = error { return true }
        return false
    }

    @Test func hugeScreenIsRefusedBeforeAllocating() async {
        // 65535 x 65535 x 4 bytes would be 16 GiB.
        let client = RFBClient(transport: ReplayTransport(ServerScript.handshake(width: 65535, height: 65535).bytes))
        await #expect(performing: { try await client.handshake() }, throws: Self.isLimit)
        let wide = RFBClient(transport: ReplayTransport(ServerScript.handshake(width: 9000, height: 10).bytes))
        await #expect(performing: { try await wide.handshake() }, throws: Self.isLimit)
        // Within limits per side but too many pixels in total.
        var options = RFBOptions()
        options.maxScreenPixels = 100
        let many = RFBClient(transport: ReplayTransport(ServerScript.handshake(width: 20, height: 20).bytes), options: options)
        await #expect(performing: { try await many.handshake() }, throws: Self.isLimit)
    }

    @Test func resizeIsCheckedToo() async {
        var s = ServerScript.handshake(width: 8, height: 8)
        s.update([(RFBRect(x: 0, y: 0, width: 60000, height: 60000), .desktopSize, [])])
        let client = RFBClient(transport: ReplayTransport(s.bytes))
        await #expect(performing: { try await client.run() }, throws: Self.isLimit)
        #expect(await client.framebuffer.width == 8)
    }

    @Test func zrleLengthIsBoundedByTheRect() async {
        // A 1x1 rect claiming 4 GiB of compressed data: refused before anything is read.
        var s = ServerScript.handshake(width: 8, height: 8)
        s.bytes += [0, 0, 0, 1] + Self.rectHeader(RFBRect(x: 0, y: 0, width: 1, height: 1), .zrle)
        s.bytes.put(UInt32.max)
        let client = RFBClient(transport: ReplayTransport(s.bytes))
        await #expect(performing: { try await client.run() }, throws: Self.isLimit)
    }

    @Test func zrleZipBombStopsAtTheLimit() async throws {
        // 100 KB of zeros compress to ~100 bytes; a 1x1 rect may inflate to a few hundred.
        let bomb = try Zlib.compress(Array(repeating: 0, count: 100_000), level: 9)
        var s = ServerScript.handshake(width: 8, height: 8)
        var payload: [UInt8] = []
        payload.put(UInt32(bomb.count))
        payload += bomb
        s.update([(RFBRect(x: 0, y: 0, width: 1, height: 1), .zrle, payload)])
        let client = RFBClient(transport: ReplayTransport(s.bytes))
        await #expect(performing: { try await client.run() }, throws: Self.isLimit)
        #expect(ZRLEDecoder.maxInflated(RFBRect(x: 0, y: 0, width: 1, height: 1)) < 1000)
    }

    @Test func oversizedServerClipboardIsSkipped() async throws {
        let events = EventLog()
        var s = ServerScript.handshake()
        // Classic cut text over 256 KiB: skipped without keeping it, then a Bell proves the
        // stream is still in step.
        s.bytes += [3, 0, 0, 0]
        s.bytes.put(UInt32(300_000))
        s.bytes += Array(repeating: 0x41, count: 300_000)
        // Extended provide that inflates past the limit: dropped.
        let body = try Zlib.compress([0, 0x0F, 0, 0] + Array(repeating: 0x42, count: 1_000_000), level: 9)
        let provide = [0x10, 0, 0, 1] + body
        s.bytes += [3, 0, 0, 0]
        s.bytes.put(Int32(-Int32(provide.count)))
        s.bytes += provide
        s.bytes.append(2)
        let client = RFBClient(transport: ReplayTransport(s.bytes, chunkSizes: [4096]))
        do { try await client.run { e, _ in events.append(e) } } catch RFBError.endOfStream {}
        #expect(events.all == [.bell])
    }

    @Test func longServerStringsAreCut() async throws {
        var s = ServerScript()
        s.bytes += Array("RFB 003.008\n".utf8) + [1, 1]
        s.bytes.put(UInt32(0))
        s.bytes.put(UInt16(8)); s.bytes.put(UInt16(8))
        s.bytes += PixelFormat.bgrx.encoded
        s.bytes.put(UInt32(100_000))
        s.bytes += Array(repeating: 0x6E, count: 100_000)
        s.bytes.append(2)  // a Bell right after: the rest of the name was skipped, not lost
        let client = RFBClient(transport: ReplayTransport(s.bytes))
        let info = try await client.handshake()
        #expect(info.name.utf8.count == RFBClient.maxStringLength)
        let events = EventLog()
        do { try await client.run { e, _ in events.append(e) } } catch RFBError.endOfStream {}
        #expect(events.all.first == .bell)

        var refused = Array("RFB 003.008\n".utf8) + [0]
        refused.put(UInt32(50_000))
        refused += Array(repeating: 0x72, count: 50_000)
        await #expect {
            try await RFBClient(transport: ReplayTransport(refused)).handshake()
        } throws: { error in
            guard case RFBError.connectionRefused(let reason) = error else { return false }
            return reason.utf8.count == RFBClient.maxStringLength
        }
    }

    @Test func cursorIsBounded() async {
        var big = ServerScript.handshake()
        big.bytes += [0, 0, 0, 1] + Self.rectHeader(RFBRect(x: 0, y: 0, width: 4000, height: 4000), .cursor)
        let client = RFBClient(transport: ReplayTransport(big.bytes))
        await #expect(performing: { try await client.run() }, throws: Self.isLimit)

        var hotspot = ServerScript.handshake()
        hotspot.update([(RFBRect(x: 5, y: 0, width: 2, height: 2), .cursor, Array(repeating: 0, count: 2 * 2 * 4 + 2))])
        let other = RFBClient(transport: ReplayTransport(hotspot.bytes))
        await #expect(performing: { try await other.run() }, throws: Self.isViolation)
    }

    @Test func fencePayloadOverSixtyFourBytesIsAProtocolError() async {
        var s = ServerScript.handshake()
        s.fence([.request], Array(repeating: 7, count: 65))
        let client = RFBClient(transport: ReplayTransport(s.bytes))
        await #expect(performing: { try await client.run() }, throws: Self.isViolation)
    }
}
