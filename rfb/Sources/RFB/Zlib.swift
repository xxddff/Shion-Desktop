import CZlib

/// A zlib inflate stream. ZRLE keeps ONE stream for the whole connection, so this is long-lived.
final class Inflater {
    private let stream: UnsafeMutablePointer<z_stream>
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)

    init() throws {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        let rc = inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else {
            stream.deallocate()
            throw RFBError.zlib(rc)
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
    }

    /// Inflates all of `input` (which must end on a flush point, as ZRLE rects and extended
    /// clipboard messages do) and returns everything it produced.
    func inflate(_ input: [UInt8], sizeHint: Int = 0) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(max(sizeHint, input.count * 4))
        try input.withUnsafeBufferPointer { inBuf in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
            stream.pointee.avail_in = UInt32(inBuf.count)
            while true {
                let produced: Int = try scratch.withUnsafeMutableBufferPointer { out in
                    stream.pointee.next_out = out.baseAddress
                    stream.pointee.avail_out = UInt32(out.count)
                    let rc = CZlib.inflate(stream, Z_SYNC_FLUSH)
                    // Z_BUF_ERROR just means no progress was possible (input used up).
                    if rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR { throw RFBError.zlib(rc) }
                    return out.count - Int(stream.pointee.avail_out)
                }
                output += scratch[0..<produced]
                if stream.pointee.avail_in == 0 && produced < scratch.count { break }
                if produced == 0 && stream.pointee.avail_in > 0 {
                    throw RFBError.protocolViolation("zlib stream stalled")
                }
            }
            stream.pointee.next_in = nil
        }
        return output
    }
}

enum Zlib {
    /// One-shot zlib (RFC 1950) compression, as the extended clipboard expects.
    static func compress(_ input: [UInt8], level: Int32 = 6) throws -> [UInt8] {
        var size = compressBound(uLong(input.count))
        var out = [UInt8](repeating: 0, count: Int(size))
        let rc = out.withUnsafeMutableBufferPointer { o in
            input.withUnsafeBufferPointer { i in
                compress2(o.baseAddress, &size, i.baseAddress, uLong(i.count), level)
            }
        }
        guard rc == Z_OK else { throw RFBError.zlib(rc) }
        return Array(out[0..<Int(size)])
    }

    static func crc32(_ bytes: [UInt8], start: UInt32 = 0) -> UInt32 {
        bytes.withUnsafeBufferPointer { b in
            UInt32(CZlib.crc32(uLong(start), b.baseAddress, uInt(b.count)))
        }
    }
}
