/// ZRLE (RFC 6143 §7.7.6) for our fixed pixel format, where a CPIXEL is 3 bytes (B, G, R).
///
/// The zlib stream lives as long as the connection, so one decoder per client.
final class ZRLEDecoder {
    private let inflater: Inflater
    static let tileSize = 64

    init() throws {
        inflater = try Inflater()
    }

    /// `compressed` is the rect's zlib data (after its u32 length).
    func decode(_ compressed: [UInt8], rect r: RFBRect, into fb: inout Framebuffer) throws {
        try fb.check(r)
        let data = try inflater.inflate(compressed, sizeHint: r.width * r.height * 3 + 1024)
        try Self.decodeTiles(data, rect: r, into: &fb)
    }

    static func decodeTiles(_ data: [UInt8], rect r: RFBRect, into fb: inout Framebuffer) throws {
        let stride = fb.bytesPerRow
        let count = data.count
        try data.withUnsafeBufferPointer { src in
            try fb.pixels.withUnsafeMutableBufferPointer { dst in
                var i = 0
                @inline(__always) func need(_ n: Int) throws {
                    if i + n > count { throw RFBError.protocolViolation("ZRLE data truncated") }
                }
                @inline(__always) func cpixel() throws -> UInt32 {
                    try need(3)
                    defer { i += 3 }
                    return UInt32(src[i]) | UInt32(src[i + 1]) << 8 | UInt32(src[i + 2]) << 16 | 0xFF00_0000
                }
                @inline(__always) func put(_ px: UInt32, _ o: Int) {
                    dst[o] = UInt8(px & 0xFF)
                    dst[o + 1] = UInt8((px >> 8) & 0xFF)
                    dst[o + 2] = UInt8((px >> 16) & 0xFF)
                    dst[o + 3] = 0xFF
                }
                @inline(__always) func runLength() throws -> Int {
                    var length = 1
                    while true {
                        try need(1)
                        let b = Int(src[i]); i += 1
                        length += b
                        if b != 255 { return length }
                    }
                }
                var palette = [UInt32](repeating: 0, count: 128)

                var ty = r.y
                while ty < r.y + r.height {
                    let th = min(tileSize, r.y + r.height - ty)
                    var tx = r.x
                    while tx < r.x + r.width {
                        let tw = min(tileSize, r.x + r.width - tx)
                        try need(1)
                        let sub = Int(src[i]); i += 1
                        let origin = ty * stride + tx * 4
                        switch sub {
                        case 0: // raw CPIXELs
                            for row in 0..<th {
                                var o = origin + row * stride
                                for _ in 0..<tw { put(try cpixel(), o); o += 4 }
                            }
                        case 1: // solid
                            let px = try cpixel()
                            for row in 0..<th {
                                var o = origin + row * stride
                                for _ in 0..<tw { put(px, o); o += 4 }
                            }
                        case 2...16: // packed palette
                            let size = sub
                            for k in 0..<size { palette[k] = try cpixel() }
                            let bits = size == 2 ? 1 : size <= 4 ? 2 : 4
                            let mask = (1 << bits) - 1
                            for row in 0..<th {
                                var o = origin + row * stride
                                var byte = 0, left = 0
                                for _ in 0..<tw {
                                    if left == 0 {
                                        try need(1)
                                        byte = Int(src[i]); i += 1
                                        left = 8
                                    }
                                    left -= bits
                                    let index = (byte >> left) & mask
                                    guard index < size else { throw RFBError.protocolViolation("ZRLE palette index") }
                                    put(palette[index], o); o += 4
                                }
                            }
                        case 128: // plain RLE
                            var row = 0, col = 0
                            while row < th {
                                let px = try cpixel()
                                var n = try runLength()
                                guard n <= (th - row) * tw - col else { throw RFBError.protocolViolation("ZRLE run too long") }
                                while n > 0 {
                                    put(px, origin + row * stride + col * 4)
                                    n -= 1; col += 1
                                    if col == tw { col = 0; row += 1 }
                                }
                            }
                        case 130...255: // palette RLE
                            let size = sub - 128
                            for k in 0..<size { palette[k] = try cpixel() }
                            var row = 0, col = 0
                            while row < th {
                                try need(1)
                                let b = Int(src[i]); i += 1
                                let index = b & 0x7F
                                guard index < size else { throw RFBError.protocolViolation("ZRLE palette index") }
                                var n = b & 0x80 != 0 ? try runLength() : 1
                                guard n <= (th - row) * tw - col else { throw RFBError.protocolViolation("ZRLE run too long") }
                                let px = palette[index]
                                while n > 0 {
                                    put(px, origin + row * stride + col * 4)
                                    n -= 1; col += 1
                                    if col == tw { col = 0; row += 1 }
                                }
                            }
                        default:
                            throw RFBError.protocolViolation("ZRLE subencoding \(sub)")
                        }
                        tx += tileSize
                    }
                    ty += tileSize
                }
                if i != count { throw RFBError.protocolViolation("ZRLE: \(count - i) bytes left over") }
            }
        }
    }
}
