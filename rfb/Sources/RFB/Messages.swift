/// RFB encoding numbers (RFC 6143 §7.7, plus the TigerVNC extensions we use).
public struct RFBEncoding: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let raw = RFBEncoding(rawValue: 0)
    public static let copyRect = RFBEncoding(rawValue: 1)
    public static let zrle = RFBEncoding(rawValue: 16)
    // pseudo-encodings
    public static let desktopSize = RFBEncoding(rawValue: -223)
    public static let lastRect = RFBEncoding(rawValue: -224)
    /// Cursor shape. Not advertised while only watching, so Xvnc paints the agent's pointer into
    /// the picture; turned on at takeover (a later stage).
    public static let cursor = RFBEncoding(rawValue: -239)
    public static let extendedDesktopSize = RFBEncoding(rawValue: -308)
    public static let fence = RFBEncoding(rawValue: -312)
    public static let continuousUpdates = RFBEncoding(rawValue: -313)
    public static let extendedClipboard = RFBEncoding(rawValue: Int32(bitPattern: 0xC0A1_E5CE))
    /// Compression level 0–9 (-256 … -247) and JPEG quality 0–9 (-32 … -23): only used by Tight.
    public static func compressLevel(_ level: Int32) -> RFBEncoding { RFBEncoding(rawValue: -256 + level) }

    public var description: String {
        switch self {
        case .raw: "Raw"
        case .copyRect: "CopyRect"
        case .zrle: "ZRLE"
        case .desktopSize: "DesktopSize"
        case .lastRect: "LastRect"
        case .cursor: "Cursor"
        case .extendedDesktopSize: "ExtendedDesktopSize"
        case .fence: "Fence"
        case .continuousUpdates: "ContinuousUpdates"
        case .extendedClipboard: "ExtendedClipboard"
        default: "encoding(\(rawValue))"
        }
    }
}

/// The pixel format the client always asks for: 32 bits per pixel, depth 24, little-endian true
/// colour, red at bit 16, green at 8, blue at 0. In memory that is B, G, R, X — what CoreGraphics
/// calls 32-bit little-endian with alpha skipped first, and what IOSurface / CVPixelBuffer call BGRA.
/// It is also Xvnc's native format at -depth 24, so the server converts nothing.
public struct PixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndian: Bool
    public var trueColour: Bool
    public var redMax: UInt16, greenMax: UInt16, blueMax: UInt16
    public var redShift: UInt8, greenShift: UInt8, blueShift: UInt8

    public static let bgrx = PixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: false, trueColour: true,
                                         redMax: 255, greenMax: 255, blueMax: 255,
                                         redShift: 16, greenShift: 8, blueShift: 0)

    init(bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool, trueColour: Bool,
         redMax: UInt16, greenMax: UInt16, blueMax: UInt16,
         redShift: UInt8, greenShift: UInt8, blueShift: UInt8) {
        self.bitsPerPixel = bitsPerPixel; self.depth = depth
        self.bigEndian = bigEndian; self.trueColour = trueColour
        self.redMax = redMax; self.greenMax = greenMax; self.blueMax = blueMax
        self.redShift = redShift; self.greenShift = greenShift; self.blueShift = blueShift
    }

    init(_ b: [UInt8]) {
        precondition(b.count == 16)
        bitsPerPixel = b[0]; depth = b[1]; bigEndian = b[2] != 0; trueColour = b[3] != 0
        redMax = UInt16(b[4]) << 8 | UInt16(b[5])
        greenMax = UInt16(b[6]) << 8 | UInt16(b[7])
        blueMax = UInt16(b[8]) << 8 | UInt16(b[9])
        redShift = b[10]; greenShift = b[11]; blueShift = b[12]
    }

    var encoded: [UInt8] {
        var out: [UInt8] = []
        out.put(bitsPerPixel); out.put(depth); out.put(UInt8(bigEndian ? 1 : 0)); out.put(UInt8(trueColour ? 1 : 0))
        out.put(redMax); out.put(greenMax); out.put(blueMax)
        out.put(redShift); out.put(greenShift); out.put(blueShift)
        out.pad(3)
        return out
    }
}

/// What the server told us in ServerInit.
public struct ServerInit: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// The server's own pixel format (we replace it with `PixelFormat.bgrx` right after).
    public var pixelFormat: PixelFormat
    /// The desktop name; Hermes sets `hermes:<profile>`.
    public var name: String
}

