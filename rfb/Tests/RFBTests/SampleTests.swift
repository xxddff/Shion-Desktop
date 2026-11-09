import Foundation
import Testing
@testable import RFB

/// Recorded sessions with a real Xvnc (TigerVNC 1.13, Hermes' flags) through the testbed bridge,
/// and the real screen grabbed with xwd at the end (testbed/record-sample.sh). Replaying the
/// server's bytes must give exactly the screen's pixels.
struct Sample: CustomTestStringConvertible, Sendable {
    let name: String
    var testDescription: String { name }

    static let all = ["watch", "resize", "resize-plain", "raw"].map(Sample.init)

    static var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Samples")
    }

    func file(_ suffix: String) throws -> [UInt8] {
        let data = try Data(contentsOf: Self.directory.appendingPathComponent("\(name).\(suffix)"))
        return try Inflater().inflate([UInt8](data), limit: 64 << 20)
    }

    var metadata: [String: Any] {
        get throws {
            let json = try Data(contentsOf: Self.directory.appendingPathComponent("\(name).json"))
            return try JSONSerialization.jsonObject(with: json) as! [String: Any]
        }
    }

    var size: (Int, Int) {
        get throws {
            let parts = (try metadata["size"] as! String).split(separator: "x").map { Int($0)! }
            return (parts[0], parts[1])
        }
    }

    /// Where the pointer was parked while recording.
    var pointer: (Int, Int) {
        get throws {
            let p = try metadata["pointer"] as! [Int]
            return (p[0], p[1])
        }
    }
}

/// Runs a client over a replayed stream until the recording ends.
func replay(_ bytes: [UInt8], chunkSizes: [Int] = [64 * 1024], options: RFBOptions = RFBOptions())
    async throws -> (RFBClient, ReplayTransport, [RFBEvent]) {
    let transport = ReplayTransport(bytes, chunkSizes: chunkSizes)
    let client = RFBClient(transport: transport, options: options)
    let events = EventLog()
    do {
        try await client.run { event, _ in events.append(event) }
        Issue.record("run returned without the stream ending")
    } catch RFBError.endOfStream {
        // the recording is over
    }
    return (client, transport, events.all)
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RFBEvent] = []
    func append(_ e: RFBEvent) { lock.withLock { events.append(e) } }
    var all: [RFBEvent] { lock.withLock { events } }
}

/// Pixels whose B, G or R differ.
func differingPixels(_ fb: Framebuffer, _ expected: [UInt8]) -> [(x: Int, y: Int)] {
    var out: [(x: Int, y: Int)] = []
    for i in stride(from: 0, to: min(fb.pixels.count, expected.count), by: 4)
    where fb.pixels[i] != expected[i] || fb.pixels[i + 1] != expected[i + 1] || fb.pixels[i + 2] != expected[i + 2] {
        out.append((x: (i / 4) % fb.width, y: (i / 4) / fb.width))
    }
    return out
}

@Suite struct SampleTests {
    @Test(arguments: Sample.all)
    func decodesToTheRealScreen(_ sample: Sample) async throws {
        let stream = try sample.file("server.z")
        let expected = try sample.file("expected.z")
        let (width, height) = try sample.size
        let (client, _, _) = try await replay(stream)
        let fb = await client.framebuffer
        #expect(fb.width == width && fb.height == height)
        #expect(expected.count == width * height * 4)
        // Xvnc paints the pointer into the picture for a client without the Cursor
        // pseudo-encoding (what we want while watching); xwd leaves it out. So pixels may differ
        // only where the pointer was, and everywhere else they must be identical.
        let (px, py) = try sample.pointer
        let diff = differingPixels(fb, expected)
        let stray = diff.filter { abs($0.x - px) > 24 || abs($0.y - py) > 24 }
        #expect(stray.isEmpty, "\(stray.count) pixels differ away from the pointer, first at \(stray.first.map { "\($0)" } ?? "")")
        #expect(diff.count < 24 * 24)
    }

