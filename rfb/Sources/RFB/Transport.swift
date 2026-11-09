/// The byte pipe an `RFBClient` runs over. The core does not care whether it is a WebSocket
/// (Hermes' display bridge), a TCP socket or a recorded session being replayed.
///
/// Chunk boundaries carry no meaning: RFB messages do not line up with WebSocket frames.
public protocol RFBTransport: AnyObject, Sendable {
    /// Sends `bytes` as one write (one binary frame on a WebSocket).
    func send(_ bytes: [UInt8]) async throws
    /// The next chunk from the server. Returns nil when the stream ended without a close code
    /// (a TCP EOF); throws `RFBConnectionClosed` when the peer closed with one (WebSocket).
    func receive() async throws -> [UInt8]?
    /// Closes the connection. On a WebSocket, `.normal` (1000) tells Hermes' bridge that the viewer
    /// left on purpose, which also hands the lease back.
    func close(_ code: RFBCloseCode) async
}

/// How we close. Only matters on a WebSocket.
public enum RFBCloseCode: Sendable, Equatable {
    /// 1000: the viewer closed the screen on purpose.
    case normal
    /// 1001: going away (app quitting).
    case goingAway
}

/// The peer closed the connection, with the WebSocket close code and reason when there was one.
public struct RFBConnectionClosed: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: Int?
    public var reason: String

    public init(code: Int?, reason: String = "") {
        self.code = code
        self.reason = reason
    }

    /// What Hermes' display bridge meant by this code, if it is one of its own.
    public var bridgeReason: DisplayBridgeClose? {
        code.flatMap(DisplayBridgeClose.init(rawValue:))
    }

    public var description: String {
        let what = bridgeReason.map { " (\($0))" } ?? ""
        return "connection closed, code \(code.map(String.init) ?? "none")\(what)\(reason.isEmpty ? "" : ": \(reason)")"
    }
}

/// Close codes used by Hermes' `/api/display/ws` (hermes_cli/web_routers/display.py).
public enum DisplayBridgeClose: Int, Sendable, CustomStringConvertible {
    /// Our normal close, or the bridge's own teardown.
    case normal = 1000
    case goingAway = 1001
    /// A text frame, or a client message the bridge's RFB filter cannot frame (or a clipboard
    /// message over 256 KiB). Our encoder never produces those.
    case protocolError = 1003
    /// Another viewer took the lease from us: go back to watching with a fresh ticket.
    case controlTaken = 4000
    /// The screen is not running (no RFB socket on the server).
    case desktopGone = 4001
    /// The ticket is missing, expired, already used, or its browser tab signed out: call
    /// `display.observe` again.
    case badTicket = 4401
    /// Refused by the bridge's Host / Origin / client-IP policy.
    case notAllowed = 4403

    public var description: String {
        switch self {
        case .normal: "normal"
        case .goingAway: "going away"
        case .protocolError: "protocol error"
        case .controlTaken: "control taken by another viewer"
        case .desktopGone: "screen not running"
        case .badTicket: "ticket missing, expired or used"
        case .notAllowed: "not allowed"
        }
    }
}
