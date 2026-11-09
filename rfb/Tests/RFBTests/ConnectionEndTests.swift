import Foundation
import Testing
@testable import RFB

/// A transport for the ending-of-a-connection tests. It hands out `stream`, can answer what the
/// client sends (`respond`), can fail sends (`failSends`), and when the stream is used up either
/// throws `ending` or waits until someone closes it. After `.abort` a waiting receive throws a
/// close without a code, as Network.framework reports ECANCELED.
final class ScriptedTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[UInt8]]
    private let ending: Error?
    private let failSends: Bool
    private let respond: (@Sendable ([UInt8]) -> [UInt8]?)?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var closedWith: RFBCloseCode?
    private(set) var sent: [[UInt8]] = []

    init(_ stream: [UInt8], chunk: Int = 1500, ending: Error? = nil, failSends: Bool = false,
         respond: (@Sendable ([UInt8]) -> [UInt8]?)? = nil) {
        queue = stride(from: 0, to: stream.count, by: chunk).map { Array(stream[$0..<min($0 + chunk, stream.count)]) }
        self.ending = ending
        self.failSends = failSends
        self.respond = respond
    }

    var closed: RFBCloseCode? { lock.withLock { closedWith } }
    var sentMessages: [[UInt8]] { lock.withLock { sent } }

    func send(_ bytes: [UInt8]) async throws {
        if failSends { throw RFBConnectionClosed(code: nil, reason: "Socket is not connected") }
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            sent.append(bytes)
            guard let answer = respond?(bytes) else { return nil }
            queue.append(answer)
            defer { waiting = nil }
            return waiting
        }
        w?.resume()
    }

    func receive() async throws -> [UInt8]? {
        while true {
            let next = lock.withLock { () -> [UInt8]? in queue.isEmpty ? nil : queue.removeFirst() }
            if let next { return next }
            // A scripted ending was already received: it comes out even after a later abort.
            if let ending { throw ending }
            if let code = lock.withLock({ closedWith }) {
                if code == .abort { throw RFBConnectionClosed(code: nil, reason: "ECANCELED") }
                return nil
            }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { () -> Bool in
                    if !queue.isEmpty || closedWith != nil { return true }
                    waiting = c
                    return false
                }
                if ready { c.resume() }
            }
        }
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

/// When a connection goes down, the write side often fails before the read side reports why
/// (seen on macOS: a fence answer failed with "socket is not connected" while Hermes' 4000 was
/// still waiting to be read). The client must keep reading and report the close code, must not
/// hang when no reason ever comes, and must notice a connection that went quiet.
@Suite struct ConnectionEndTests {
    static func isTimeout(_ error: any Error) -> Bool {
        if case RFBError.timedOut = error { return true }
        return false
    }

    /// The handshake of a server that does fences (so the keepalive starts): ServerInit, then one
    /// fence request as Xvnc sends right after SetEncodings.
    static var fencingServer: [UInt8] {
        var s = ServerScript.handshake()
        s.fence([.request], [0])
        return s.bytes
    }

