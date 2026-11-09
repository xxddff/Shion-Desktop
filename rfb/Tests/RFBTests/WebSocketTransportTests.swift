import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RFB
@testable import RFBNetwork

/// The WebSocket transports against testbed/replay_server.py, which plays a recorded Xvnc session
/// and then either closes with 4000 (control taken) or waits for our close. Checks what the App
/// relies on: extra request headers, a refused upgrade (403), the bridge's close code reaching
/// the caller, and our close going out as 1000.
///
/// Needs a python3 with `websockets` (>= 13): set RFB_TESTBED_PYTHON to it, as for the testbed.
/// On macOS this exercises NWWebSocketTransport and URLSessionWebSocketTransport; everywhere it
/// also runs the small ws:// client.
@Suite(.serialized, .timeLimit(.minutes(1)),
       .enabled(if: ReplayServer.python != nil, "RFB_TESTBED_PYTHON with websockets not set"))
struct WebSocketTransportTests {
    enum Kind: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case plain, urlSession, network
        var testDescription: String { rawValue }

        static var available: [Kind] {
            #if canImport(Network)
            [.plain, .urlSession, .network]
            #else
            [.plain]  // Foundation's WebSocket needs a libcurl built with WebSockets
            #endif
        }

        func transport(_ url: URL, headers: [(String, String)]) throws -> any RFBTransport {
            // What the platform transports report goes to stderr, which CI shows even when the
            // test output is buffered.
            let name = rawValue
            let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("[\(name)] \($0)\n".utf8)) }
            switch self {
            case .plain:
                return try PlainWebSocketTransport(url: url, headers: headers)
            case .urlSession:
                var request = URLRequest(url: url)
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                return URLSessionWebSocketTransport(request: request, log: log)
            case .network:
                #if canImport(Network)
                return NWWebSocketTransport(url: url, headers: headers, connectTimeout: 5, log: log)
                #else
                fatalError("Network.framework only")
                #endif
            }
        }
    }

    static let header = [("CF-Access-Client-Id", "test-id")]

    @Test(arguments: Kind.available)
    func bridgeCloseCodeReachesTheCaller(_ kind: Kind) async throws {
        let server = try ReplayServer(sample: "watch")
        defer { server.stop() }
        let client = RFBClient(transport: try kind.transport(server.url(then: "close4000"), headers: Self.header))
        let ending: Error?
        do {
            try await client.run()
            ending = nil
        } catch {
            ending = error
        }
        let check = {
            let closed = try #require(ending as? RFBConnectionClosed, "ended with \(ending.map { "\($0)" } ?? "no error")")
            #expect(closed.code == 4000)
            #expect(closed.bridgeReason == .controlTaken)
        }
        if kind == .urlSession {
            // CI on macOS: URLSessionWebSocketTask reported the server's close only as
            // "Socket is not connected", with no code. NWWebSocketTransport is the one to use.
            withKnownIssue("URLSessionWebSocketTask may not report a server-initiated close code", isIntermittent: true) {
                try check()
            }
        } else {
            try check()
        }
        // Everything before the close was decoded: the picture matches the real screen.
        let sample = Sample(name: "watch")
        let diff = differingPixels(await client.framebuffer, try sample.file("expected.z"))
        let (px, py) = try sample.pointer
        #expect(diff.allSatisfy { abs($0.x - px) <= 24 && abs($0.y - py) <= 24 })
    }

    @Test(arguments: Kind.available)
    func ourCloseIsNormal(_ kind: Kind) async throws {
        let server = try ReplayServer(sample: "watch")
        defer { server.stop() }
        let client = RFBClient(transport: try kind.transport(server.url(then: "wait"), headers: Self.header))
        let run = Task { try await client.run() }
        // Wait for the whole recording to arrive, then leave the way the App does.
        for _ in 0..<100 where await client.statistics.updates < 7 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(await client.statistics.updates == 7)
        await client.close(.normal)
        _ = await run.result
        #expect(server.waitForLine(prefix: "client closed") == "client closed 1000")
    }

    @Test(arguments: Kind.available)
    func missingAccessHeaderIsRefused(_ kind: Kind) async throws {
        let server = try ReplayServer(sample: "watch")
        defer { server.stop() }
        await #expect {
            let client = RFBClient(transport: try kind.transport(server.url(then: "wait"), headers: []))
            try await client.handshake()
        } throws: { error in
            guard case RFBError.connectionRefused(let message) = error else { return false }
            // Network.framework does not surface the HTTP status of a refused upgrade.
            return kind == .network || message.contains("403")
        }
    }
}

/// testbed/replay_server.py in a child process.
final class ReplayServer: @unchecked Sendable {
    static var python: String? {
        guard let path = ProcessInfo.processInfo.environment["RFB_TESTBED_PYTHON"],
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("testbed/replay_server.py")

    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var lines: [String] = []
    private var partial = ""
    private(set) var port = 0

    init(sample: String) throws {
        process.executableURL = URL(fileURLWithPath: Self.python!)
        process.arguments = ["-I", Self.script.path,
                             Sample.directory.appendingPathComponent("\(sample).server.z").path,
                             "--require-header", "CF-Access-Client-Id"]
        process.standardOutput = output
        try process.run()
        // A plain reader thread (readabilityHandler spins on Linux).
        let reader = Thread { [weak self] in
            while true {
                guard let handle = self?.output.fileHandleForReading else { return }
                let data = handle.availableData
                guard !data.isEmpty, let self else { return }
                self.lock.withLock {
                    self.partial += String(decoding: data, as: UTF8.self)
                    while let newline = self.partial.firstIndex(of: "\n") {
                        self.lines.append(String(self.partial[..<newline]))
                        self.partial = String(self.partial[self.partial.index(after: newline)...])
                    }
                }
            }
        }
        reader.start()
        var found: Int?
        for _ in 0..<200 {
            found = lock.withLock { lines.first { $0.hasPrefix("port ") }.flatMap { Int($0.dropFirst(5)) } }
            if found != nil || !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let found else {
            process.terminate()
            throw POSIXSocketError("replay server did not start")
        }
        port = found
    }

    func url(then: String) -> URL {
        URL(string: "ws://127.0.0.1:\(port)/api/display/ws?display_ticket=test&then=\(then)")!
    }

    /// The first stdout line starting with `prefix`, waiting up to 5 s.
    func waitForLine(prefix: String) -> String? {
        for _ in 0..<100 {
            if let line = lock.withLock({ lines.first { $0.hasPrefix(prefix) } }) { return line }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    func stop() {
        // SIGKILL: a child spawned from a libdispatch thread inherits a mask that blocks SIGTERM.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
