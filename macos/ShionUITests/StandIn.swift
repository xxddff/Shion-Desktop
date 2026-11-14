import Foundation
import Network
import XCTest

/// What a UI test says to the CI stand-in itself (ci/fake_hermes.py) rather than through Shion: that
/// the tunnel a scripted drop took down may come back (`POST /ci/tunnel/up`, ci/fake_reconnect.py).
/// A drop keeps the tunnel down until then, so a test sees what it looks for while Shion is away
/// (重新连接中…, 等连上后确认, what it said meanwhile waiting) however long its typing takes, and Shion
/// is back at its next try after. The same way, the stand-in sends the message nobody asked for
/// when BoardTests is reading further up (`POST /ci/later`), finishes the ⌥Space reply once
/// QuickAskTests has seen it arrive (`POST /ci/quick/finish`), and marks in its log where a test
/// got to (`POST /ci/mark/…`), which is kept when a run is cut short.
///
/// The request is plain HTTP over Network.framework, which App Transport Security does not cover
/// (the runner's Info.plist is Xcode's, without Shion's exception for 127.0.0.1). The runner's sandbox
/// lets it connect because ShionUITests.entitlements adds com.apple.security.network.client to what
/// Xcode signs it with.
enum StandIn {
    static let port: UInt16 = 8765

    /// Brings the tunnel back. The stand-in answers once what its script does while Shion is away is
    /// done (a reply that ends meanwhile, the parts kept for the replay); a failure naming `step` when
    /// the tunnel was not down, or nothing answered.
    @discardableResult
    static func tunnelUp(_ step: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        say("/ci/tunnel/up", step, "bring the tunnel back", timeout: 45, file: file, line: line)
    }

    /// Has the stand-in send now the message nobody asked for that 「等一会儿再说一句」 kept back:
    /// answered once it is sent. A failure naming `step` when none was kept back.
    @discardableResult
    static func later(_ step: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        say("/ci/later", step, "send the message nobody asked for", timeout: 10, file: file, line: line)
    }

    /// Has the stand-in go on with the ⌥Space reply it holds after its first part.
    @discardableResult
    static func finishQuickReply(_ step: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        say("/ci/quick/finish", step, "finish the quick window's reply", timeout: 10, file: file, line: line)
    }

    /// Has the stand-in let the chat be attached (`POST /ci/attach/go`, ci/fake_reconnect.py): it
    /// answers the `session.resume` it keeps back after 「断线：又说一遍」, and no longer refuses
    /// the ones after 「断线：接不上」. Until then Shion is connected and the chat is not attached on
    /// the new socket, so what ReconnectTests says or sees in between is while the chat is being
    /// attached again. A failure naming `step` when no answer was kept back and none refused.
    @discardableResult
    static func attach(_ step: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        say("/ci/attach/go", step, "let the chat be attached", timeout: 10, file: file, line: line)
    }

    /// A mark in the stand-in's log (`fake_hermes-<test>.log`): where the test got to, should the
    /// app stop answering and the run be cut short. Nothing fails if it does not get there.
    static func mark(_ step: String) {
        _ = post("/ci/mark/\(step)", timeout: 2)
    }

    private static func say(_ path: String, _ step: String, _ what: String, timeout: TimeInterval,
                            file: StaticString, line: UInt) -> Bool {
        switch post(path, timeout: timeout) {
        case .success(let reply) where reply.status == 200:
            print("\(step): \(path): \(reply.body)")
            return true
        case .success(let reply):
            XCTFail("\(step): the stand-in did not \(what): \(reply.status) \(reply.body)", file: file, line: line)
        case .failure(let failure):
            XCTFail("\(step): the stand-in could not be told to \(what): \(failure.reason)", file: file, line: line)
        }
        return false
    }

    private struct Reply {
        let status: Int
        let body: String
    }

    private struct Failure: Error {
        let reason: String
    }

    /// One request on a connection of its own (`Connection: close`): the answer, or why none came.
    private static func post(_ path: String, timeout: TimeInterval) -> Result<Reply, Failure> {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { return .failure(Failure(reason: "no port \(port)")) }
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        let box = StandInAnswer()
        let request = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error { box.finish("sending: \(error)") }
                })
                StandIn.readAnswer(from: connection, into: box)
            case .waiting(let error), .failed(let error):
                box.finish("connecting: \(error)")
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "dev.shion.ShionUITests.stand-in"))
        let answered = box.done.wait(timeout: .now() + timeout) == .success
        connection.stateUpdateHandler = nil
        connection.cancel()
        guard answered else { return .failure(Failure(reason: "no answer in \(Int(timeout)) s")) }
        if let reason = box.failure { return .failure(Failure(reason: reason)) }
        let text = String(decoding: box.data, as: UTF8.self)
        guard let split = text.range(of: "\r\n\r\n") else { return .failure(Failure(reason: "half an answer: \(text.prefix(80))")) }
        let fields = text[..<split.lowerBound].split(separator: " ", maxSplits: 2)
        guard fields.count >= 2, let status = Int(fields[1]) else {
            return .failure(Failure(reason: "not an HTTP answer: \(text.prefix(80))"))
        }
        return .success(Reply(status: status, body: String(text[split.upperBound...])))
    }

    /// Reads until the stand-in closes the connection, as it does after its answer.
    private static func readAnswer(from connection: NWConnection, into box: StandInAnswer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data { box.append(data) }
            if isComplete || (error != nil && box.hasAnswer) {
                box.finish(nil)
            } else if let error {
                box.finish("reading: \(error)")
            } else {
                StandIn.readAnswer(from: connection, into: box)
            }
        }
    }
}

/// What came back on the connection's queue, read once `done` is signalled.
private final class StandInAnswer: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var bytes = Data()
    private var reason: String?
    private var over = false

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }

    /// The whole head is in: a connection reset after it still leaves an answer.
    var hasAnswer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bytes.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    func append(_ more: Data) {
        lock.lock()
        bytes.append(more)
        lock.unlock()
    }

    /// The request is over: answered (nil), or not and why. Only the first word counts.
    func finish(_ failure: String?) {
        lock.lock()
        let first = !over
        if first {
            over = true
            reason = failure
        }
        lock.unlock()
        if first { done.signal() }
    }
}
