import CZlib
import Testing
@testable import RFB

/// Hand-built tiles for every ZRLE subencoding (the recordings mostly exercise what Xvnc picks
/// for desktop content; these pin down each branch, including partial edge tiles).
@Suite struct ZRLETests {
    typealias Pixel = (UInt8, UInt8, UInt8)  // r, g, b

    static func cpixel(_ p: Pixel) -> [UInt8] { [p.2, p.1, p.0] }
    static func run(_ n: Int) -> [UInt8] {
        var out: [UInt8] = []
        var left = n - 1
        while left >= 255 { out.append(255); left -= 255 }
        out.append(UInt8(left))
        return out
    }

    /// Decodes one rect (one or more tiles) into a fresh framebuffer and returns its pixels.
    static func decode(_ tiles: [UInt8], width: Int, height: Int) throws -> [[Pixel]] {
        var fb = Framebuffer(width: width, height: height)
        try ZRLEDecoder.decodeTiles(tiles, rect: RFBRect(x: 0, y: 0, width: width, height: height), into: &fb)
        return (0..<height).map { y in (0..<width).map { x in fb.rgb(x: x, y: y) } }
    }

    static func same(_ a: [[Pixel]], _ b: [[Pixel]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { ra, rb in
            ra.count == rb.count && zip(ra, rb).allSatisfy { $0 == $1 }
        }
    }

    let red: Pixel = (255, 0, 0), green: Pixel = (0, 255, 0), blue: Pixel = (0, 0, 255), white: Pixel = (255, 255, 255)

    @Test func rawAndSolid() throws {
        let raw = [0] + [red, green, blue, white].flatMap(Self.cpixel)
        #expect(Self.same(try Self.decode(raw, width: 2, height: 2), [[red, green], [blue, white]]))
        let solid = [1] + Self.cpixel(blue)
        #expect(Self.same(try Self.decode(solid, width: 3, height: 2), Array(repeating: Array(repeating: blue, count: 3), count: 2)))
    }

    @Test func packedPalettes() throws {
        // 2 colours, 1 bit per pixel, each row padded to a byte: width 3.
        let two = [2] + Self.cpixel(red) + Self.cpixel(green) + [0b1010_0000, 0b0100_0000]
        #expect(Self.same(try Self.decode(two, width: 3, height: 2), [[green, red, green], [red, green, red]]))
        // 3 colours, 2 bits: width 5 → 2 bytes per row.
        let three = [3] + [red, green, blue].flatMap(Self.cpixel) + [0b0001_1000, 0b0100_0000]
        #expect(Self.same(try Self.decode(three, width: 5, height: 1), [[red, green, blue, red, green]]))
        // 16 colours, 4 bits.
        var palette: [Pixel] = (0..<16).map { (UInt8($0 * 16), 0, 0) }
        let sixteen = [16] + palette.flatMap(Self.cpixel) + [0xF0, 0x7A]
        palette = [palette[15], palette[0], palette[7], palette[10]]
        #expect(Self.same(try Self.decode(sixteen, width: 4, height: 1), [palette]))
    }

    @Test func plainRLE() throws {
        // A run crossing rows: 5 red over a 3x3 tile, then 4 blue.
        let rle = [128] + Self.cpixel(red) + Self.run(5) + Self.cpixel(blue) + Self.run(4)
        #expect(Self.same(try Self.decode(rle, width: 3, height: 3),
                           [[red, red, red], [red, red, blue], [blue, blue, blue]]))
        // Long run lengths use 255 continuation bytes: 64x64 = 4096 pixels.
        let long = [128] + Self.cpixel(white) + Self.run(4096)
        #expect(try Self.decode(long, width: 64, height: 64).allSatisfy { $0.allSatisfy { $0 == white } })
    }

    @Test func paletteRLE() throws {
        // Palette of 2: index 0 single, index 1 run of 3 (top bit set), index 0 run of 2.
        let tile = [130] + Self.cpixel(red) + Self.cpixel(green) + [0x00, 0x81] + Self.run(3) + [0x80] + Self.run(2)
        #expect(Self.same(try Self.decode(tile, width: 3, height: 2), [[red, green, green], [green, red, red]]))
    }

    @Test func tilesAreSixtyFourSquareInRasterOrder() throws {
        // 70x65: tiles 64x64, 6x64, 64x1, 6x1, each solid in its own colour.
        let colours = [red, green, blue, white]
        let data: [UInt8] = colours.flatMap { [UInt8(1)] + Self.cpixel($0) }
        let px = try Self.decode(data, width: 70, height: 65)
        #expect(px[0][0] == red && px[63][63] == red)
        #expect(px[0][64] == green && px[63][69] == green)
        #expect(px[64][0] == blue && px[64][63] == blue)
        #expect(px[64][64] == white && px[64][69] == white)
    }

    @Test func rejectsBadData() {
        #expect(throws: RFBError.self) { try Self.decode([128] + Self.cpixel(red) + Self.run(10), width: 3, height: 3) }  // run too long
        #expect(throws: RFBError.self) { try Self.decode([130] + Self.cpixel(red) + Self.cpixel(red) + [0x05], width: 1, height: 1) }  // bad index
        #expect(throws: RFBError.self) { try Self.decode([17], width: 1, height: 1) }  // unused subencoding
        #expect(throws: RFBError.self) { try Self.decode([1, 0, 0], width: 1, height: 1) }  // truncated
        #expect(throws: RFBError.self) { try Self.decode([1, 0, 0, 0, 9], width: 1, height: 1) }  // trailing bytes
    }

    /// The zlib stream continues across rects.
    @Test func zlibStreamSpansRects() async throws {
        // Compress two rects' tile data as one stream with a sync flush between them, like Xvnc.
        let first = [1] + Self.cpixel(red)
        let second = [1] + Self.cpixel(blue)
        let (a, b) = try ZlibStream.compressTwo(first, second)
        var s = ServerScript.handshake(width: 2, height: 1)
        var p1: [UInt8] = []; p1.put(UInt32(a.count)); p1 += a
        var p2: [UInt8] = []; p2.put(UInt32(b.count)); p2 += b
        s.update([(RFBRect(x: 0, y: 0, width: 1, height: 1), .zrle, p1), (RFBRect(x: 1, y: 0, width: 1, height: 1), .zrle, p2)])
        let (client, _, _) = try await replay(s.bytes)
        let fb = await client.framebuffer
        #expect(fb.rgb(x: 0, y: 0) == red && fb.rgb(x: 1, y: 0) == blue)
    }
}


/// A deflate stream with a sync flush after each piece (test helper).
enum ZlibStream {
    static func compressTwo(_ a: [UInt8], _ b: [UInt8]) throws -> ([UInt8], [UInt8]) {
        var stream = z_stream()
        guard deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RFBError.zlib(-1)
        }
        defer { deflateEnd(&stream) }
        func piece(_ input: [UInt8]) -> [UInt8] {
            var input = input
            var out = [UInt8](repeating: 0, count: 1024)
            let produced = input.withUnsafeMutableBufferPointer { i in
                out.withUnsafeMutableBufferPointer { o in
                    stream.next_in = i.baseAddress; stream.avail_in = UInt32(i.count)
                    stream.next_out = o.baseAddress; stream.avail_out = UInt32(o.count)
                    deflate(&stream, Z_SYNC_FLUSH)
                    return o.count - Int(stream.avail_out)
                }
            }
            return Array(out[0..<produced])
        }
        return (piece(a), piece(b))
    }
}
