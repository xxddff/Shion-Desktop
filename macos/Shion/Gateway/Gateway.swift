import Foundation
import Observation

nonisolated enum GatewayError: LocalizedError {
    case notConfigured
    case offline
    case timeout(String)
    case accessDenied
    case notHermes
    case tokenLoginOff([String])
    case badToken(String)
    case noSignInNeeded
    case noBrowserSignIn([String])
    case notSignedIn
    case signInExpired
    case signInRefused
    case signInFailed(String)
    case upgradeRefused(Int)
    case http(Int)
    case closed(Int, String)
    case rpc(code: Int, message: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "还没填服务器地址"
        case .offline: return "没有连上服务器"
        case .timeout(let what): return "等 \(what) 超时了"
        case .accessDenied: return "Cloudflare Access 没有放行，检查 Client ID 和 Secret"
        case .notHermes: return "这个地址的 /api/status 不是 Hermes 的回复：要填 hermes gateway 的 Webapp 地址。"
        case .tokenLoginOff(let providers):
            return "服务器没开会话令牌登录：/api/status 的 auth_providers 里没有 session-token（\(Self.listing(providers))）。在运行 hermes gateway 的环境里设好 HERMES_DASHBOARD_SESSION_TOKEN，确认 dashboard.session_token_auth.enabled 不是 false，再重启 gateway。"
        case .badToken(let hint):
            return "会话令牌和服务器上的 HERMES_DASHBOARD_SESSION_TOKEN 对不上（/api/auth/me 返回 401）。这里填的是 \(hint)，和服务器上 gateway 进程实际用的值比一比；服务器换过令牌的话，这里要填新的。"
        case .noSignInNeeded: return "这个服务器没开登录（auth_required 是 false），没有登录页：改用会话令牌。"
        case .noBrowserSignIn(let providers):
            return "服务器没开浏览器登录：/api/status 的 auth_flows 里没有 native_pkce（\(Self.listing(providers))）。在 config.yaml 的 dashboard.basic_auth 设好 username 和 password，重启 gateway。"
        case .notSignedIn: return "还没登录：点「用浏览器登录」"
        case .signInExpired: return "登录过期了：再点一次「用浏览器登录」"
        case .signInRefused: return "服务器不认这次登录（/api/auth/me 返回 401）：退出登录，再登录一次"
        case .signInFailed(let detail): return "登录没完成：\(detail)"
        case .upgradeRefused(let status):
            switch status {
            case 404: return "这个地址下面没有 /api/ws（HTTP 404）：要填 hermes gateway 的 Webapp 地址。"
            case 401, 403: return "服务器拒绝了 WebSocket（HTTP \(status)）。登录已经检查过的话，多半是 Host 和 webapp.public_url 对不上，或者这个地址没开聊天。"
            default: return "服务器拒绝了 WebSocket（HTTP \(status)）。"
            }
        case .http(let status): return "服务器返回 HTTP \(status)"
        case .closed(let code, let reason): return Gateway.describeClose(code, reason)
        case .rpc(_, let message, let reason): return reason ?? message
        }
    }

    private static func listing(_ providers: [String]) -> String {
        providers.isEmpty ? "现在一个登录方式都没有" : "现在只有 \(providers.joined(separator: "、"))"
    }

    /// Trying again cannot fix these; they wait for a change in Settings or on the server.
    var needsYou: Bool {
        switch self {
        case .notConfigured, .accessDenied, .notHermes, .tokenLoginOff, .badToken, .noSignInNeeded,
             .noBrowserSignIn, .notSignedIn, .signInExpired, .signInRefused:
            return true
        default:
            return false
        }
    }
}

