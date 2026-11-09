// rfb-probe: connect to an RFB server (Hermes' display bridge, or Xvnc directly), run the
// handshake and the "watch" setup, record both byte streams and save the final picture.
//
// Tickets, tokens and header values are never printed: URLs are shown without their query.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RFB
import RFBNetwork

let usage = """
usage: rfb-probe <url> [options]
       rfb-probe --gateway <wss://host> --profile <name> [options]

<url>   ws://… or wss://… (Hermes: /api/display/ws?display_ticket=…), tcp://host:port, unix:/path

  -H, --header 'Name: value'   extra request header (repeatable); a value of @env:VAR is read
                               from the environment, e.g. -H 'CF-Access-Client-Secret: @env:CF_SECRET'
  --out DIR                    where to write the recording and the picture (default ./probe-out)
  --seconds N                  keep watching N seconds after the first picture (default 5)
  --updates N                  or stop after N framebuffer updates
  --no-continuous              do not enable continuous updates (one request per update)
  --no-extended-desktop-size   only advertise the plain DesktopSize pseudo-encoding
  --no-pipeline                wait for each server step of the handshake before answering
  --encodings LIST             e.g. zrle,copyrect,raw (pseudo-encodings are always added)
  --transport auto|urlsession|plain
                               auto: the small built-in client for ws:// on Linux, URLSession otherwise
  --paste TEXT                 after the first picture, put TEXT on the remote clipboard (needs the lease)
  --type TEXT                  after the first picture, type TEXT at the remote cursor: clipboard + Ctrl+V (needs the lease)
  --cursor-after SECONDS       after that long, ask for the pointer shape (Cursor pseudo-encoding), as at takeover
  --move-pointer X,Y           then move the pointer there (only reaches Xvnc while holding the lease)

Getting a ticket from the gateway first (display.observe over /api/ws; not yet tried on a real server):
  --gateway URL                the gateway origin, e.g. wss://hermes.example.com
  --profile NAME               the assistant (profile) whose screen to watch
  --token-env VAR              env var holding the Hermes session token for /api/ws?token= (default HERMES_SESSION_TOKEN)
"""

struct Arguments {
    var url: String?
    var headers: [(String, String)] = []
    var out = "probe-out"
    var seconds = 5.0
    var updates: Int?
    var continuous = true
    var extendedDesktopSize = true
    var pipeline = true
    var encodings: [RFBEncoding]?
    var transport = "auto"
    var paste: String?
    var type: String?
    var cursorAfter: Double?
    var movePointer: (Int, Int)?
    var gateway: String?
    var profile: String?
    var tokenEnv = "HERMES_SESSION_TOKEN"
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("rfb-probe: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func parseArguments() -> Arguments {
    var a = Arguments()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) needs a value") }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "-h", "--help": print(usage); exit(0)
        case "-H", "--header":
            let raw = value(arg)
            guard let colon = raw.firstIndex(of: ":") else { fail("header must look like 'Name: value'") }
            let name = raw[..<colon].trimmingCharacters(in: .whitespaces)
            var v = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("@env:") {
                let variable = String(v.dropFirst(5))
                guard let env = ProcessInfo.processInfo.environment[variable] else { fail("\(variable) is not set") }
                v = env
            }
            a.headers.append((name, v))
        case "--out": a.out = value(arg)
        case "--seconds": guard let n = Double(value(arg)) else { fail("--seconds takes a number") }
            a.seconds = n
        case "--updates": guard let n = Int(value(arg)) else { fail("--updates takes a number") }
            a.updates = n
        case "--no-continuous": a.continuous = false
        case "--no-extended-desktop-size": a.extendedDesktopSize = false
        case "--no-pipeline": a.pipeline = false
        case "--encodings":
            a.encodings = value(arg).split(separator: ",").map {
                switch $0.lowercased() {
                case "zrle": .zrle
                case "copyrect": .copyRect
                case "raw": .raw
                default: fail("unknown encoding \($0)")
                }
            }
        case "--transport": a.transport = value(arg)
        case "--paste": a.paste = value(arg)
        case "--type": a.type = value(arg)
        case "--move-pointer":
            let xy = value(arg).split(separator: ",").compactMap { Int($0) }
            guard xy.count == 2 else { fail("--move-pointer takes X,Y") }
            a.movePointer = (xy[0], xy[1])
        case "--cursor-after":
            guard let n = Double(value(arg)) else { fail("--cursor-after takes a number") }
            a.cursorAfter = n
        case "--gateway": a.gateway = value(arg)
        case "--profile": a.profile = value(arg)
        case "--token-env": a.tokenEnv = value(arg)
        default:
            if arg.hasPrefix("-") || a.url != nil { fail("unexpected argument \(arg)\n\n\(usage)") }
            a.url = arg
        }
    }
    if a.url == nil && a.gateway == nil { print(usage); exit(2) }
    return a
}

/// The URL without its query (which may hold a ticket or token).
func redacted(_ url: String) -> String {
    guard let q = url.firstIndex(of: "?") else { return url }
    return url[..<q] + "?…"
}

