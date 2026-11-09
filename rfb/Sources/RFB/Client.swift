/// What the client reports while running.
public enum RFBEvent: Sendable, Equatable {
    /// One FramebufferUpdate message was applied. `dirty` lists the rects that changed (CopyRect
    /// destinations included); after a resize it is the whole screen.
    case framebufferUpdated(dirty: [RFBRect])
    /// The remote screen changed size (DesktopSize / ExtendedDesktopSize). The framebuffer is
    /// now that size and black until the server repaints it, which follows in the same update.
    case resized(width: Int, height: Int)
    case bell
    /// Text the server put on our clipboard. Hermes runs Xvnc with -SendCutText=0, so this never
    /// arrives from a Bot Screen.
    case serverClipboard(String)
    /// The server's extended clipboard capabilities (sent once, right after SetEncodings).
    case serverClipboardCapabilities(ExtendedClipboardMessage)
    /// Continuous updates were switched on or off (TigerVNC's EnableContinuousUpdates).
    case continuousUpdates(Bool)
    /// The pointer's shape, after `setCursorShapeUpdates(true)`: draw it locally at the local
    /// pointer position. Xvnc stops painting the pointer into the picture meanwhile.
    case cursorShape(RFBCursor)
}

/// A pointer image from the Cursor pseudo-encoding, as BGRA with straight alpha (0 or 255).
///
/// Xvnc decides per client: it sends the real shape only while this client is the one moving
/// the pointer (its last PointerEvent is where the pointer is). When someone else moved it (the
/// agent), it paints the pointer into the picture and sends an empty (0x0) cursor: hide the local
/// one then.
public struct RFBCursor: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// The point of the image that sits on the pointer position.
    public var hotspotX: Int
    public var hotspotY: Int
    /// `width * height * 4` bytes, B, G, R, A per pixel; A is 255 where the server's mask is set.
    public var pixels: [UInt8]
}

/// Counters for the probe and for tuning.
public struct RFBStatistics: Sendable, Equatable {
    public var bytesReceived = 0
    public var bytesSent = 0
    public var updates = 0
    /// Rects per encoding (pseudo-encodings included).
    public var rects: [Int32: Int] = [:]
    /// Wire bytes per encoding, rect headers excluded.
    public var encodedBytes: [Int32: Int] = [:]
    public var fencesAnswered = 0
    /// Server fences with more than 64 bytes of payload, skipped unanswered (as TigerVNC does).
    public var fencesSkipped = 0
    /// Keepalive fences of ours the server answered.
    public var keepalivesAnswered = 0
}

/// Input for `RFBClient.post(_:)`. Applied strictly in the order posted.
public enum RFBInput: Sendable, Equatable {
    /// One key going down or up (an X keysym, see `Keysym`).
    case key(UInt32, down: Bool)
    /// Press and release `keysym` while holding `modifiers`.
    case keyPress(UInt32, modifiers: [UInt32])
    /// Pointer at (x, y) in framebuffer pixels with these buttons held.
    case pointer(x: Int, y: Int, buttons: PointerButtons)
    /// One wheel notch at (x, y).
    case scroll(x: Int, y: Int, direction: PointerButtons, held: PointerButtons)
    /// Put text on the remote clipboard.
    case clipboard(String)
    /// Clipboard, then the paste shortcut (Ctrl+V by default).
    case paste(String, shortcut: [UInt32])
}

public struct RFBOptions: Sendable {
    /// ClientInit's shared flag. Hermes' bridge forces it to 1 anyway.
    public var shared = true
    /// Ask Xvnc to push updates without waiting for each request (TigerVNC extension), when the
    /// server offers it. Saves a round trip per frame, which matters over Cloudflare.
    public var continuousUpdates = true
    /// Send our side of the handshake (version 3.8, security None, ClientInit) and the
    /// SetPixelFormat / SetEncodings that follow it in one go, without waiting for each server
    /// step. Our answers are fixed, and Xvnc reads its input as a stream, so this saves about
    /// three round trips before the first picture. A server that wants anything else (another
    /// version, real authentication) fails the handshake either way.
    public var pipelineHandshake = true
    /// Encodings in preference order. Cursor is left out on purpose while only watching: Xvnc
    /// then paints the agent's pointer into the picture.
    public var encodings: [RFBEncoding] = [
        .zrle, .copyRect, .raw,
        .desktopSize, .extendedDesktopSize, .lastRect,
        .fence, .continuousUpdates, .extendedClipboard,
    ]