/// One WebSocket to the Hermes gateway (`/api/ws`), speaking the Canonical Gateway Protocol:
/// JSON-RPC 2.0, one object per text frame. Requests get replies; `event` notifications go to
/// `onEvent`; server requests go to `onRequest`, and the ones it does not take get a -32601 answer.
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
    /// When the next automatic try is, while one waits (the sidebar says it).
    private(set) var nextRetry: Date?
    /// A connection that had worked is down, and being got back.
    var reconnecting: Bool { wanted && wasOnline && phase != .online }

    /// (event type, session id, payload)
    @ObservationIgnored var onEvent: ((String, String?, JSONValue) -> Void)?
    /// Every event's whole params, just before `onEvent`: Hermes stamps each frame of a turn with
    /// its `execution_generation` there, beside the payload (AppStore+Control.swift keeps it).
    @ObservationIgnored var onFrame: ((JSONValue) -> Void)?
    /// A server→client request (method, id, params): true when it was taken, to be answered with
    /// `answer(_:_:)` (sudo and secret, AppStore+Secrets.swift).
    @ObservationIgnored var onRequest: ((String, String, JSONValue) -> Bool)?
    /// Called after an automatic reconnect: attachments are per socket, so sessions must resume.
    @ObservationIgnored var onReconnect: (() -> Void)?
    /// Bumped by every socket that comes up: work begun for an earlier one stops (AppStore.comeBack),
    /// and a sudo or secret request is answered on the socket it came on, or on one a resume found
    /// it still waiting on (AppStore+Secrets.swift).
    @ObservationIgnored private(set) var connection = 0
    /// Each session's newest event seen, kept across sockets (Gateway+Replay.swift).
    @ObservationIgnored var cursors = EventCursors()
    /// The sessions attached on this socket (`session.resume`, `session.create`): Hermes takes a
    /// prompt, or an answer to an approval, only on a socket that has its session attached.
    @ObservationIgnored var attached: Set<String> = []
    /// Signs each dial: the session token, or a browser sign-in's access token. `true` asks for
    /// a fresh one, after the server refused the last.
    @ObservationIgnored var credential: ((_ settings: ServerSettings, _ renew: Bool) async throws -> Credential)?

    @ObservationIgnored private var settings = ServerSettings()
    /// Bumped by every dial and by disconnect: a dial that was overtaken while it waited stops.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    /// Requests whose refusal is answered as `{"refusal": error}`, not thrown (`keepRefusal`).
    @ObservationIgnored private var keepsRefusal: Set<Int> = []
    @ObservationIgnored private var ready: CheckedContinuation<JSONValue, Error>?
    @ObservationIgnored private var readyAttempt = 0
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var lastInbound = Date()
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var wasOnline = false
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var retry: Task<Void, Never>?

    // MARK: connecting

    func connect(_ settings: ServerSettings) async {
        self.settings = settings
        wanted = true
        wasOnline = false
        retries = 0
        cursors.removeAll()
        await open(isReconnect: false)
    }

    func disconnect() {
        wanted = false
        attempt += 1
        retry?.cancel()
        nextRetry = nil
        cursors.removeAll()
        teardown(GatewayError.offline)
        phase = .offline
    }

    private func open(isReconnect: Bool) async {
        attempt += 1
        let attempt = attempt
        retry?.cancel()
        nextRetry = nil
        teardown(GatewayError.offline)
        phase = .connecting
        do {
            guard settings.isConfigured, let credential else { throw GatewayError.notConfigured }
            var signed = try await credential(settings, false)
            do {
                try await preflight(signed)
            } catch GatewayError.signInRefused {
                // a server can drop a sign-in's token before its time: renew once, then it counts
                signed = try await credential(settings, true)
                try await preflight(signed)
            }
            guard attempt == self.attempt else { return }
            guard let url = settings.socketURL(token: signed.token) else { throw GatewayError.notConfigured }
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
            guard attempt == self.attempt else { return }
            connection += 1
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
            guard attempt == self.attempt else { return }
            teardown(error)
            phase = .failed(error.localizedDescription)
            if (error as? GatewayError)?.needsYou != true {
                scheduleReconnect()
            }
        }
    }

    /// Checks over plain HTTP what the WebSocket upgrade would only answer with a bare refusal:
    /// whether Cloudflare Access lets us in (`GET /api/status` is public on Hermes), whether the
    /// server takes the deployment session token at all (its `session-token` provider), and
    /// whether this credential opens it (`GET /api/auth/me`, the way Hermes Desktop sends it:
    /// the session token as X-Hermes-Session-Token, a sign-in's access token as a bearer).
    private func preflight(_ signed: Credential) async throws {
        // a server without the sign-in gate (loopback) checks the token on the socket itself
        guard let status = try await settings.status(), status.authRequired else { return }
        if case .sessionToken = signed, !status.providers.contains("session-token") {
            throw GatewayError.tokenLoginOff(status.providers)
        }
        guard let meURL = settings.httpURL("/api/auth/me") else { return }
        var me = URLRequest(url: meURL)
        me.timeoutInterval = 15
        settings.applyAccessHeaders(to: &me)
        signed.sign(&me)
        let (_, meResponse) = try await URLSession.shared.data(for: me)
        guard let http = meResponse as? HTTPURLResponse, http.statusCode == 401 else { return }
        switch signed {
        case .sessionToken: throw GatewayError.badToken(settings.tokenHint)
        case .bearer: throw GatewayError.signInRefused
        }
    }

    /// A REST read on the server, signed as the socket is (session token or sign-in bearer).
    func rest(_ path: String) async throws -> JSONValue {
        guard let url = settings.httpURL(path), let credential else { throw GatewayError.notConfigured }
        let signed = try await credential(settings, false)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        settings.applyAccessHeaders(to: &request)
        signed.sign(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try ServerSettings.checkAccess(response)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GatewayError.http(status) }
        return try JSONValue.parse(String(decoding: data, as: UTF8.self))
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

    /// Sends a request and waits for its reply (30 s by default, as the Desktop does). With
    /// `keepRefusal`, a refusal comes back as `{"refusal": <the error object>}` instead of being
    /// thrown, for a caller that reads `error.data` (a revision conflict names the fresh revision).
    /// An attach's snapshot says where its session's events go on from (Gateway+Replay.swift).
    @discardableResult
    func call(_ method: String, _ params: JSONValue = [:], timeout: Double = 30, keepRefusal: Bool = false) async throws -> JSONValue {
        let socket = self.socket
        let result = try await request(method, params, timeout: timeout, keepRefusal: keepRefusal)
        if method == "session.resume" || method == "session.create", socket != nil, socket === self.socket,
           let session = result["session_id"]?.string {
            cursors.start(result)
            attached.insert(session)
        }
        return result
    }

    private func request(_ method: String, _ params: JSONValue, timeout: Double, keepRefusal: Bool) async throws -> JSONValue {
        guard let socket else { throw GatewayError.offline }
        let id = nextId
        nextId += 1
        if keepRefusal {
            keepsRefusal.insert(id)
        }
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
        keepsRefusal.remove(id)
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func send(_ frame: JSONValue) {
        guard let socket, let text = try? frame.serialized() else { return }
        Task {
            try? await socket.send(.string(text))
        }
    }

    /// Answers a server→client request: a JSON-RPC response, which gets no reply. Throws when the
    /// connection is down or the frame did not go out. The frame is not kept, retried or logged.
    func answer(_ id: String, _ result: JSONValue) async throws {
        guard let socket, phase == .online else { throw GatewayError.offline }
        let frame: JSONValue = ["jsonrpc": "2.0", "id": .string(id), "result": result]
        let text = try frame.serialized()
        try await socket.send(.string(text))
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
                    // a frame seen already goes no further (Gateway+Replay.swift)
                    deliver(params)
                }
            } else if let id = frame["id"] {
                // sudo and secret wait for you (AppStore+Secrets.swift); the other server requests
                // are not handled, so say so at once
                if let key = id.string, onRequest?(method, key, frame["params"] ?? .null) == true { return }
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("no handler for server request: \(method)")]])
            }
            return
        }
        guard let id = frame["id"]?.int else { return }
        if let error = frame["error"], keepsRefusal.contains(id) {
            settle(id, .success(["refusal": error]))
        } else if let error = frame["error"] {
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
        // a refused upgrade surfaces as "bad server response"; its HTTP status says more
        let refused = (socket.response as? HTTPURLResponse).map(\.statusCode).flatMap { $0 == 101 ? nil : $0 }
        let failure: Error
        if let refused {
            failure = GatewayError.upgradeRefused(refused)
        } else if code == 0 || code == URLSessionWebSocketTask.CloseCode.invalid.rawValue {
            failure = error
        } else {
            failure = GatewayError.closed(code, reason)
        }
        teardown(failure)
        // while dialling, the dial says so itself and tries again (`open`): once, not twice
        guard wanted, phase == .online else { return }
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
    /// token, wrong address) stays failed with its reason until you connect again. Tries 1, 2, 4,
    /// 8 s apart, then every 15 s (Backoff).
    private func scheduleReconnect() {
        guard wanted, wasOnline, settings.isConfigured else { return }
        retries += 1
        let delay = Backoff.delay(afterFailures: retries)
        nextRetry = Date().addingTimeInterval(delay)
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wanted, self.phase != .online, self.phase != .connecting else { return }
            // the dial gets a task of its own: open() cancels the retry, and from in here that
            // would cancel the dial too (its requests failing at once, never sent)
            self.redial()
        }
    }

    /// Back from sleep, or on another network (ConnectionWatch.swift): a connection that had worked
    /// does not wait out its backoff. One that seems up is checked first: a socket from before the
    /// sleep or from the old network is dead without knowing it, and one that has heard nothing for
    /// longer than the heartbeat allows certainly is.
    func reconnectNow() {
        guard wanted, wasOnline, settings.isConfigured, phase != .connecting else { return }
        guard phase == .online else { return redial() }
        if Date().timeIntervalSince(lastInbound) > 20 { return redial() }
        Task { [weak self] in
            do {
                _ = try await self?.call("gateway.ping", [:], timeout: 5)
            } catch {
                guard let self, self.phase == .online else { return }
                self.redial()
            }
        }
    }

    private func redial() {
        retry?.cancel()
        nextRetry = nil
        Task { await self.open(isReconnect: true) }
    }

    private func teardown(_ error: Error) {
        heartbeat?.cancel()
        heartbeat = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        attached = []
        resolveReady(.failure(error))
        let waiting = pending
        pending = [:]
        keepsRefusal = []
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    nonisolated static func describeClose(_ code: Int, _ reason: String) -> String {
        switch code {
        case 4401: return "服务器不认这次的令牌或登录，拒绝了连接（4401）"
        case 4403: return "服务器拒绝了连接（4403）：检查地址、Host 和权限"
        case 1013: return "网关还没准备好，稍后会自动重连（1013）"
        case 1011: return "服务器断开了连接（1011）"
        default: return reason.isEmpty ? "连接断开了（\(code)）" : "连接断开了（\(code)）：\(reason)"
        }
    }
}
