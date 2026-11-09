import Foundation
import Testing
@testable import RFB

/// When a connection goes down, the write side often fails before the read side reports why
/// (seen on macOS: a fence answer failed with "socket is not connected" while Hermes' 4000 was
/// still waiting to be read). The client must keep reading and report the close code, and must
/// not hang when no reason ever comes.
@Suite struct ConnectionEndTests {
    /// Replays a server stream; sends fail after the first `sendsAllowed`. At the end, receive
    /// throws `ending`, or (nil) waits until someone closes the transport.
    final class BrokenWriteTransport: RFBTransport, @unchecked Sendable {
        private let replay: ReplayTransport
        private let ending: Error?
        private let lock = NSLock()
        private var sendsAllowed: Int
        private var waiting: CheckedContinuation<Void, Never>?
        private(set) var closedWith: RFBCloseCode?

        init(_ stream: [UInt8], sendsAllowed: Int, ending: Error?) {
            replay = ReplayTransport(stream, chunkSizes: [1500])
            self.sendsAllowed = sendsAllowed
            self.ending = ending
        }

        func send(_ bytes: [UInt8]) async throws {
            let ok = lock.withLock { () -> Bool in
                guard sendsAllowed > 0 else { return false }
                sendsAllowed -= 1
                return true
            }
            if !ok { throw RFBConnectionClosed(code: nil, reason: "Socket is not connected") }
        }

        func receive() async throws -> [UInt8]? {
            if let chunk = try await replay.receive() { return chunk }
            if let ending { throw ending }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let closed = lock.withLock { () -> Bool in
                    if closedWith != nil { return true }
                    waiting = c
                    return false
                }
                if closed { c.resume() }
            }
            return nil
        }

        func close(_ code: RFBCloseCode) async {
            let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                closedWith = closedWith ?? code
                defer { waiting = nil }
                return waiting
            }
            w?.resume()
        }
    }

    @Test func closeCodeWinsOverAFailedSend() async throws {
        let sample = Sample(name: "watch")
        // Only the pipelined handshake gets out; every reply after it fails.
        let transport = BrokenWriteTransport(try sample.file("server.z"), sendsAllowed: 1,
                                             ending: RFBConnectionClosed(code: 4000, reason: "control-taken"))
        let client = RFBClient(transport: transport)
        await #expect(throws: RFBConnectionClosed(code: 4000, reason: "control-taken")) {
            try await client.run()
        }
        // Everything that arrived before the close was still decoded.
        #expect(await client.statistics.updates == 7)
        let (px, py) = try sample.pointer
        let diff = differingPixels(await client.framebuffer, try sample.file("expected.z"))
        #expect(diff.allSatisfy { abs($0.x - px) <= 24 && abs($0.y - py) <= 24 })
    }

    @Test func halfOpenConnectionIsDroppedNotHandedBack() async throws {
        let transport = BrokenWriteTransport(ServerScript.handshake().bytes, sendsAllowed: 1, ending: nil)
        var options = RFBOptions()
        options.sendFailureGrace = 0.1
        let client = RFBClient(transport: transport, options: options)
        let started = Date()
        await #expect(throws: RFBConnectionClosed(code: nil, reason: "Socket is not connected")) {
            try await client.run()
        }
        #expect(Date().timeIntervalSince(started) < 5)
        // Dropped like a network failure: no 1000/1001, so Hermes keeps the lease with us.
        #expect(transport.closedWith == .abort)
    }
}
