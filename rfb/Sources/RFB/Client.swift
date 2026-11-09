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
}

public struct RFBOptions: Sendable {
    /// ClientInit's shared flag. Hermes' bridge forces it to 1 anyway.
    public var shared = true
    /// Ask Xvnc to push updates without waiting for each request (TigerVNC extension), when the
    /// server offers it. Saves a round trip per frame, which matters over Cloudflare.
    public var continuousUpdates = true
    /// Encodings in preference order. Cursor is left out on purpose while only watching: Xvnc
    /// then paints the agent's pointer into the picture.
    public var encodings: [RFBEncoding] = [
        .zrle, .copyRect, .raw,
        .desktopSize, .extendedDesktopSize, .lastRect,
        .fence, .continuousUpdates, .extendedClipboard,
    ]
    public init() {}
}

/// A minimal RFB 3.8 client for TigerVNC behind Hermes' display bridge.
///
/// ```swift
/// let client = RFBClient(transport: transport)
/// let info = try await client.handshake()
/// try await client.run { event, framebuffer in … }     // returns when the connection ends
/// ```
/// Input methods (`sendKey`, `sendPointer`, `sendClipboard`) may be called from any task while
/// `run` is going. The bridge silently drops them unless this viewer holds the lease.
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
    private var wantContinuousUpdates: Bool
    /// Text offered with Notify, waiting for the server's Request.
    private var pendingClipboard: String?
    private var closed = false

    /// To keep the raw byte streams (test samples), wrap the transport in a `RecordingTransport`.
    public init(transport: any RFBTransport, options: RFBOptions = RFBOptions()) {
        self.transport = transport
        self.options = options
        self.wantContinuousUpdates = options.continuousUpdates
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
    private func string(_ n: Int) async throws -> String { String(decoding: try await bytes(n), as: UTF8.self) }

    // MARK: - writing

    /// Sends one client message. Every message we can build is one Hermes' bridge forwards.
    public func send(_ message: ClientMessage) async throws {
        let bytes = try message.encoded()
        statistics.bytesSent += bytes.count
        try await transport.send(bytes)
    }

    // MARK: - handshake

    /// Version 3.8, security type None, ClientInit, ServerInit.
    @discardableResult
    public func handshake() async throws -> ServerInit {
        let version = try await string(12)
        guard version.hasPrefix("RFB "), version.hasSuffix("\n"),
              let major = Int(version.dropFirst(4).prefix(3)), let minor = Int(version.dropFirst(8).prefix(3)),
              major > 3 || (major == 3 && minor >= 8) else {
            throw RFBError.unsupportedVersion(String(version.prefix(11)))
        }
        try await transport.send(Array("RFB 003.008\n".utf8))
        statistics.bytesSent += 12

        let count = Int(try await u8())
        if count == 0 {
            let length = Int(try await u32())
            throw RFBError.connectionRefused(try await string(length))
        }
        let types = try await bytes(count)
        guard types.contains(1) else { throw RFBError.unsupportedSecurity(types) }
        try await transport.send([1])
        let result = try await u32()
        if result != 0 {
            let length = Int(try await u32())
            throw RFBError.securityFailed(try await string(length))
        }

        try await transport.send([options.shared ? 1 : 0])
        statistics.bytesSent += 2
        let width = Int(try await u16())
        let height = Int(try await u16())
        let format = PixelFormat(try await bytes(16))
        let nameLength = Int(try await u32())
        let name = try await string(nameLength)
        let info = ServerInit(width: width, height: height, pixelFormat: format, name: name)
        serverInit = info
        framebuffer = Framebuffer(width: width, height: height)
        return info
    }

    // MARK: - running

    /// Asks for our pixel format and encodings, requests the whole screen and processes server
    /// messages until the connection ends, which it reports by throwing (`RFBConnectionClosed`
    /// for a WebSocket close, `RFBError.endOfStream` for EOF). `onEvent` runs on this actor, with
    /// the framebuffer as it is right after the event.
    public func run(onEvent: @Sendable (RFBEvent, Framebuffer) -> Void = { _, _ in }) async throws {
        if serverInit == nil { try await handshake() }
        try await send(.setPixelFormat(.bgrx))
        try await send(.setEncodings(options.encodings))
        try await requestUpdate(incremental: false)

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

    /// Closes the connection. `.normal` (1000) tells the bridge we left on purpose, which also
    /// hands the lease back.
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
        let (w, h) = fullScreen
        try await send(.framebufferUpdateRequest(incremental: incremental, x: 0, y: 0, width: w, height: h))
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
                let length = Int(try await u32())
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
            default:
                throw RFBError.unsupportedEncoding(encoding)
            }
            statistics.encodedBytes[encoding, default: 0] += statistics.bytesReceived - buffer.available - before
        }
        statistics.updates += 1
        if resized { dirty = [RFBRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)] }
        onEvent(.framebufferUpdated(dirty: dirty), framebuffer)
        if !continuousUpdatesEnabled {
            try await requestUpdate(incremental: true)
        }
    }

    private func resize(width: Int, height: Int, _ onEvent: @Sendable (RFBEvent, Framebuffer) -> Void) async throws {
        guard width != framebuffer.width || height != framebuffer.height else { return }
        framebuffer.resize(width: width, height: height)
        onEvent(.resized(width: width, height: height), framebuffer)
        if continuousUpdatesEnabled {
            // The continuous-update area was the old screen; widen it to the new one.
            let (w, h) = fullScreen
            try await send(.enableContinuousUpdates(enable: true, x: 0, y: 0, width: w, height: h))
        }
    }

    private func colourMapEntries() async throws {
        // Only sent for colour-mapped formats, which we never ask for; skip it to stay in sync.
        try await need(5)
        _ = buffer.take(3)
        let n = Int(buffer.u16())
        _ = try await bytes(6 * n)
    }

    private func serverCutText(_ onEvent: @Sendable (RFBEvent, Framebuffer) -> Void) async throws {
        try await need(7)
        _ = buffer.take(3)
        let length = Int32(bitPattern: buffer.u32())
        if length >= 0 {
            let text = try await bytes(Int(length))
            // Classic cut text is Latin-1.
            onEvent(.serverClipboard(String(text.map { Character(Unicode.Scalar($0)) })), framebuffer)
            return
        }
        let payload = try await bytes(Int(length.magnitude))
        let message = try ExtendedClipboardMessage.decode(payload)
        switch message.action {
        case .caps:
            serverClipboardCaps = message
            try await send(.extendedClipboard(Self.clientClipboardCaps))
            onEvent(.serverClipboardCapabilities(message), framebuffer)
        case .request:
            // Xvnc asks for the text we announced (an X client is pasting).
            if message.formats.contains(.text), let text = pendingClipboard {
                try await send(.extendedClipboard(.provide(text: text)))
            }
        case .notify:
            // The server has new clipboard data; ask for it. (Never with SendCutText=0.)
            if message.formats.contains(.text) {
                try await send(.extendedClipboard(.request(.text)))
            }
        case .provide:
            if let text = message.text { onEvent(.serverClipboard(text), framebuffer) }
        case .peek:
            // "Do you still have data?": answer with what we offer.
            try await send(.extendedClipboard(.notify(pendingClipboard == nil ? [] : .text)))
        }
    }

    private func endOfContinuousUpdates(_ onEvent: @Sendable (RFBEvent, Framebuffer) -> Void) async throws {
        // The first one only says the server supports the extension; later ones confirm "off".
        let wasEnabled = continuousUpdatesEnabled
        serverSupportsContinuousUpdates = true
        continuousUpdatesEnabled = false
        if wasEnabled {
            onEvent(.continuousUpdates(false), framebuffer)
            try await requestUpdate(incremental: true)
        }
        if wantContinuousUpdates && !wasEnabled {
            let (w, h) = fullScreen
            try await send(.enableContinuousUpdates(enable: true, x: 0, y: 0, width: w, height: h))
            continuousUpdatesEnabled = true
            onEvent(.continuousUpdates(true), framebuffer)
        }
    }

    private func serverFence() async throws {
        try await need(8)
        _ = buffer.take(3)
        let flags = FenceFlags(rawValue: buffer.u32())
        let length = Int(buffer.u8())
        let payload = try await bytes(length)
        guard flags.contains(.request) else { return }  // an answer to a fence of ours; we send none
        // We handle messages strictly in order, so BlockBefore / BlockAfter hold by construction.
        // SyncNext is not supported, so it is left out of the answer (as noVNC does).
        try await send(.fence(flags: flags.intersection([.blockBefore, .blockAfter]), payload: payload))
        statistics.fencesAnswered += 1
    }

    // MARK: - input (only reaches Xvnc while this viewer holds the lease)

    public func sendKey(_ keysym: UInt32, down: Bool) async throws {
        try await send(.keyEvent(down: down, keysym: keysym))
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

    /// Puts `text` on the remote clipboard (then send Ctrl+V to paste it). With the extended
    /// clipboard, the text is announced and handed over when Xvnc asks for it, as UTF-8; without
    /// it, it goes as Latin-1 cut text (other characters become "?"). Throws
    /// `RFBError.refusedToSend` when the message would exceed the bridge's 256 KiB limit.
    public func sendClipboard(_ text: String) async throws {
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
            let latin1 = text.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }
            try await send(.clientCutText(latin1: latin1))
        }
    }

    /// Text only; we accept server clipboard data up to the bridge's limit.
    public static let clientClipboardCaps = ExtendedClipboardMessage.caps(
        formats: .text, actions: [.request, .notify, .provide], maxSizes: [UInt32(ClientMessage.maxCutText)])
}
