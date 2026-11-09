import Foundation
import Testing
@testable import RFB

/// Feeds everything our encoder can produce through Hermes' own `RfbClientFilter`
/// (testbed/hermes/rfb_filter.py, vendored unchanged) to show the bridge can frame every message:
/// all of it passes for the lease holder, input is dropped for a watcher, nothing makes it close
/// the connection. Needs python3; skipped without it.
@Suite struct BridgeFilterTests {
    static let filterDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("testbed/hermes")

    static var python: String? {
        ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Every kind of message we send, with the handshake bytes in front.
    static func session() throws -> [UInt8] {
        let messages: [ClientMessage] = [
            .setPixelFormat(.bgrx),
            .setEncodings(RFBOptions().encodings),
            .framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: 1440, height: 900),
            .enableContinuousUpdates(enable: true, x: 0, y: 0, width: 1440, height: 900),
            .fence(flags: [.blockBefore], payload: [1, 2, 3]),
            .keyEvent(down: true, keysym: 0xFFE3),
            .pointerEvent(buttons: .left, x: 10, y: 20),
            .clientCutText(latin1: Array("plain".utf8)),
            .extendedClipboard(RFBClient.clientClipboardCaps),
            .extendedClipboard(.notify(.text)),
            .extendedClipboard(.provide(text: String(repeating: "长文本 long text\n", count: 9000))),
            .fence(flags: [], payload: []),
        ]
        return Array("RFB 003.008\n".utf8) + [1, 1] + (try messages.flatMap { try $0.encoded() })
    }

    /// Runs the stream through the filter in odd-sized chunks; returns what reached "Xvnc".
    static func filter(_ stream: [UInt8], allowInput: Bool) throws -> (out: [UInt8], error: String) {
        let script = """
        import sys
        sys.path.insert(0, sys.argv[1])
        from rfb_filter import RfbClientFilter
        data = sys.stdin.buffer.read()
        f = RfbClientFilter(lambda: sys.argv[2] == "1")
        out = bytearray()
        sizes = [1, 5, 4096, 3, 70000]
        i = k = 0
        while i < len(data):
            n = sizes[k % len(sizes)]; k += 1
            out += f.feed(data[i:i + n]); i += n
        sys.stdout.buffer.write(out)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python!)
        process.arguments = ["-I", "-c", script, filterDirectory.path, allowInput ? "1" : "0"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let writer = Thread {
            stdin.fileHandleForWriting.write(Data(stream))
            try? stdin.fileHandleForWriting.close()
        }
        writer.start()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ([UInt8](out), String(decoding: err, as: UTF8.self))
    }

    @Test(.enabled(if: python != nil, "python3 not found"))
    func leaseHolderGetsEverythingThrough() throws {
        let stream = try Self.session()
        let (out, error) = try Self.filter(stream, allowInput: true)
        #expect(error.isEmpty, "\(error)")
        #expect(out == stream)
    }

    @Test(.enabled(if: python != nil, "python3 not found"))
    func watcherInputIsDropped() throws {
        let stream = try Self.session()
        let (out, error) = try Self.filter(stream, allowInput: false)
        #expect(error.isEmpty, "\(error)")
        // What should survive: handshake and every non-input message, in order.
        let expected = Array("RFB 003.008\n".utf8) + [1, 1] + (try [
            ClientMessage.setPixelFormat(.bgrx),
            .setEncodings(RFBOptions().encodings),
            .framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: 1440, height: 900),
            .enableContinuousUpdates(enable: true, x: 0, y: 0, width: 1440, height: 900),
            .fence(flags: [.blockBefore], payload: [1, 2, 3]),
            .fence(flags: [], payload: []),
        ].flatMap { try $0.encoded() })
        #expect(out == expected)
    }

    @Test(.enabled(if: python != nil, "python3 not found"))
    func oversizedClipboardWouldCloseTheBridge() throws {
        // We never build this (ClientMessage refuses), so craft it by hand to show the limit is real.
        var bad = Array("RFB 003.008\n".utf8) + [1, 1] + [6, 0, 0, 0]
        bad.put(UInt32(ClientMessage.maxCutText + 1))
        let (_, error) = try Self.filter(bad + Array(repeating: 0x41, count: 16), allowInput: true)
        #expect(error.contains("clipboard message too large"))
    }
}