func makeTransport(_ url: String, _ args: Arguments) throws -> any RFBTransport {
    if url.hasPrefix("tcp://") {
        let rest = url.dropFirst(6)
        guard let colon = rest.lastIndex(of: ":"), let port = UInt16(rest[rest.index(after: colon)...]) else {
            fail("tcp:// URLs need a port")
        }
        return try SocketTransport(host: String(rest[..<colon]), port: port)
    }
    if url.hasPrefix("unix:") {
        return try SocketTransport(unixPath: String(url.dropFirst(5)))
    }
    guard let u = URL(string: url), u.scheme == "ws" || u.scheme == "wss" else { fail("bad URL \(redacted(url))") }
    #if os(Linux)
    let preferPlain = u.scheme == "ws"
    #else
    let preferPlain = false
    #endif
    let kind = args.transport == "auto" ? (preferPlain ? "plain" : "urlsession") : args.transport
    switch kind {
    case "plain":
        return try PlainWebSocketTransport(url: u, headers: args.headers)
    case "urlsession":
        var request = URLRequest(url: u)
        for (name, value) in args.headers { request.setValue(value, forHTTPHeaderField: name) }
        return URLSessionWebSocketTransport(request: request)
    default:
        fail("unknown transport \(kind)")
    }
}

/// Collects the recording off the client's actor.
final class Recording: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [UInt8] = []
    private var sent: [UInt8] = []
    func add(_ d: RecordingTransport.Direction, _ b: [UInt8]) {
        lock.withLock { if d == .received { received += b } else { sent += b } }
    }
    var streams: ([UInt8], [UInt8]) { lock.withLock { (received, sent) } }
}

final class Progress: @unchecked Sendable {
    let lock = NSLock()
    var firstPicture: Date?
    var updates = 0
    var events: [String] = []
    var ended = false
    var endError: Error?
    var cursorRequested: Date?
    var loggedAfterCursor = 0
}

/// display.observe over the gateway's JSON-RPC WebSocket; returns the display URL with its ticket.
/// The gateway socket is returned too: the viewer id lives as long as that connection.
func observe(_ args: Arguments) async throws -> (String, URLSessionWebSocketTask) {
    guard let gateway = args.gateway, var components = URLComponents(string: gateway) else { fail("bad --gateway") }
    guard let profile = args.profile else { fail("--gateway needs --profile") }
    guard let token = ProcessInfo.processInfo.environment[args.tokenEnv] else { fail("\(args.tokenEnv) is not set") }
    components.path = "/api/ws"
    components.queryItems = [URLQueryItem(name: "token", value: token)]
    var request = URLRequest(url: components.url!)
    for (name, value) in args.headers { request.setValue(value, forHTTPHeaderField: name) }
    let task = URLSession.shared.webSocketTask(with: request)
    task.resume()
    let call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "display.observe", "params": ["profile": profile]]
    try await task.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: call), as: UTF8.self)))
    while true {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: continue
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["id"] as? Int) == 1 else { continue }  // events and other traffic
        if let error = object["error"] as? [String: Any] {
            fail("display.observe failed: \(error["code"] ?? "?") \(error["message"] ?? "")")
        }
        guard let result = object["result"] as? [String: Any], let ticket = result["ticket"] as? String,
              let path = result["path"] as? String else { fail("display.observe: unexpected answer") }
        var display = URLComponents(string: gateway)!
        display.path = path
        display.queryItems = [URLQueryItem(name: "display_ticket", value: ticket)]
        log("display.observe: viewer \(String((result["viewer_id"] as? String ?? "?").prefix(4)))…, running \(result["running"] ?? "?")")
        return (display.url!.absoluteString, task)
    }
}