    @Test func closeCodeWinsOverAFailedSend() async throws {
        let sample = Sample(name: "watch")
        // Every send fails, the pipelined handshake included; the read side still delivers the
        // whole session and then the bridge's 4000.
        let transport = ScriptedTransport(try sample.file("server.z"),
                                          ending: RFBConnectionClosed(code: 4000, reason: "control-taken"),
                                          failSends: true)
        var options = RFBOptions()
        options.sendFailureGrace = 1
        let client = RFBClient(transport: transport, options: options)
        await #expect(throws: RFBConnectionClosed(code: 4000, reason: "control-taken")) {
            try await client.run()
        }
        // Everything that arrived before the close was still decoded.
        #expect(await client.statistics.updates == 7)
        let (px, py) = try sample.pointer
        let diff = differingPixels(await client.framebuffer, try sample.file("expected.z"))
        #expect(diff.allSatisfy { abs($0.x - px) <= 24 && abs($0.y - py) <= 24 })
        // The grace period's abort was called off when the session ended.
        try await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(transport.closed == nil)
    }

    @Test func refusedTicketIsReportedEvenWhenTheHandshakeSendFails() async {
        // A spent ticket: the bridge accepts, then closes with 4401 at once; our pipelined
        // handshake write fails first.
        let transport = ScriptedTransport([], ending: RFBConnectionClosed(code: 4401, reason: "used"), failSends: true)
        await #expect(throws: RFBConnectionClosed(code: 4401, reason: "used")) {
            try await RFBClient(transport: transport).handshake()
        }
    }

    @Test func halfOpenConnectionIsDroppedNotHandedBack() async throws {
        let transport = ScriptedTransport(ServerScript.handshake().bytes, failSends: true)
        var options = RFBOptions()
        options.sendFailureGrace = 0.1
        let client = RFBClient(transport: transport, options: options)
        let started = Date()
        // The original failure is reported, not the ECANCELED the abort itself causes.
        await #expect(throws: RFBConnectionClosed(code: nil, reason: "Socket is not connected")) {
            try await client.run()
        }
        #expect(Date().timeIntervalSince(started) < 5)
        // Dropped like a network failure: no 1000/1001, so Hermes keeps the lease with us.
        #expect(transport.closed == .abort)
    }

    @Test func silentServerFailsTheHandshake() async {
        let transport = ScriptedTransport([])
        var options = RFBOptions()
        options.handshakeTimeout = 0.2
        await #expect(performing: { try await RFBClient(transport: transport, options: options).handshake() },
                      throws: Self.isTimeout)
        #expect(transport.closed == .abort)
    }

    @Test func deadConnectionIsFoundByTheKeepalive() async {
        // The server shows it does fences, then goes silent and answers nothing.
        let transport = ScriptedTransport(Self.fencingServer)
        var options = RFBOptions()
        options.keepaliveInterval = 0.1
        options.keepaliveTimeout = 0.2
        let client = RFBClient(transport: transport, options: options)
        await #expect(performing: { try await client.run() }, throws: Self.isTimeout)
        #expect(transport.closed == .abort)
        // It asked: a fence request carrying our marker.
        #expect(transport.sentMessages.contains { $0.first == 248 && $0[4] & 0x80 != 0 && $0.suffix(3).starts(with: [0x53, 0x48]) })
    }

    @Test func answeredKeepaliveKeepsTheSessionAndCancelLeavesNormally() async throws {
        // Answer every fence request of ours the way Xvnc does (same payload, no request flag).
        let transport = ScriptedTransport(Self.fencingServer, respond: { bytes in
            guard bytes.first == 248, bytes[4] & 0x80 != 0 else { return nil }
            return [248, 0, 0, 0, 0, 0, 0, 0] + Array(bytes[8...])
        })
        var options = RFBOptions()
        options.keepaliveInterval = 0.05
        options.keepaliveTimeout = 2  // generous: a slow CI machine must not look like a dead link
        let client = RFBClient(transport: transport, options: options)
        let run = Task { try await client.run() }
        // Several rounds go by without the session ending (polled: CI machines can be slow).
        for _ in 0..<250 where await client.statistics.keepalivesAnswered < 3 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await client.statistics.keepalivesAnswered >= 3)
        #expect(transport.closed == nil)
        // Leaving the screen (the SwiftUI .task ends): the client closes with 1000.
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(transport.closed == .normal)
    }

    @Test func cancellingTheHandshakeClosesTheConnection() async throws {
        let transport = ScriptedTransport([])
        var options = RFBOptions()
        options.closeOnCancel = .abort
        let client = RFBClient(transport: transport, options: options)
        let handshake = Task { try await client.handshake() }
        try await Task.sleep(nanoseconds: 100_000_000)
        handshake.cancel()
        await #expect(throws: CancellationError.self) { try await handshake.value }
        #expect(transport.closed == .abort)
    }

    @Test func refusedInputIsNotATransportFailure() async throws {
        var s = ServerScript.handshake()
        s.bytes += [3, 0, 0, 0]; s.bytes.put(Int32(-8)); s.bytes += [0x1F, 0, 0, 1, 0, 0, 0, 0]  // Xvnc's caps
        let transport = ScriptedTransport(s.bytes)
        var options = RFBOptions()
        options.sendFailureGrace = 0.1
        options.keepaliveInterval = 0
        let client = RFBClient(transport: transport, options: options)
        let run = Task { try await client.run() }
        let tooLong = String(repeating: "x", count: ClientMessage.maxCutText + 1)
        #expect(!RFBClient.clipboardFits(tooLong))
        await #expect(throws: RFBError.self) { try await client.sendClipboard(tooLong) }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(transport.closed == nil)  // no abort: nothing went wrong with the connection
        run.cancel()
        _ = await run.result
    }
}

