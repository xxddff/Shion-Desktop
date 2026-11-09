/// Bytes received but not yet parsed. Filled by the client from its transport; read synchronously.
struct ReceiveBuffer {
    private var buffer: [UInt8] = []
    private var offset = 0

    var available: Int { buffer.count - offset }

    mutating func append(_ chunk: [UInt8]) {
        if offset == buffer.count {
            buffer = chunk
            offset = 0
            return
        }
        if offset > 1 << 16 {
            buffer.removeFirst(offset)
            offset = 0
        }
        buffer += chunk
    }

    /// Callers make sure `available >= count` first.
    mutating func take(_ count: Int) -> [UInt8] {
        precondition(available >= count)
        defer { offset += count }
        return Array(buffer[offset..<offset + count])
    }

    mutating func u8() -> UInt8 {
        precondition(available >= 1)
        defer { offset += 1 }
        return buffer[offset]
    }

    mutating func u16() -> UInt16 {
        precondition(available >= 2)
        defer { offset += 2 }
        return UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1])
    }

    mutating func u32() -> UInt32 {
        precondition(available >= 4)
        defer { offset += 4 }
        return buffer[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Big-endian serialisation helpers for client messages.
extension Array where Element == UInt8 {
    mutating func put(_ v: UInt8) { append(v) }
    mutating func put(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func put(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }
    mutating func put(_ v: Int32) { put(UInt32(bitPattern: v)) }
    mutating func pad(_ n: Int) { append(contentsOf: repeatElement(0, count: n)) }
}

/// Reads big-endian fields from an in-memory buffer (decoded payloads).
struct SliceReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func need(_ n: Int) throws {
        if remaining < n { throw RFBError.protocolViolation("payload truncated") }
    }

    mutating func u8() throws -> UInt8 {
        try need(1); defer { offset += 1 }; return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        try need(2); defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func u32() throws -> UInt32 {
        try need(4); defer { offset += 4 }
        return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        try need(n); defer { offset += n }; return bytes[offset..<offset + n]
    }
}
