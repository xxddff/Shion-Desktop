import Foundation
import Network

/// A one-shot web server on 127.0.0.1 for the end of a browser sign-in (RFC 8252 §7.3). Hermes
/// sends the browser to `http://127.0.0.1:<port>/callback?code=…&state=…`; the listener hands that
/// query to the app and answers by sending the browser on to Shion's callback scheme, which closes
/// the sign-in sheet. It serves nothing else, and lives only while a sign-in is open.
nonisolated final class LoopbackListener: @unchecked Sendable {
    /// Where the browser is sent once the query is in hand.
    static let doneLocation = "\(BrowserSignIn.callbackScheme)://done"

    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.shion.signin.loopback")
    private let onCallback: @Sendable ([String: String]) -> Void
    /// Touched on `queue` only, apart from the first write before the listener starts.
    private var starting: CheckedContinuation<Void, Error>?

    private init(listener: NWListener, onCallback: @escaping @Sendable ([String: String]) -> Void) {
        self.listener = listener
        self.onCallback = onCallback
    }

    /// Starts listening on an ephemeral port of 127.0.0.1, and only there.
    static func start(onCallback: @escaping @Sendable ([String: String]) -> Void) async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let loopback = LoopbackListener(listener: try NWListener(using: parameters), onCallback: onCallback)
        try await loopback.run()
        return loopback
    }

    func stop() {
        listener.cancel()
    }

    private func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            starting = continuation
            listener.stateUpdateHandler = { [weak self] state in
                self?.changed(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func changed(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener.port?.rawValue ?? 0
            starting?.resume()
            starting = nil
        case .failed(let error), .waiting(let error):
            starting?.resume(throwing: error)
            starting = nil
            listener.cancel()
        case .cancelled:
            starting?.resume(throwing: CancellationError())
            starting = nil
        default:
            break
        }
    }

    // MARK: one request per connection

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    /// Reads up to the end of the request head; a browser sends nothing else on a GET.
    private func read(_ connection: NWConnection, _ head: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var head = head
            if let data {
                head.append(data)
            }
            if head.range(of: Data("\r\n\r\n".utf8)) != nil || head.count > 16 * 1024 || isComplete || error != nil {
                self.answer(connection, head)
            } else {
                self.read(connection, head)
            }
        }
    }

    private func answer(_ connection: NWConnection, _ head: Data) {
        let requestLine = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let response: String
        if parts.count >= 2, parts[0] == "GET",
           let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
           components.path == "/callback" {
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
            onCallback(query)
            response = Self.redirect
        } else {
            response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Sends the browser on to the callback scheme. The page under it only shows if a browser
    /// does not follow that, and says what to do.
    private static let redirect: String = {
        let page = """
        <!doctype html><meta charset="utf-8"><title>Shion</title>\
        <body style="font:15px -apple-system,system-ui;margin:4rem;text-align:center">\
        <p>已登录，可以关掉这个页面，回到 Shion。</p>
        """
        let body = Data(page.utf8)
        return "HTTP/1.1 302 Found\r\n"
            + "Location: \(LoopbackListener.doneLocation)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
            + page
    }()
}