    /// In the raw sample the pointer rests on a terminal, whose I-beam Xvnc paints into the
    /// picture. (Over the bare root window of the testbed, which has no WM setting a root
    /// cursor, nothing is painted; on Hermes' Xfce desktop the root has the arrow.)
    @Test func xvncPaintsTheAgentsPointer() async throws {
        let sample = Sample(name: "raw")
        var options = RFBOptions()
        options.continuousUpdates = false
        let (client, _, _) = try await replay(try sample.file("server.z"), options: options)
        let diff = differingPixels(await client.framebuffer, try sample.file("expected.z"))
        #expect(!diff.isEmpty)
    }

    /// Message boundaries never line up with what the transport hands us.
    @Test(arguments: Sample.all)
    func chunkingDoesNotMatter(_ sample: Sample) async throws {
        let stream = try sample.file("server.z")
        let (reference, _, _) = try await replay(stream)
        let (oddly, _, _) = try await replay(stream, chunkSizes: [1, 7, 3, 1500, 2, 64 * 1024 + 3])
        let a = await reference.framebuffer, b = await oddly.framebuffer
        #expect(a == b)
    }

    @Test func watchUsesTheEncodingsWeExpect() async throws {
        let (client, transport, events) = try await replay(try Sample(name: "watch").file("server.z"))
        let stats = await client.statistics
        #expect(stats.rects[RFBEncoding.zrle.rawValue, default: 0] > 0)
        #expect(stats.rects[RFBEncoding.copyRect.rawValue, default: 0] > 0)
        #expect(stats.fencesAnswered > 0)
        #expect(events.contains(.continuousUpdates(true)))
        #expect(await client.serverSupportsContinuousUpdates)
        let caps = try #require(await client.serverClipboardCaps)
        #expect(caps.formats.contains(.text))
        #expect(caps.supportedActions.isSuperset(of: [.notify, .request, .provide]))

        // What the client said: pixel format, encodings, a full request, our clipboard caps,
        // fence answers, EnableContinuousUpdates. Nothing the bridge cannot frame.
        // The handshake goes out pipelined, in one write: version, security None, shared,
        // SetPixelFormat, SetEncodings.
        let sent = transport.sent
        let opening = Array("RFB 003.008\n".utf8) + [1, 1] + (try ClientMessage.setPixelFormat(.bgrx).encoded())
            + (try ClientMessage.setEncodings(RFBOptions().encodings).encoded())
        #expect(sent[0] == opening)
        #expect(sent[1] == (try ClientMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: 800, height: 500).encoded()))
        #expect(sent.contains { $0.first == 150 })
        #expect(sent.contains { $0.first == 248 })
        #expect(!sent.dropFirst().contains { [4, 5, 251, 255].contains($0.first!) })
    }

    @Test func resizeFollowsTheServer() async throws {
        for name in ["resize", "resize-plain"] {
            let (client, _, events) = try await replay(try Sample(name: name).file("server.z"))
            #expect(events.contains(.resized(width: 640, height: 480)), "\(name)")
            let stats = await client.statistics
            let pseudo = name == "resize" ? RFBEncoding.extendedDesktopSize : .desktopSize
            #expect(stats.rects[pseudo.rawValue, default: 0] > 0, "\(name)")
        }
    }

    @Test func rawWithoutContinuousUpdates() async throws {
        var options = RFBOptions()
        options.continuousUpdates = false  // as recorded (--no-continuous)
        let (client, transport, _) = try await replay(try Sample(name: "raw").file("server.z"), options: options)
        let stats = await client.statistics
        #expect(stats.rects[RFBEncoding.raw.rawValue, default: 0] > 0)
        #expect(stats.rects[RFBEncoding.zrle.rawValue, default: 0] == 0)
        // One incremental request after each update.
        let requests = transport.sent.filter { $0.first == 3 }
        #expect(requests.count == stats.updates + 1)
        #expect(!transport.sent.contains { $0.first == 150 })
    }
}