@Suite struct InputOrderTests {
    @Test func clipboardWithoutTheExtensionIsLatin1Only() async throws {
        // No clipboard caps before the first update: the server has no extended clipboard.
        var s = ServerScript.handshake()
        s.update([])
        let transport = ScriptedTransport(s.bytes)
        var options = RFBOptions()
        options.keepaliveInterval = 0
        let client = RFBClient(transport: transport, options: options)
        let run = Task { try await client.run() }
        // Refused rather than sent as "??".
        await #expect(throws: RFBError.self) { try await client.sendClipboard("你好") }
        try await client.sendClipboard("café")
        #expect(transport.sentMessages.last == (try ClientMessage.clientCutText(latin1: [0x63, 0x61, 0x66, 0xE9]).encoded()))
        run.cancel()
        _ = await run.result
    }

    @Test func postedInputGoesOutInOrder() async throws {
        var s = ServerScript.handshake(width: 100, height: 100)
        s.bytes += [3, 0, 0, 0]; s.bytes.put(Int32(-8)); s.bytes += [0x1F, 0, 0, 1, 0, 0, 0, 0]  // Xvnc's caps
        let transport = ScriptedTransport(s.bytes)
        var options = RFBOptions()
        options.keepaliveInterval = 0
        let client = RFBClient(transport: transport, options: options)
        // Posted before run starts: held until it does.
        client.post(.key(0x61, down: true))
        let run = Task { try await client.run() }
        // A burst, as NSEvents would come in, mixing keys, the pointer and a paste.
        client.post(.key(0x61, down: false))
        for x in 0..<50 { client.post(.pointer(x: x, y: 1, buttons: x % 2 == 0 ? .left : [])) }
        client.post(.paste("你好", shortcut: [Keysym.controlLeft]))
        client.post(.key(Keysym.return, down: true))
        client.post(.key(Keysym.return, down: false))

        let input: [[UInt8]] = try [
            ClientMessage.keyEvent(down: true, keysym: 0x61).encoded(),
            ClientMessage.keyEvent(down: false, keysym: 0x61).encoded(),
        ] + (0..<50).map { x in
            try ClientMessage.pointerEvent(buttons: x % 2 == 0 ? .left : [], x: UInt16(x), y: 1).encoded()
        } + [
            ClientMessage.extendedClipboard(RFBClient.clientClipboardCaps).encoded(),
            ClientMessage.extendedClipboard(.notify(.text)).encoded(),
            ClientMessage.keyEvent(down: true, keysym: Keysym.controlLeft).encoded(),
            ClientMessage.keyEvent(down: true, keysym: 0x76).encoded(),
            ClientMessage.keyEvent(down: false, keysym: 0x76).encoded(),
            ClientMessage.keyEvent(down: false, keysym: Keysym.controlLeft).encoded(),
            ClientMessage.keyEvent(down: true, keysym: Keysym.return).encoded(),
            ClientMessage.keyEvent(down: false, keysym: Keysym.return).encoded(),
        ]
        // The input messages, in the order sent (setup, fences and replies filtered out).
        func sentInput() -> [[UInt8]] {
            transport.sentMessages.filter { [4, 5].contains($0.first!) || ($0.first == 6 && $0.count > 8 && [0x08, 0x1B].contains($0[8])) }
        }
        for _ in 0..<100 where sentInput().count < input.count {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // The caps message the client sends on its own (answering the server's) also starts
        // with 0x1B; keep the ones belonging to the paste by position.
        let sent = sentInput()
        let firstKey = try #require(sent.firstIndex(of: input[0]))
        #expect(Array(sent[firstKey...]) == input)
        run.cancel()
        _ = await run.result
    }
}
