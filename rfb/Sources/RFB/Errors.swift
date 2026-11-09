public enum RFBError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The server's version string is not one we speak (only RFB 3.8 and later are accepted).
    case unsupportedVersion(String)
    /// The server refused the connection before security negotiation, with its reason.
    case connectionRefused(String)
    /// None of the server's security types is one we support (only None).
    case unsupportedSecurity([UInt8])
    /// SecurityResult was a failure.
    case securityFailed(String)
    /// The server sent something we cannot parse.
    case protocolViolation(String)
    /// A server message type we do not know; we cannot find the next message boundary.
    case unknownServerMessage(UInt8)
    /// A rectangle with an encoding we did not ask for.
    case unsupportedEncoding(Int32)
    /// zlib reported an error.
    case zlib(Int32)
    /// The stream ended (TCP EOF, or the end of a replayed recording).
    case endOfStream
    /// A message we refuse to send because the display bridge would close the connection over it,
    /// or that cannot be sent right now.
    case refusedToSend(String)
    /// The server announced something larger than we accept (screen, compressed data, cursor).
    case limitExceeded(String)
    /// No answer in time: the handshake, or the keepalive while running. The connection was
    /// dropped without a close handshake, so the bridge keeps any lease with this viewer.
    case timedOut(String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let v): "unsupported RFB version \(v)"
        case .connectionRefused(let r): "server refused the connection: \(r)"
        case .unsupportedSecurity(let t): "no supported security type in \(t)"
        case .securityFailed(let r): "security handshake failed: \(r)"
        case .protocolViolation(let m): "protocol violation: \(m)"
        case .unknownServerMessage(let t): "unknown server message type \(t)"
        case .unsupportedEncoding(let e): "unsupported encoding \(e)"
        case .zlib(let c): "zlib error \(c)"
        case .endOfStream: "end of stream"
        case .refusedToSend(let m): "refused to send: \(m)"
        case .limitExceeded(let m): "over the limit: \(m)"
        case .timedOut(let m): "timed out: \(m)"
        }
    }
}
