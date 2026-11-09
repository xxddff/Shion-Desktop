import Foundation
import Observation

nonisolated enum GatewayError: LocalizedError {
    case notConfigured
    case offline
    case timeout(String)
    case accessDenied
    case http(Int)
    case closed(Int, String)
    case rpc(code: Int, message: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "还没填服务器地址"
        case .offline: return "没有连上服务器"
        case .timeout(let what): return "等 \(what) 超时了"
        case .accessDenied: return "Cloudflare Access 没有放行，检查 Client ID 和 Secret"
        case .http(let status): return "服务器返回 HTTP \(status)"
        case .closed(let code, let reason): return Gateway.describeClose(code, reason)
        case .rpc(_, let message, let reason): return reason ?? message
        }
    }
}

/// One WebSocket to the Hermes gateway (`/api/ws`), speaking the Canonical Gateway Protocol:
/// JSON-RPC 2.0, one object per text frame. Requests get replies; `event` notifications go to
/// `onEvent`; server requests Shion does not handle get a -32601 answer.
@Observable
final class Gateway {
    enum Phase: Equatable {
        case offline
        case connecting
        case online
        case failed(String)
    }

    private(set) var phase: Phase = .offline
    /// True when `/api/ws` is served by `hermes gateway` (the canonical wire); a standalone
    /// `hermes serve` speaks the legacy wire, which Shion does not support.
    private(set) var sessionAuthority = false

    /// (event type, session id, payload)
    @ObservationIgnored var onEvent: ((String, String?, JSONValue) -> Void)?
    /// Called after an automatic reconnect: attachments are per socket, so sessions must resume.
    @ObservationIgnored var onReconnect: (() -> Void)?

    @ObservationIgnored private var settings = ServerSettings()
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    @ObservationIgnored private var ready: CheckedContinuation<JSONValue, Error>?
    @ObservationIgnored private var readyAttempt = 0
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var lastInbound = Date()
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var wasOnline = false
    @ObservationIgnored private var retries = 0

    // MARK: connecting

    func connect(_ settings: ServerSettings) async {
        self.settings = settings
        wanted = true
        wasOnline = false
        retries = 0
        await open(isReconnect: false)
    }

    func disconnect() {
        wanted = false
        teardown(GatewayError.offline)
        phase = .offline
    }

    private func open(isReconnect: Bool) async {
        teardown(GatewayError.offline)
        phase = .connecting
        do {
            guard let url = settings.socketURL else { throw GatewayError.notConfigured }
            try await preflight()
            var request = URLRequest(url: url)
            settings.applyAccessHeaders(to: &request)
            let socket = URLSession.shared.webSocketTask(with: request)
            // snapshots and transcript pages can be well over the 1 MiB default
            socket.maximumMessageSize = 64 * 1024 * 1024
            self.socket = socket
            socket.resume()
            receive(on: socket)
            let readyPayload = try await waitForReady(seconds: 15)
            sessionAuthority = readyPayload["session_authority"]?.bool ?? false
            _ = try await call("client.capabilities", ["server_requests": true])
            phase = .online
            wasOnline = true
            retries = 0
            if readyPayload["heartbeat"]?.bool ?? false {
                startHeartbeat()
            }
            if isReconnect {
                onReconnect?()
            }
        } catch {
            teardown(error)
            phase = .failed(error.localizedDescription)
            scheduleReconnect()
        }
    }

    /// `GET /api/status` is public on Hermes; through Cloudflare it tells whether Access let us in.
    private func preflight() async throws {
        guard let url = settings.httpURL("/api/status") else { throw GatewayError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        settings.applyAccessHeaders(to: &request)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let host = response.url?.host, host.hasSuffix("cloudflareaccess.com") {
            throw GatewayError.accessDenied
        }
        // only Access saying no is fatal here; anything else, the WebSocket itself will tell
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw GatewayError.accessDenied
        }
    }