    /// The largest screen accepted from the server (ServerInit, DesktopSize), per side and in
    /// pixels; the framebuffer is allocated at 4 bytes per pixel. 8K by default.
    public var maxScreenDimension = 8192
    public var maxScreenPixels = 7680 * 4320
    /// The largest pointer image accepted, per side.
    public var maxCursorDimension = 512

    /// Give up (and drop the connection) when the handshake has not finished in this many seconds.
    public var handshakeTimeout: Double = 20
    /// An idle screen sends nothing, so while running the client asks the server for a Fence
    /// answer every `keepaliveInterval` seconds (only once the server has shown it does fences);
    /// no answer within `keepaliveTimeout` seconds counts as a dead connection. 0 turns it off.
    public var keepaliveInterval: Double = 15
    public var keepaliveTimeout: Double = 15
    /// After a send of ours fails, keep reading this many seconds for the reason (the close code
    /// usually waits on the read side), then drop the connection.
    public var sendFailureGrace: Double = 2
    /// How the connection is closed when the task running `handshake` or `run` is cancelled.
    /// `.normal` (1000) tells Hermes' bridge the viewer left, which also hands the lease back.
    public var closeOnCancel: RFBCloseCode = .normal

    public init() {}
}

/// A minimal RFB 3.8 client for TigerVNC behind Hermes' display bridge.
///
/// ```swift
/// let client = RFBClient(transport: transport)
/// let info = try await client.handshake()
/// try await client.run { event, framebuffer in … }     // returns when the connection ends
/// ```
/// Input: `post(_:)` from any thread, applied in order while `run` is going; or the async
/// methods (`sendKey`, `sendPointer`, `paste`, …) when the caller orders them itself. The bridge
/// silently drops input unless this viewer holds the lease.
public actor RFBClient {
    public let options: RFBOptions
    private let transport: any RFBTransport
    private var buffer = ReceiveBuffer()
    private var zrle: ZRLEDecoder?

    public private(set) var serverInit: ServerInit?
    public private(set) var framebuffer = Framebuffer(width: 0, height: 0)
    public private(set) var statistics = RFBStatistics()
    /// The server's extended clipboard caps, if it offered the extension.
    public private(set) var serverClipboardCaps: ExtendedClipboardMessage?
    /// The server answered our ContinuousUpdates pseudo-encoding with EndOfContinuousUpdates.
    public private(set) var serverSupportsContinuousUpdates = false
    public private(set) var continuousUpdatesEnabled = false
    /// Cursor pseudo-encoding currently requested.
    public private(set) var cursorShapeUpdates = false
    private var wantContinuousUpdates: Bool

    /// Text offered with Notify, waiting for the server's Request.
    private var pendingClipboard: String?
    /// Caps have arrived, or the first update did without them (no extended clipboard).
    private var clipboardReady = false
    private var clipboardWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextWaiter = 0

    private var closed = false
    private var running = false
    private var finished = false
    /// SetPixelFormat and SetEncodings already went out with a pipelined handshake.
    private var setupSent = false

    /// The first failed send; the read side usually reports the close soon after.
    private var sendFailure: Error?
    private var graceTask: Task<Void, Never>?
    private var abortedAfterSendFailure = false
    /// Set when our own watchdog (handshake timeout, keepalive) dropped the connection.
    private var deadReason: String?

    private var serverSupportsFence = false
    private var keepaliveSentAt: ContinuousClock.Instant?
    private var keepaliveCounter: UInt8 = 0
    private static let keepaliveMarker: [UInt8] = [0x53, 0x48]  // "SH"

    private nonisolated let inputs: AsyncStream<RFBInput>
    private nonisolated let inputContinuation: AsyncStream<RFBInput>.Continuation

    /// Longest server string kept (refusal reasons, the desktop name); the rest is skipped.
    static let maxStringLength = 4096

    /// To keep the raw byte streams (test samples), wrap the transport in a `RecordingTransport`.
    public init(transport: any RFBTransport, options: RFBOptions = RFBOptions()) {
        self.transport = transport
        self.options = options
        self.wantContinuousUpdates = options.continuousUpdates
        (inputs, inputContinuation) = AsyncStream.makeStream(of: RFBInput.self)
    }

    // MARK: - reading

    private func need(_ count: Int) async throws {
        while buffer.available < count {
            guard let chunk = try await transport.receive() else { throw RFBError.endOfStream }
            statistics.bytesReceived += chunk.count
            buffer.append(chunk)
        }
    }

    private func u8() async throws -> UInt8 { try await need(1); return buffer.u8() }
    private func u16() async throws -> UInt16 { try await need(2); return buffer.u16() }
    private func u32() async throws -> UInt32 { try await need(4); return buffer.u32() }
    private func bytes(_ n: Int) async throws -> [UInt8] { try await need(n); return buffer.take(n) }

    /// Reads and throws away `count` bytes without holding more than one chunk at a time.
    private func discard(_ count: Int) async throws {
        var left = count
        while left > 0 {
            if buffer.available == 0 {
                guard let chunk = try await transport.receive() else { throw RFBError.endOfStream }
                statistics.bytesReceived += chunk.count
                buffer.append(chunk)
            }
            left -= buffer.drop(upTo: left)
        }
    }

    /// A `length`-byte server string, of which at most `maxStringLength` bytes are kept.
    private func string(_ length: Int) async throws -> String {
        let keep = min(length, Self.maxStringLength)
        let text = String(decoding: try await bytes(keep), as: UTF8.self)
        try await discard(length - keep)
        return text
    }

    // MARK: - writing

    /// Sends one client message. Every message we can build is one Hermes' bridge forwards. A
    /// message that cannot be encoded (too large) throws without touching the connection; a
    /// transport failure is also noted, so that the connection ends with its real reason.
    func send(_ message: ClientMessage) async throws {
        let bytes = try message.encoded()
        try await sendBytes(bytes)
    }

    private func sendBytes(_ bytes: [UInt8]) async throws {
        statistics.bytesSent += bytes.count
        do {
            try await transport.send(bytes)
        } catch {
            noteSendFailure(error)
            throw error
        }
    }

    /// For what the client sends by itself (requests, fence answers, clipboard replies). If the
    /// connection is going down, the write side often fails first while the reason (the
    /// bridge's close code) still waits on the read side; so a failed send does not end the
    /// session: reading goes on until the transport reports the close.
    private func sendWhileRunning(_ message: ClientMessage) async {
        try? await send(message)
    }

    /// Remembers the first send failure and, should the read side never say why the connection
    /// ended (half-open), drops it after `sendFailureGrace`. Never with 1000 / 1001: those tell
    /// the bridge we left on purpose and hand the lease back.
    private func noteSendFailure(_ error: Error) {
        guard sendFailure == nil else { return }
        sendFailure = error
        let grace = max(options.sendFailureGrace, 0)
        graceTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(grace)) } catch { return }
            await self?.graceExpired()
        }
    }

    private func graceExpired() async {
        guard !finished else { return }
        abortedAfterSendFailure = true
        await transport.close(.abort)
    }

    /// Drops the connection when a watchdog expires; `ending(_:)` then reports `timedOut`.
    private func expire(_ reason: String) async {
        guard deadReason == nil, !finished else { return }
        deadReason = reason
        await transport.close(.abort)
    }

    private func startWatchdog(after seconds: Double, reason: String) -> Task<Void, Never>? {
        guard seconds > 0 else { return nil }
        return Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.expire(reason)
        }
    }

    /// Runs `body`; if the calling task is cancelled meanwhile, closes the transport with
    /// `options.closeOnCancel`, which also ends whatever `body` is waiting for.
    private func closingOnCancel<T>(_ body: () async throws -> T) async throws -> T {
        let transport = self.transport
        let code = options.closeOnCancel
        return try await withTaskCancellationHandler {
            try await body()
        } onCancel: {
            Task { await transport.close(code) }
        }
    }

    /// Why the connection ended, from what the read side threw: cancellation first, then a close
    /// code from the server, then our own watchdogs, then a send that failed before the read
    /// side stopped without a reason.
    private func ending(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let closed = error as? RFBConnectionClosed, closed.code != nil { return closed }
        if let deadReason { return RFBError.timedOut(deadReason) }
        if let sendFailure {
            if abortedAfterSendFailure { return sendFailure }
            if case RFBError.endOfStream = error { return sendFailure }
            if let closed = error as? RFBConnectionClosed, closed.code == nil { return sendFailure }
        }
        return error
    }

    /// After the session ended (or failed before it began): stop timers, wake waiters, refuse
    /// further input.
    private func finish() {
        finished = true
        running = false
        graceTask?.cancel()
        inputContinuation.finish()
        let waiters = clipboardWaiters
        clipboardWaiters = [:]
        for (_, waiter) in waiters { waiter.resume(throwing: RFBError.endOfStream) }
    }

    // MARK: - handshake

    /// Version 3.8, security type None, ClientInit, ServerInit. Gives up after
    /// `options.handshakeTimeout`; cancelling the calling task closes the connection.
    @discardableResult
    public func handshake() async throws -> ServerInit {
        if let serverInit { return serverInit }
        let watchdog = startWatchdog(after: options.handshakeTimeout,
                                     reason: "no handshake within \(Int(options.handshakeTimeout)) s")
        defer { watchdog?.cancel() }
        do {
            return try await closingOnCancel { try await handshakeSteps() }
        } catch {
            finish()
            throw ending(error)
        }
    }

    private func handshakeSteps() async throws -> ServerInit {
        let version = Array("RFB 003.008\n".utf8)
        let shared: UInt8 = options.shared ? 1 : 0
        // A failed send here does not end the handshake: if the bridge refused us (a used ticket:
        // 4401; no screen: 4001), the reason is on the read side.
        if options.pipelineHandshake {
            let setup = try ClientMessage.setPixelFormat(.bgrx).encoded() + ClientMessage.setEncodings(options.encodings).encoded()
            try? await sendBytes(version + [1, shared] + setup)
            setupSent = true
        }

        let serverVersion = String(decoding: try await bytes(12), as: UTF8.self)
        guard serverVersion.hasPrefix("RFB "), serverVersion.hasSuffix("\n"),
              let major = Int(serverVersion.dropFirst(4).prefix(3)), let minor = Int(serverVersion.dropFirst(8).prefix(3)),
              major > 3 || (major == 3 && minor >= 8) else {
            throw RFBError.unsupportedVersion(String(serverVersion.prefix(11)))
        }
        if !options.pipelineHandshake { try? await sendBytes(version) }

        let count = Int(try await u8())
        if count == 0 {
            let length = Int(try await u32())
            throw RFBError.connectionRefused(try await string(length))
        }
        let types = try await bytes(count)
        guard types.contains(1) else { throw RFBError.unsupportedSecurity(types) }
        if !options.pipelineHandshake { try? await sendBytes([1]) }
        let result = try await u32()
        if result != 0 {
            let length = Int(try await u32())
            throw RFBError.securityFailed(try await string(length))
        }

        if !options.pipelineHandshake { try? await sendBytes([shared]) }
        let width = Int(try await u16())
        let height = Int(try await u16())
        let format = PixelFormat(try await bytes(16))
        let nameLength = Int(try await u32())
        let name = try await string(nameLength)
        try checkScreen(width, height)
        let info = ServerInit(width: width, height: height, pixelFormat: format, name: name)
        serverInit = info
        framebuffer = Framebuffer(width: width, height: height)
        return info
    }

    private func checkScreen(_ width: Int, _ height: Int) throws {
        guard width <= options.maxScreenDimension, height <= options.maxScreenDimension,
              width * height <= options.maxScreenPixels else {
            throw RFBError.limitExceeded("screen \(width)x\(height)")
        }
    }

    // MARK: - running

    /// Asks for our pixel format and encodings, requests the whole screen and processes server
    /// messages until the connection ends, which it reports by throwing: `RFBConnectionClosed`
    /// for a WebSocket close (with the bridge's code when there was one), `RFBError.timedOut`
    /// when the keepalive found the connection dead, `CancellationError` when the calling task
    /// was cancelled (the connection is then closed with `options.closeOnCancel`). A failed send
    /// does not end it early: the read side's reason wins (see `sendFailureGrace`).
    ///
    /// `onEvent` runs on this actor, with the framebuffer as it is right after the event. Call
    /// `run` once per client.
    public func run(onEvent: @Sendable (RFBEvent, Framebuffer) -> Void = { _, _ in }) async throws {
        guard !running, !finished else { throw RFBError.refusedToSend("run() is called once per client") }
        if serverInit == nil { try await handshake() }
        running = true
        defer { finish() }
        do {
            try await closingOnCancel {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { await self.pumpInput() }
                    if self.options.keepaliveInterval > 0 {
                        group.addTask { await self.keepaliveLoop() }
                    }
                    try await self.readLoop(onEvent)
                }
            }
        } catch {
            throw ending(error)
        }
    }

    private func readLoop(_ onEvent: @Sendable (RFBEvent, Framebuffer) -> Void) async throws {
        if !setupSent {
            await sendWhileRunning(.setPixelFormat(.bgrx))
            await sendWhileRunning(.setEncodings(options.encodings))
            setupSent = true
        }
        await sendWhileRunning(fullUpdateRequest(incremental: false))

        while true {
            let type = try await u8()
            switch type {
            case 0: try await framebufferUpdate(onEvent)
            case 1: try await colourMapEntries()
            case 2: onEvent(.bell, framebuffer)
            case 3: try await serverCutText(onEvent)
            case 150: try await endOfContinuousUpdates(onEvent)
            case 248: try await serverFence()
            default: throw RFBError.unknownServerMessage(type)
            }
        }
    }

    private func keepaliveLoop() async {
        let interval = options.keepaliveInterval
        while true {
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            await keepaliveTick()
        }
    }

    /// One keepalive step: a fence of ours still unanswered after `keepaliveTimeout` means the
    /// connection is dead; otherwise ask again. Only once the server has shown it does fences.
    private func keepaliveTick() async {
        guard serverSupportsFence, deadReason == nil, !finished else { return }
        if let sent = keepaliveSentAt {
            if ContinuousClock.now - sent >= .seconds(options.keepaliveTimeout) {
                await expire("no keepalive answer within \(Int(options.keepaliveTimeout)) s")
            }
            return
        }
        keepaliveCounter &+= 1
        keepaliveSentAt = .now
        await sendWhileRunning(.fence(flags: [.request], payload: Self.keepaliveMarker + [keepaliveCounter]))
    }

    /// Closes the connection. `.normal` (1000) tells the bridge we left on purpose, which also
    /// hands the lease back; `.abort` drops it like a network failure, keeping the lease.
    public func close(_ code: RFBCloseCode = .normal) async {
        guard !closed else { return }
        closed = true
        await transport.close(code)
    }

    private var fullScreen: (UInt16, UInt16) {
        (UInt16(clamping: framebuffer.width), UInt16(clamping: framebuffer.height))
    }

    /// Requests an update of the whole screen. Only needed when continuous updates are off;
    /// `incremental: false` repaints everything.
    public func requestUpdate(incremental: Bool) async throws {
        try await send(fullUpdateRequest(incremental: incremental))
    }

    private func fullUpdateRequest(incremental: Bool) -> ClientMessage {
        let (w, h) = fullScreen
        return .framebufferUpdateRequest(incremental: incremental, x: 0, y: 0, width: w, height: h)
    }

    /// Whether the pointer comes as a shape to draw locally (Cursor pseudo-encoding) or is painted
    /// into the picture by Xvnc (the default, so a watcher sees where the agent points). Turn it on
    /// at takeover, so the local pointer does not lag behind the network, and off on hand-back.
    /// Re-sends SetEncodings; Xvnc answers at once, but with an empty cursor until our own
    /// PointerEvents move the pointer (see `RFBCursor`).
    public func setCursorShapeUpdates(_ on: Bool) async throws {
        var encodings = options.encodings.filter { $0 != .cursor }
        if on { encodings.append(.cursor) }
        try await send(.setEncodings(encodings))
        cursorShapeUpdates = on
    }

    /// Turns continuous updates on or off (when the server supports them). Off falls back to one
    /// request per update. To stop the picture entirely (window hidden), close the connection:
    /// an open viewer counts as "someone is watching" on the server.
    public func setContinuousUpdates(_ on: Bool) async throws {
        wantContinuousUpdates = on
        guard serverSupportsContinuousUpdates, on != continuousUpdatesEnabled else { return }
        let (w, h) = fullScreen
        try await send(.enableContinuousUpdates(enable: on, x: 0, y: 0, width: w, height: h))
        if on { continuousUpdatesEnabled = true }
        // Turning off completes when the server answers with EndOfContinuousUpdates.
    }

    private func framebufferUpdate(_ onEvent: @Sendable (RFBEvent, Framebuffer) -> Void) async throws {
        try await need(3)
        _ = buffer.u8()
        let count = Int(buffer.u16())
        var dirty: [RFBRect] = []
        var resized = false
        // count 0xFFFF: "until LastRect" (the LastRect pseudo-encoding).
        var index = 0
        rects: while count == 0xFFFF || index < count {
            index += 1
            try await need(12)
            let r = RFBRect(x: Int(buffer.u16()), y: Int(buffer.u16()), width: Int(buffer.u16()), height: Int(buffer.u16()))
            let encoding = Int32(bitPattern: buffer.u32())
            statistics.rects[encoding, default: 0] += 1
            let before = statistics.bytesReceived - buffer.available
            switch RFBEncoding(rawValue: encoding) {
            case .raw:
                try framebuffer.check(r)
                let data = try await bytes(r.width * r.height * Framebuffer.bytesPerPixel)
                try framebuffer.blit(data, into: r)
                dirty.append(r)
            case .copyRect:
                let sx = Int(try await u16()), sy = Int(try await u16())
                try framebuffer.copy(from: sx, sy, to: r)
                dirty.append(r)
            case .zrle:
                try framebuffer.check(r)
                let length = Int(try await u32())
                guard length <= ZRLEDecoder.maxCompressed(r) else {
                    throw RFBError.limitExceeded("ZRLE rect \(r) with \(length) compressed bytes")
                }
                let data = try await bytes(length)
                if zrle == nil { zrle = try ZRLEDecoder() }
                try zrle!.decode(data, rect: r, into: &framebuffer)
                dirty.append(r)
            case .desktopSize:
                try await resize(width: r.width, height: r.height, onEvent)
                resized = true
            case .extendedDesktopSize:
                // x = reason, y = status (non-zero: our SetDesktopSize failed; we never send one).
                let screens = Int(try await u8())
                try await need(3 + 16 * screens)
                _ = buffer.take(3 + 16 * screens)
                if r.y == 0 {
                    try await resize(width: r.width, height: r.height, onEvent)
                    resized = true
                }
            case .lastRect:
                break rects
            case .cursor:
                // x, y = hotspot; then width*height pixels and a 1-bit mask, rows padded to bytes.
                guard r.width <= options.maxCursorDimension, r.height <= options.maxCursorDimension else {
                    throw RFBError.limitExceeded("cursor \(r.width)x\(r.height)")
                }
                if r.width > 0 && r.height > 0 && (r.x >= r.width || r.y >= r.height) {
                    throw RFBError.protocolViolation("cursor hotspot \(r.x),\(r.y) outside its \(r.width)x\(r.height) image")
                }
                let pixels = try await bytes(r.width * r.height * Framebuffer.bytesPerPixel)
                let rowMask = (r.width + 7) / 8
                let mask = try await bytes(rowMask * r.height)
                var bgra = pixels
                for y in 0..<r.height {
                    for x in 0..<r.width {
                        let on = mask[y * rowMask + x / 8] & (0x80 >> UInt8(x % 8)) != 0
                        bgra[(y * r.width + x) * 4 + 3] = on ? 255 : 0
                    }
                }
                onEvent(.cursorShape(RFBCursor(width: r.width, height: r.height, hotspotX: r.x, hotspotY: r.y, pixels: bgra)), framebuffer)
            default:
                throw RFBError.unsupportedEncoding(encoding)
            }
            statistics.encodedBytes[encoding, default: 0] += statistics.bytesReceived - buffer.available - before
        }
        statistics.updates += 1
        if resized { dirty = [RFBRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)] }
        onEvent(.framebufferUpdated(dirty: dirty), framebuffer)
        // Xvnc sends its clipboard caps right after SetEncodings, before any update: if none came
        // by now, the server has no extended clipboard.
        markClipboardReady()
        if !continuousUpdatesEnabled {
            await sendWhileRunning(fullUpdateRequest(incremental: true))
        }
    }

    private func resize(width: Int, height: Int, _ onEvent: @Sendable (RFBEvent, Framebuffer) -> Void) async throws {
        guard width != framebuffer.width || height != framebuffer.height else { return }
        try checkScreen(width, height)
        framebuffer.resize(width: width, height: height)
        onEvent(.resized(width: width, height: height), framebuffer)
        if continuousUpdatesEnabled {
            // The continuous-update area was the old screen; widen it to the new one.
            let (w, h) = fullScreen
            await sendWhileRunning(.enableContinuousUpdates(enable: true, x: 0, y: 0, width: w, height: h))
        }
    }

    private func colourMapEntries() async throws {
        // Only sent for colour-mapped formats, which we never ask for; skip it to stay in sync.
        try await need(5)
        _ = buffer.take(3)
        let n = Int(buffer.u16())
        try await discard(6 * n)
    }

    private func serverCutText(_ onEvent: @Sendable (RFBEvent, Framebuffer) -> Void) async throws {
        try await need(7)
        _ = buffer.take(3)
        let length = Int32(bitPattern: buffer.u32())
        let size = Int(length.magnitude)
        guard size <= ClientMessage.maxCutText else {
            // Larger than anything the bridge lets through the other way: skip it, holding no
            // more than a chunk at a time. (Hermes runs -SendCutText=0, so this never happens.)
            try await discard(size)
            return
        }
        if length >= 0 {
            let text = try await bytes(size)
            // Classic cut text is Latin-1.
            onEvent(.serverClipboard(String(text.map { Character(Unicode.Scalar($0)) })), framebuffer)
            return
        }
        let payload = try await bytes(size)
        let message: ExtendedClipboardMessage
        do {
            message = try ExtendedClipboardMessage.decode(payload)
        } catch RFBError.limitExceeded {
            return  // inflates past the limit: dropped
        }
        switch message.action {
        case .caps:
            serverClipboardCaps = message
            await sendWhileRunning(.extendedClipboard(Self.clientClipboardCaps))
            onEvent(.serverClipboardCapabilities(message), framebuffer)
            markClipboardReady()
        case .request:
            // Xvnc asks for the text we announced (an X client is pasting).
            if message.formats.contains(.text), let text = pendingClipboard {
                await sendWhileRunning(.extendedClipboard(.provide(text: text)))
            }
        case .notify:
            // The server has new clipboard data; ask for it. (Never with SendCutText=0.)
            if message.formats.contains(.text) {
                await sendWhileRunning(.extendedClipboard(.request(.text)))
            }
        case .provide:
            if let text = message.text { onEvent(.serverClipboard(text), framebuffer) }
        case .peek:
            // "Do you still have data?": answer with what we offer.
            await sendWhileRunning(.extendedClipboard(.notify(pendingClipboard == nil ? [] : .text)))
        }
    }

    private func endOfContinuousUpdates(_ onEvent: @Sendable (RFBEvent, Framebuffer) -> Void) async throws {
        // The first one only says the server supports the extension; later ones confirm "off".
        let wasEnabled = continuousUpdatesEnabled
        serverSupportsContinuousUpdates = true
        continuousUpdatesEnabled = false
        if wasEnabled {
            onEvent(.continuousUpdates(false), framebuffer)
            await sendWhileRunning(fullUpdateRequest(incremental: true))
        }
        if wantContinuousUpdates && !wasEnabled {
            let (w, h) = fullScreen
            await sendWhileRunning(.enableContinuousUpdates(enable: true, x: 0, y: 0, width: w, height: h))
            continuousUpdatesEnabled = true
            onEvent(.continuousUpdates(true), framebuffer)
        }
    }

    private func serverFence() async throws {
        try await need(8)
        _ = buffer.take(3)
        let flags = FenceFlags(rawValue: buffer.u32())
        let length = Int(buffer.u8())
        // The Fence extension allows at most 64 bytes. TigerVNC skips a longer fence unanswered
        // and carries on (CMsgReader::readFence), and so do we: it is at most 255 bytes, and
        // ending the session over it would drop a connection that otherwise works.
        guard length <= 64 else {
            try await discard(length)
            statistics.fencesSkipped += 1
            return
        }
        let payload = try await bytes(length)
        serverSupportsFence = true
        guard flags.contains(.request) else {
            // An answer to one of ours: the keepalive.
            if payload.starts(with: Self.keepaliveMarker) {
                keepaliveSentAt = nil
                statistics.keepalivesAnswered += 1
            }
            return
        }
        // We handle messages strictly in order, so BlockBefore / BlockAfter hold by construction.
        // SyncNext is not supported, so it is left out of the answer (as noVNC does).
        await sendWhileRunning(.fence(flags: flags.intersection([.blockBefore, .blockAfter]), payload: payload))
        statistics.fencesAnswered += 1
    }

    // MARK: - input (only reaches Xvnc while this viewer holds the lease)

    /// Queues input to be sent in exactly this order while `run` is going (and anything posted
    /// before `run` starts once it does). Safe to call from any thread, e.g. for every NSEvent.
    /// Fire and forget: input the bridge or the size limit refuses is dropped; check a paste
    /// with `clipboardFits(_:)` first.
    public nonisolated func post(_ input: RFBInput) {
        inputContinuation.yield(input)
    }

    private func pumpInput() async {
        for await input in inputs {
            do {
                try await perform(input)
            } catch {
                // Dropped; a transport failure was noted by send() and ends the session.
            }
        }
    }

    private func perform(_ input: RFBInput) async throws {
        switch input {
        case .key(let keysym, let down): try await sendKey(keysym, down: down)
        case .keyPress(let keysym, let modifiers): try await sendKeyPress(keysym, modifiers: modifiers)
        case .pointer(let x, let y, let buttons): try await sendPointer(x: x, y: y, buttons: buttons)
        case .scroll(let x, let y, let direction, let held): try await sendScroll(x: x, y: y, direction: direction, held: held)
        case .clipboard(let text): try await sendClipboard(text)
        case .paste(let text, let shortcut): try await paste(text, shortcut: shortcut)
        }
    }

    public func sendKey(_ keysym: UInt32, down: Bool) async throws {
        try await send(.keyEvent(down: down, keysym: keysym))
    }

    /// Presses and releases `keysym` while holding `modifiers` (keysyms, pressed in order and
    /// released in reverse), e.g. `sendKeyPress(0x76, modifiers: [Keysym.controlLeft])` for Ctrl+V.
    public func sendKeyPress(_ keysym: UInt32, modifiers: [UInt32] = []) async throws {
        for m in modifiers { try await sendKey(m, down: true) }
        try await sendKey(keysym, down: true)
        try await sendKey(keysym, down: false)
        for m in modifiers.reversed() { try await sendKey(m, down: false) }
    }

    /// Types `text` where the remote cursor is: puts it on the remote clipboard, then presses
    /// Ctrl+V. How ⌘V and committed input-method text reach the screen. The remote program asks
    /// Xvnc for the text when it handles Ctrl+V, so keep the connection open until it has.
    /// (In a terminal, Ctrl+V does not paste; that needs Ctrl+Shift+V.)
    public func paste(_ text: String, shortcut: [UInt32] = [Keysym.controlLeft]) async throws {
        try await sendClipboard(text)
        try await sendKeyPress(0x76, modifiers: shortcut)  // "v"
    }

    /// `x`, `y` in framebuffer pixels; clamped to the screen.
    public func sendPointer(x: Int, y: Int, buttons: PointerButtons) async throws {
        let px = UInt16(clamping: min(max(x, 0), max(framebuffer.width - 1, 0)))
        let py = UInt16(clamping: min(max(y, 0), max(framebuffer.height - 1, 0)))
        try await send(.pointerEvent(buttons: buttons, x: px, y: py))
    }

    /// One wheel notch: press and release the wheel "button" at (x, y), keeping `held` pressed.
    public func sendScroll(x: Int, y: Int, direction: PointerButtons, held: PointerButtons = []) async throws {
        try await sendPointer(x: x, y: y, buttons: held.union(direction))
        try await sendPointer(x: x, y: y, buttons: held)
    }

    /// Whether `text` fits through the bridge as one clipboard message (256 KiB, on the wire and
    /// unpacked).
    public static func clipboardFits(_ text: String) -> Bool {
        (try? ClientMessage.extendedClipboard(.provide(text: text)).encoded()) != nil
    }

    /// Puts `text` on the remote clipboard (then send Ctrl+V to paste it). First waits until `run`
    /// knows the server's clipboard caps (right after the handshake). With the extended clipboard the text
    /// is announced and handed over as UTF-8 when Xvnc asks for it; without it, only Latin-1
    /// text can go (as classic cut text), anything else throws `refusedToSend` rather than
    /// arriving garbled. Also throws `refusedToSend` over the bridge's 256 KiB limit.
    public func sendClipboard(_ text: String) async throws {
        try await waitForClipboardReady()
        if let caps = serverClipboardCaps, caps.formats.contains(.text),
           caps.supportedActions.contains(.notify) || caps.supportedActions.contains(.provide) {
            // Check the size limit before announcing anything.
            _ = try ClientMessage.extendedClipboard(.provide(text: text)).encoded()
            pendingClipboard = text
            if caps.supportedActions.contains(.notify) {
                // Our caps first: the bridge drops ClientCutText while we only watch, so the ones
                // a watcher sent at connect never reached Xvnc. Re-sending them is harmless.
                try await send(.extendedClipboard(Self.clientClipboardCaps))
                try await send(.extendedClipboard(.notify(.text)))
            } else {
                try await send(.extendedClipboard(.provide(text: text)))
            }
        } else {
            guard text.unicodeScalars.allSatisfy({ $0.value < 256 }) else {
                throw RFBError.refusedToSend("text outside Latin-1 needs the extended clipboard, which the server did not offer")
            }
            try await send(.clientCutText(latin1: text.unicodeScalars.map { UInt8($0.value) }))
        }
    }

    private func markClipboardReady() {
        guard !clipboardReady else { return }
        clipboardReady = true
        let waiters = clipboardWaiters
        clipboardWaiters = [:]
        for (_, waiter) in waiters { waiter.resume() }
    }

    /// Waits until `run` has learned whether the server has the extended clipboard. Called
    /// before `run` started, it waits for it (cancel the task to stop waiting).
    private func waitForClipboardReady() async throws {
        if clipboardReady { return }
        guard !finished else { throw RFBError.refusedToSend("the session has ended") }
        let id = nextWaiter
        nextWaiter += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                clipboardWaiters[id] = c
            }
        } onCancel: {
            Task { await self.cancelClipboardWaiter(id) }
        }
    }

    private func cancelClipboardWaiter(_ id: Int) {
        clipboardWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Text only; we accept server clipboard data up to the bridge's limit.
    public static let clientClipboardCaps = ExtendedClipboardMessage.caps(
        formats: .text, actions: [.request, .notify, .provide], maxSizes: [UInt32(ClientMessage.maxCutText)])
}
