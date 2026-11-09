/// Plays back a recorded server stream (what `RFBClient`'s recorder saw) and swallows whatever
/// the client sends. For tests: a recording of a real Xvnc session decodes to the same picture.
public final class ReplayTransport: RFBTransport, @unchecked Sendable {
    // Only touched from the client's actor; `@unchecked` because the protocol requires Sendable.
    private let data: [UInt8]
    private var offset = 0
    private let chunkSizes: [Int]
    private var chunkIndex = 0
    public private(set) var sent: [[UInt8]] = []

    /// `chunkSizes` cycles to cut the stream into receive() chunks (message boundaries must not
    /// matter); the default hands it out in 64 KiB pieces.
    public init(_ data: [UInt8], chunkSizes: [Int] = [64 * 1024]) {
        precondition(!chunkSizes.isEmpty && chunkSizes.allSatisfy { $0 > 0 })
        self.data = data
        self.chunkSizes = chunkSizes
    }

    public func send(_ bytes: [UInt8]) async throws { sent.append(bytes) }

    public func receive() async throws -> [UInt8]? {
        guard offset < data.count else { return nil }
        let n = min(chunkSizes[chunkIndex % chunkSizes.count], data.count - offset)
        chunkIndex += 1
        defer { offset += n }
        return Array(data[offset..<offset + n])
    }

    public func close(_ code: RFBCloseCode) async {}
}

/// Passes everything through to `inner` and hands both byte streams to `record`, in order:
/// what the server sent (the test sample) and what the client sent.
public final class RecordingTransport: RFBTransport, Sendable {
    public enum Direction: Sendable { case received, sent }
    private let inner: any RFBTransport
    private let record: @Sendable (Direction, [UInt8]) -> Void

    public init(_ inner: any RFBTransport, record: @escaping @Sendable (Direction, [UInt8]) -> Void) {
        self.inner = inner
        self.record = record
    }

    public func send(_ bytes: [UInt8]) async throws {
        try await inner.send(bytes)
        record(.sent, bytes)
    }

    public func receive() async throws -> [UInt8]? {
        let chunk = try await inner.receive()
        if let chunk { record(.received, chunk) }
        return chunk
    }

    public func close(_ code: RFBCloseCode) async { await inner.close(code) }
}
