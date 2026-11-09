/// TigerVNC's extended clipboard (the "ExtendedClipboard" pseudo-encoding 0xC0A1E5CE), carried in
/// Server/ClientCutText with a negative length. Text travels as UTF-8 with CRLF line endings and a
/// trailing NUL, zlib-compressed. We only handle the text format.
public struct ExtendedClipboardMessage: Sendable, Equatable {
    public struct Formats: OptionSet, Sendable, Hashable {
        public var rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let text = Formats(rawValue: 1 << 0)
        public static let rtf = Formats(rawValue: 1 << 1)
        public static let html = Formats(rawValue: 1 << 2)
        public static let dib = Formats(rawValue: 1 << 3)
        public static let files = Formats(rawValue: 1 << 4)
    }

    public enum Action: UInt32, Sendable, CaseIterable {
        case caps = 0x0100_0000
        case request = 0x0200_0000
        case peek = 0x0400_0000
        case notify = 0x0800_0000
        case provide = 0x1000_0000
    }

    /// The message's action. A caps message also lists the actions the sender supports.
    public var action: Action
    public var formats: Formats
    /// caps: the actions supported.
    public var supportedActions: Set<Action> = []
    /// caps: the largest unsolicited size per format the sender accepts, in format-bit order.
    public var maxSizes: [UInt32] = []
    /// provide: the text (LF line endings on our side).
    public var text: String?

    public static func caps(formats: Formats, actions: Set<Action>, maxSizes: [UInt32]) -> Self {
        Self(action: .caps, formats: formats, supportedActions: actions, maxSizes: maxSizes)
    }
    public static func notify(_ formats: Formats) -> Self { Self(action: .notify, formats: formats) }
    public static func request(_ formats: Formats) -> Self { Self(action: .request, formats: formats) }
    public static func provide(text: String) -> Self { Self(action: .provide, formats: .text, text: text) }

    func encoded() throws -> [UInt8] {
        var out: [UInt8] = []
        switch action {
        case .caps:
            let actions = supportedActions.reduce(UInt32(0)) { $0 | $1.rawValue }
            out.put(action.rawValue | actions | formats.rawValue)
            for size in maxSizes { out.put(size) }
        case .request, .peek, .notify:
            out.put(action.rawValue | formats.rawValue)
        case .provide:
            out.put(action.rawValue | Formats.text.rawValue)
            let body = Self.wireText(text ?? "")
            guard body.count <= ClientMessage.maxCutText else {
                throw RFBError.refusedToSend("clipboard text over \(ClientMessage.maxCutText) bytes")
            }
            var plain: [UInt8] = []
            plain.put(UInt32(body.count))
            plain += body
            out += try Zlib.compress(plain)
        }
        return out
    }

    /// LF → CRLF, plus the trailing NUL the extension expects.
    static func wireText(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count + 16)
        var previous: UInt8 = 0
        for b in text.utf8 {
            if b == 0x0A && previous != 0x0D { out.append(0x0D) }
            out.append(b)
            previous = b
        }
        out.append(0)
        return out
    }

    /// `inflateLimit` bounds what a provide message may inflate to.
    static func decode(_ payload: [UInt8], inflateLimit: Int = ClientMessage.maxCutText + 64) throws -> ExtendedClipboardMessage {
        var r = SliceReader(payload)
        let flags = try r.u32()
        let formats = Formats(rawValue: flags & 0xFFFF)
        let actionBits = flags & 0xFF00_0000
        if actionBits & Action.caps.rawValue != 0 {
            var sizes: [UInt32] = []
            for bit in 0..<16 where flags & (1 << UInt32(bit)) != 0 {
                sizes.append(try r.u32())
            }
            let actions = Set(Action.allCases.filter { $0 != .caps && actionBits & $0.rawValue != 0 })
            return .caps(formats: formats, actions: actions, maxSizes: sizes)
        }
        guard let action = Action.allCases.first(where: { actionBits == $0.rawValue }) else {
            throw RFBError.protocolViolation("extended clipboard flags \(flags)")
        }
        guard action == .provide else { return Self(action: action, formats: formats) }
        // provide: zlib stream of (u32 length, bytes) for each format bit set, in bit order.
        let plain = try Inflater().inflate(Array(r.bytes[r.offset...]), limit: inflateLimit)
        var p = SliceReader(plain)
        var text: String?
        for bit in 0..<16 where flags & (1 << UInt32(bit)) != 0 {
            let length = Int(try p.u32())
            let data = try p.take(length)
            if bit == 0 { text = Self.decodeText(Array(data)) }
        }
        return Self(action: .provide, formats: formats, text: text)
    }

    /// Strips the trailing NUL and CRLF → LF.
    static func decodeText(_ bytes: [UInt8]) -> String {
        var b = bytes
        while b.last == 0 { b.removeLast() }
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        for (i, c) in b.enumerated() where !(c == 0x0D && i + 1 < b.count && b[i + 1] == 0x0A) {
            out.append(c)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
