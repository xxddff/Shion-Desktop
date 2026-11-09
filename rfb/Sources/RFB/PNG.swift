/// A minimal PNG writer (8-bit RGB, no filtering), for the probe and for looking at test output.
public enum PNG {
    public static func encode(_ fb: Framebuffer) throws -> [UInt8] {
        var raw: [UInt8] = []
        raw.reserveCapacity((fb.width * 3 + 1) * fb.height)
        fb.pixels.withUnsafeBufferPointer { p in
            for y in 0..<fb.height {
                raw.append(0)  // filter: none
                var o = y * fb.bytesPerRow
                for _ in 0..<fb.width {
                    raw.append(p[o + 2]); raw.append(p[o + 1]); raw.append(p[o])
                    o += 4
                }
            }
        }
        var ihdr: [UInt8] = []
        ihdr.put(UInt32(fb.width)); ihdr.put(UInt32(fb.height))
        ihdr += [8, 2, 0, 0, 0]  // 8-bit, truecolour RGB, deflate, no filter method, no interlace
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        chunk("IHDR", ihdr, into: &out)
        chunk("IDAT", try Zlib.compress(raw), into: &out)
        chunk("IEND", [], into: &out)
        return out
    }

    private static func chunk(_ type: String, _ data: [UInt8], into out: inout [UInt8]) {
        let t = Array(type.utf8)
        out.put(UInt32(data.count))
        out += t
        out += data
        out.put(Zlib.crc32(t + data))
    }
}