    private func waitForReady(seconds: Double) async throws -> JSONValue {
        readyAttempt += 1
        let attempt = readyAttempt
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                // a timer left over from an earlier attempt must not fail this one
                guard let self, self.readyAttempt == attempt else { return }
                self.resolveReady(.failure(GatewayError.timeout("gateway.ready")))
            }
        }
    }

    private func resolveReady(_ result: Result<JSONValue, Error>) {
        guard let continuation = ready else { return }
        ready = nil
        continuation.resume(with: result)
    }

    // MARK: requests

    /// Sends a request and waits for its reply (30 s by default, as the Desktop does).
    @discardableResult
    func call(_ method: String, _ params: JSONValue = [:], timeout: Double = 30) async throws -> JSONValue {
        guard let socket else { throw GatewayError.offline }
        let id = nextId
        nextId += 1
        let frame: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let text = try frame.serialized()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                do {
                    try await socket.send(.string(text))
                } catch {
                    self?.settle(id, .failure(error))
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.settle(id, .failure(GatewayError.timeout(method)))
            }
        }
    }

    private func settle(_ id: Int, _ result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func send(_ frame: JSONValue) {
        guard let socket, let text = try? frame.serialized() else { return }
        Task {
            try? await socket.send(.string(text))
        }
    }

    // MARK: receiving

    private func receive(on socket: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await socket.receive()
                } catch {
                    self?.closed(socket, error: error)
                    return
                }
                guard let self else { return }
                switch message {
                case .string(let text):
                    self.handle(text)
                case .data(let data):
                    self.handle(String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
            }
        }
    }

    private func handle(_ text: String) {
        lastInbound = Date()
        guard let frame = try? JSONValue.parse(text) else { return }
        if let method = frame["method"]?.string {
            if method == "event", let params = frame["params"] {
                let type = params["type"]?.string ?? ""
                let payload = params["payload"] ?? .null
                if type == "gateway.ready" {
                    resolveReady(.success(payload))
                } else {
                    onEvent?(type, params["session_id"]?.string, payload)
                }
            } else if let id = frame["id"] {
                // sudo, secret and other server requests: not handled here yet, so say so at once
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("no handler for server request: \(method)")]])
            }
            return
        }
        guard let id = frame["id"]?.int else { return }
        if let error = frame["error"] {
            settle(id, .failure(GatewayError.rpc(
                code: error["code"]?.int ?? 0,
                message: error["message"]?.string ?? "error",
                reason: error["data"]?["reason"]?.string
            )))
        } else {
            settle(id, .success(frame["result"] ?? .null))
        }
    }

    private func closed(_ socket: URLSessionWebSocketTask, error: Error) {
        guard socket === self.socket else { return }
        let code = socket.closeCode.rawValue
        let reason = socket.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let failure: Error = code == 0 || code == URLSessionWebSocketTask.CloseCode.invalid.rawValue
            ? error
            : GatewayError.closed(code, reason)
        teardown(failure)
        guard wanted else { return }
        phase = .failed(failure.localizedDescription)
        scheduleReconnect()
    }

    // MARK: keeping it alive

    /// `gateway.ping` every 15 s; no inbound frame for 45 s means the socket is dead.
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.phase == .online else { return }
                if Date().timeIntervalSince(self.lastInbound) > 45 {
                    self.socket?.cancel(with: .goingAway, reason: nil)
                    return
                }
                _ = try? await self.call("gateway.ping", [:], timeout: 10)
            }
        }
    }

    /// Only a connection that had worked comes back on its own; a first attempt that fails (wrong
    /// token, wrong address) stays failed with its reason until you connect again.
    private func scheduleReconnect() {
        guard wanted, wasOnline, settings.isConfigured else { return }
        retries += 1
        let delay = min(15, 0.5 * pow(2, Double(min(retries, 6))))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.wanted, self.phase != .online, self.phase != .connecting else { return }
            await self.open(isReconnect: true)
        }
    }

    private func teardown(_ error: Error) {
        heartbeat?.cancel()
        heartbeat = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        resolveReady(.failure(error))
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    nonisolated static func describeClose(_ code: Int, _ reason: String) -> String {
        switch code {
        case 4401: return "令牌不对，服务器拒绝了连接（4401）"
        case 4403: return "服务器拒绝了连接（4403）：检查地址、Host 和权限"
        case 1013: return "网关还没准备好，稍后会自动重连（1013）"
        case 1011: return "服务器断开了连接（1011）"
        default: return reason.isEmpty ? "连接断开了（\(code)）" : "连接断开了（\(code)）：\(reason)"
        }
    }
}