func run() async {
    let args = parseArguments()
    var gatewayTask: URLSessionWebSocketTask?
    var url = args.url ?? ""
    if args.gateway != nil {
        do { (url, gatewayTask) = try await observe(args) } catch { fail("gateway: \(error)") }
    }
    defer { gatewayTask?.cancel(with: .normalClosure, reason: nil) }

    let recording = Recording()
    let transport: any RFBTransport
    do {
        transport = RecordingTransport(try makeTransport(url, args)) { recording.add($0, $1) }
    } catch {
        fail("connect \(redacted(url)): \(error)")
    }
    if !args.headers.isEmpty { log("headers: \(args.headers.map(\.0).joined(separator: ", "))") }

    var options = RFBOptions()
    options.continuousUpdates = args.continuous
    options.pipelineHandshake = args.pipeline
    if let encodings = args.encodings {
        options.encodings = encodings + [.desktopSize, .extendedDesktopSize, .lastRect, .fence, .continuousUpdates, .extendedClipboard]
    }
    if !args.extendedDesktopSize { options.encodings.removeAll { $0 == .extendedDesktopSize } }
    let client = RFBClient(transport: transport, options: options)

    let started = Date()
    let info: ServerInit
    do {
        info = try await client.handshake()
    } catch {
        fail("handshake with \(redacted(url)): \(error)")
    }
    log("connected to \(redacted(url)) in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms")
    log("server: \"\(info.name)\" \(info.width)x\(info.height), native format \(info.pixelFormat == .bgrx ? "= BGRX" : "\(info.pixelFormat)")")

    let progress = Progress()
    let maxUpdates = args.updates
    let runTask = Task {
        do {
        try await client.run { event, fb in
            progress.lock.withLock {
                switch event {
                case .framebufferUpdated(let dirty):
                    progress.updates += 1
                    if progress.firstPicture == nil {
                        progress.firstPicture = Date()
                        progress.events.append(String(format: "first picture after %.0f ms", Date().timeIntervalSince(started) * 1000))
                    }
                    if progress.updates <= 3 { progress.events.append("update: \(dirty.count) rects") }
                    if let asked = progress.cursorRequested, progress.loggedAfterCursor < 2 {
                        progress.loggedAfterCursor += 1
                        progress.events.append(String(format: "update %.0f ms after asking for the cursor: ", Date().timeIntervalSince(asked) * 1000)
                            + dirty.map(\.description).joined(separator: " "))
                    }
                case .serverClipboardCapabilities(let caps):
                    progress.events.append("server clipboard caps: formats \(caps.formats.rawValue), actions \(caps.supportedActions.map { "\($0)" }.sorted()), max sizes \(caps.maxSizes)")
                case .continuousUpdates(let on):
                    progress.events.append("continuous updates \(on ? "on" : "off")")
                case .resized(let w, let h):
                    progress.events.append("resized to \(w)x\(h)")
                case .serverClipboard(let text):
                    progress.events.append("server clipboard: \(text.utf8.count) bytes")
                case .bell:
                    progress.events.append("bell")
                case .cursorShape(let c):
                    let after = progress.cursorRequested.map { String(format: " %.0f ms after asking", Date().timeIntervalSince($0) * 1000) } ?? ""
                    progress.events.append("cursor shape \(c.width)x\(c.height), hotspot \(c.hotspotX),\(c.hotspotY)\(after)")
                }
            }
            _ = fb
        }
        } catch {
            progress.lock.withLock { progress.endError = error }
        }
        progress.lock.withLock { progress.ended = true }
    }

    // Watch until the deadline, the update budget, or the connection ending.
    var pasted = false
    var cursorAsked = false
    while true {
        try? await Task.sleep(nanoseconds: 100_000_000)
        let (first, updates) = progress.lock.withLock { (progress.firstPicture, progress.updates) }
        if first != nil, !pasted {
            pasted = true
            if let paste = args.paste {
                do { try await client.sendClipboard(paste); log("pasted \(paste.utf8.count) bytes to the remote clipboard") }
                catch { log("paste failed: \(error)") }
            }
            if let text = args.type {
                do { try await client.paste(text); log("typed \(text.utf8.count) bytes with clipboard + Ctrl+V") }
                catch { log("typing failed: \(error)") }
            }
        }
        if let after = args.cursorAfter, let first, !cursorAsked, Date().timeIntervalSince(first) >= after {
            cursorAsked = true
            progress.lock.withLock { progress.cursorRequested = Date() }
            do { try await client.setCursorShapeUpdates(true); log("asked for the cursor shape") }
            catch { log("cursor request failed: \(error)") }
            if let (x, y) = args.movePointer {
                // Two moves a moment apart, like a real pointer, ending at (x, y).
                try? await client.sendPointer(x: x - 5, y: y - 5, buttons: [])
                try? await Task.sleep(nanoseconds: 100_000_000)
                try? await client.sendPointer(x: x, y: y, buttons: [])
                log("moved the pointer to \(x),\(y)")
            }
        }
        if let maxUpdates, updates >= maxUpdates { break }
        if let first, Date().timeIntervalSince(first) >= args.seconds { break }
        if first == nil, Date().timeIntervalSince(started) > 30 { log("no picture after 30 s"); break }
        if progress.lock.withLock({ progress.ended }) { break }
    }
    let endedByServer = progress.lock.withLock { progress.ended }
    await client.close(.normal)
    await runTask.value
    let endError = endedByServer ? progress.lock.withLock { progress.endError } : nil

    let fb = await client.framebuffer
    let stats = await client.statistics
    let (received, sent) = recording.streams
    let out = URL(fileURLWithPath: args.out)
    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data(received).write(to: out.appendingPathComponent("server.bin"))
        try Data(sent).write(to: out.appendingPathComponent("client.bin"))
        if fb.width > 0 { try Data(try PNG.encode(fb)).write(to: out.appendingPathComponent("frame.png")) }
    } catch {
        fail("writing \(out.path): \(error)")
    }
    for line in progress.lock.withLock({ progress.events }) { log(line) }
    log("updates: \(stats.updates), received \(stats.bytesReceived) bytes, sent \(stats.bytesSent), fences answered \(stats.fencesAnswered)")
    for (encoding, count) in stats.rects.sorted(by: { $0.key > $1.key }) {
        log("  \(RFBEncoding(rawValue: encoding)): \(count) rects, \(stats.encodedBytes[encoding] ?? 0) bytes")
    }
    if let endError, !(endError is CancellationError) {
        log("connection ended: \(endError)")
    }
    log("wrote \(out.path)/server.bin, client.bin, frame.png")
}

await run()
