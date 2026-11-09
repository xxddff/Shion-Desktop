import RFB

/// Plain RFB over TCP or a Unix socket, e.g. straight to Xvnc's `-rfbunixpath` socket in the
/// testbed. No bridge in between, so nothing filters what we send.
public final class SocketTransport: RFBTransport, @unchecked Sendable {
    private let socket: POSIXSocket
    private let pump: ReadPump

    public init(host: String, port: UInt16) throws {
        socket = try POSIXSocket(connectingTo: .tcp(host: host, port: port))
        let s = socket
        pump = ReadPump { let b = try s.read(); return b.isEmpty ? nil : b }
    }

    public init(unixPath: String) throws {
        socket = try POSIXSocket(connectingTo: .unix(path: unixPath))
        let s = socket
        pump = ReadPump { let b = try s.read(); return b.isEmpty ? nil : b }
    }

    public func send(_ bytes: [UInt8]) async throws { try socket.writeAll(bytes) }
    public func receive() async throws -> [UInt8]? { try await pump.next() }
    public func close(_ code: RFBCloseCode) async { socket.close() }
}