/// Mouse buttons in a PointerEvent's mask. Wheel "buttons" are pressed and released in one go.
public struct PointerButtons: OptionSet, Sendable, Hashable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = PointerButtons(rawValue: 1 << 0)
    public static let middle = PointerButtons(rawValue: 1 << 1)
    public static let right = PointerButtons(rawValue: 1 << 2)
    public static let wheelUp = PointerButtons(rawValue: 1 << 3)
    public static let wheelDown = PointerButtons(rawValue: 1 << 4)
    public static let wheelLeft = PointerButtons(rawValue: 1 << 5)
    public static let wheelRight = PointerButtons(rawValue: 1 << 6)
}

/// Fence flags (TigerVNC's Fence extension).
public struct FenceFlags: OptionSet, Sendable, Hashable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let blockBefore = FenceFlags(rawValue: 1 << 0)
    public static let blockAfter = FenceFlags(rawValue: 1 << 1)
    public static let syncNext = FenceFlags(rawValue: 1 << 2)
    public static let request = FenceFlags(rawValue: 1 << 31)
}

/// Client-to-server messages. The set is closed on purpose: it is exactly what Hermes' display
/// bridge (tools/bot_desktop/rfb_filter.py) can frame and forward. Anything else makes the bridge
/// drop the connection, and SetDesktopSize (251) would resize the agent's own screen, so neither
/// can be built here.
public enum ClientMessage: Sendable, Equatable {
    /// Largest ClientCutText payload the bridge forwards (and Xvnc's -MaxCutText): 256 KiB.
    public static let maxCutText = 256 * 1024

    case setPixelFormat(PixelFormat)
    case setEncodings([RFBEncoding])
    case framebufferUpdateRequest(incremental: Bool, x: UInt16, y: UInt16, width: UInt16, height: UInt16)
    case keyEvent(down: Bool, keysym: UInt32)
    case pointerEvent(buttons: PointerButtons, x: UInt16, y: UInt16)
    /// Classic ClientCutText: Latin-1 text.
    case clientCutText(latin1: [UInt8])
    /// TigerVNC's extended clipboard, carried in ClientCutText with a negative length.
    case extendedClipboard(ExtendedClipboardMessage)
    case enableContinuousUpdates(enable: Bool, x: UInt16, y: UInt16, width: UInt16, height: UInt16)
    case fence(flags: FenceFlags, payload: [UInt8])

    /// The wire bytes. Throws `RFBError.refusedToSend` for a message the bridge would reject.
    public func encoded() throws -> [UInt8] {
        var out: [UInt8] = []
        switch self {
        case .setPixelFormat(let pf):
            out.put(UInt8(0)); out.pad(3); out += pf.encoded
        case .setEncodings(let encodings):
            guard encodings.count <= Int(UInt16.max) else { throw RFBError.refusedToSend("too many encodings") }
            out.put(UInt8(2)); out.pad(1); out.put(UInt16(encodings.count))
            for e in encodings { out.put(e.rawValue) }
        case .framebufferUpdateRequest(let incremental, let x, let y, let w, let h):
            out.put(UInt8(3)); out.put(UInt8(incremental ? 1 : 0))
            out.put(x); out.put(y); out.put(w); out.put(h)
        case .keyEvent(let down, let keysym):
            out.put(UInt8(4)); out.put(UInt8(down ? 1 : 0)); out.pad(2); out.put(keysym)
        case .pointerEvent(let buttons, let x, let y):
            out.put(UInt8(5)); out.put(buttons.rawValue); out.put(x); out.put(y)
        case .clientCutText(let text):
            guard text.count <= Self.maxCutText else {
                throw RFBError.refusedToSend("clipboard text over \(Self.maxCutText) bytes")
            }
            out.put(UInt8(6)); out.pad(3); out.put(UInt32(text.count)); out += text
        case .extendedClipboard(let message):
            let payload = try message.encoded()
            guard payload.count <= Self.maxCutText else {
                throw RFBError.refusedToSend("clipboard message over \(Self.maxCutText) bytes")
            }
            out.put(UInt8(6)); out.pad(3); out.put(Int32(-Int32(payload.count))); out += payload
        case .enableContinuousUpdates(let enable, let x, let y, let w, let h):
            out.put(UInt8(150)); out.put(UInt8(enable ? 1 : 0))
            out.put(x); out.put(y); out.put(w); out.put(h)
        case .fence(let flags, let payload):
            guard payload.count <= 64 else { throw RFBError.refusedToSend("fence payload over 64 bytes") }
            out.put(UInt8(248)); out.pad(3); out.put(flags.rawValue); out.put(UInt8(payload.count)); out += payload
        }
        return out
    }
}
