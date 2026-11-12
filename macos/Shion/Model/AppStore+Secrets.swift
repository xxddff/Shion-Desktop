import AppKit
import Foundation

/// Passwords and keys assistants ask for in the middle of a turn. As Hermes does it (checked
/// against hermes-agent b3746e35, 2026-11-09):
/// - `sudo` (the terminal tool's sudo password) and `secret` (a skill's environment variable) are
///   server→client requests on /api/ws (tui_gateway/contracts/server_requests.py), sent only to the
///   windows attached to that chat, and only for a chat a window started (gateway/
///   run_turn_progress.py `local_viewer_turn`): `{"jsonrpc": "2.0", "id": "srq-…", "method":
///   "sudo", "params": {"session_id", "command"}}`; a secret's params are `env_var`, `prompt` and
///   `metadata` (`skill_name`, `help`, `required_for`; tools/skills_tool_setup.py).
/// - Each is answered once, with a JSON-RPC response on the socket: `{"id", "result": {"value"}}`.
///   `""` declines. A response gets no reply (gateway/session_controls.py `dispatch`).
/// - Hermes waits 120 s (gateway/session_sudo_prompt.py, gateway/session_secret_prompt.py; the
///   request does not say so), then withdraws it with a `request.cancel` event `{id, method,
///   reason}`: `timeout`, `interrupted`, or `resolved` once any window answered
///   (gateway/session_server_requests.py). The ones still waiting come with `session.resume`'s
///   `open_requests`, so a reconnect finds them again.
/// What you type lives in the card's field until it goes out; nothing here keeps, logs or saves
/// it, and it never goes into a chat.
extension AppStore {
    /// How long Hermes waits for an answer.
    static let secretWait: TimeInterval = 120

    /// Called once from init: the gateway's sudo and secret requests come here. Screenshot runs can
    /// ask for made-up ones (`-ShionSecretsDemo YES`).
    func startSecrets() {
        gateway.onRequest = { [weak self] method, id, params in
            self?.serverRequest(method, id: id, params: params) ?? false
        }
        guard UserDefaults.standard.bool(forKey: "ShionSecretsDemo"), let demo else { return }
        secrets.requests = demo.secretRequests.map { request in
            var request = request
            request.server = serverKey
            return request
        }
        trail.answered = demo.answeredAsks(server: serverKey)
        chats[demo.secretChatBot, default: []] += demo.secretChat
        for request in demo.secretRequests where request.isOpen {
            asks.insert(secretAsk(request), at: 0)
        }
    }

    /// Which server the requests and answers belong to.
    var serverKey: String { serverSettings.trimmed.signInServer }

    /// A server request: sudo and secret are taken, anything else is left to the gateway's -32601.
    /// One for a chat Shion does not know yet is being attached right now (its resume brings it
    /// back from `open_requests`), or belongs to an assistant hidden here: either way it is not
    /// declined, so another window on that chat can still answer it.
    func serverRequest(_ method: String, id: String, params: JSONValue) -> Bool {
        guard method == "sudo" || method == "secret" else { return false }
        guard let sessionId = params["session_id"]?.string, let botId = sessionBots[sessionId] else { return true }
        take(secretRequest(method, id: id, params: params, botId: botId, sessionId: sessionId, timed: true))
        return true
    }

    /// Whether an answer can go out now: on the connection the request is known on.
    func canAnswer(_ request: SecretRequest) -> Bool {
        request.demo || (gateway.phase == .online && request.connection == gateway.connection)
    }

    /// What you typed, sent once as the request's answer and kept nowhere (the card has already
    /// cleared its field). False when it did not go out: the card says why and stays open.
    @discardableResult
    func submitSecret(_ id: String, value: String) async -> Bool {
        guard !value.isEmpty, let request = secrets.request(id), request.state == .waiting, canAnswer(request) else {
            return false
        }
        return await settleSecret(id, ["value": .string(value)], as: .sent)
    }

    /// 拒绝: an empty answer, which Hermes takes as no.
    func declineSecret(_ id: String) {
        guard let request = secrets.request(id), request.state == .waiting, canAnswer(request) else { return }
        Task { await self.settleSecret(id, ["value": ""], as: .declined) }
    }

    /// 填写 from a one-line row (今天, the ⌥Space window): the card in its chat.
    func openSecret(_ id: String) {
        guard let request = secrets.request(id) else { return }
        route = .chat(request.botId)
        QuickAsk.shared.hide()
        MainWindow.show()
    }

    // MARK: what the chat's events say

    /// From `apply`: the tool a password is for, a request Hermes withdrew, a turn that ended with
    /// one still open.
    func secretEvent(_ type: String, sessionId: String, payload: JSONValue) {
        switch type {
        case "tool.start":
            if let name = payload["name"]?.string ?? payload["tool_name"]?.string {
                secrets.tools[sessionId] = name
            }
        case "request.cancel":
            guard let id = payload["id"]?.string, let request = secrets.request(id), request.sessionId == sessionId else { return }
            withdrawn(request, resolved: payload["reason"]?.string == "resolved")
        case "message.complete":
            endTurn(sessionId)
        case "session.info" where payload["running"]?.bool == false:
            endTurn(sessionId)
        default:
            break
        }
    }

    /// From `attach`: a resume lists what still waits (`open_requests`). Those can be answered on
    /// this connection, one not seen before gets its card, and the open ones it leaves out are over.
    func resumeSecrets(_ botId: String, sessionId: String, snapshot: JSONValue) {
        guard case .array(let open)? = snapshot["open_requests"] else { return }
        var listed: Set<String> = []
        for entry in open {
            guard let id = entry["id"]?.string, let method = entry["method"]?.string,
                  method == "sudo" || method == "secret"
            else { continue }
            listed.insert(id)
            if let known = secrets.request(id) {
                let connection = gateway.connection
                secrets.update(id) { request in
                    request.connection = connection
                    request.problem = nil
                    // Shion gave up on it (a disconnect, its two minutes by this clock) or its answer
                    // never landed (sent before the resume): Hermes still waits, so it is open again
                    if !request.isOpen && request.state != .elsewhere {
                        request.state = .waiting
                    }
                }
                if !known.isOpen && known.state != .elsewhere && !asks.contains(where: { $0.id == id }) {
                    asks.insert(secretAsk(known), at: 0)
                    if let deadline = known.deadline, deadline > Date() {
                        expire(id, at: deadline)
                    }
                }
            } else {
                take(secretRequest(method, id: id, params: entry["params"] ?? .null, botId: botId, sessionId: sessionId, timed: false))
            }
        }
        for request in secrets.requests where request.sessionId == sessionId && request.state == .waiting
            && !request.demo && !listed.contains(request.id) {
            close(request.id, as: .expired)
        }
    }

    /// From `resetPages`: the connection is gone for good, or a new one starts. What still waited
    /// cannot be answered from here any more (a resume that finds it still waiting opens it again);
    /// what is over keeps its line in the chat.
    func endSecrets() {
        for timer in secrets.timers.values {
            timer.cancel()
        }
        secrets.timers = [:]
        secrets.tools = [:]
        for request in secrets.requests where request.isOpen && !request.demo {
            close(request.id, as: .expired)
        }
    }

    /// From `forgetChat`: an assistant Shion no longer follows.
    func forgetSecrets(_ botId: String) {
        for request in secrets.requests where request.botId == botId {
            secrets.timers.removeValue(forKey: request.id)?.cancel()
            asks.removeAll { $0.id == request.id }
        }
        secrets.requests.removeAll { $0.botId == botId }
    }

    // MARK: the requests

    private func secretRequest(_ method: String, id: String, params: JSONValue, botId: String, sessionId: String,
                               timed: Bool) -> SecretRequest {
        let now = Date()
        var request = SecretRequest(id: id, kind: method == "sudo" ? .password : .key, botId: botId,
                                    sessionId: sessionId, at: now,
                                    deadline: timed ? now.addingTimeInterval(Self.secretWait) : nil)
        request.connection = gateway.connection
        request.server = serverKey
        switch request.kind {
        case .password:
            request.command = params["command"]?.string ?? ""
            request.tool = secrets.tools[sessionId]
        case .key:
            let metadata = params["metadata"]
            request.envVar = params["env_var"]?.string ?? ""
            request.prompt = params["prompt"]?.string ?? ""
            request.skill = Self.secretWord(metadata?["skill_name"])
            request.help = Self.secretWord(metadata?["help"])
            request.requiredFor = Self.secretWord(metadata?["required_for"])
        }
        return request
    }

    private static func secretWord(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Its entry in 待你处理 (and the counts that go with it): answered on its card.
    func secretAsk(_ request: SecretRequest) -> Ask {
        Ask(id: request.id, kind: .secret, botId: request.botId, at: request.at,
            title: request.kind == .password ? "要一个密码" : "要一个密钥", options: [])
    }

    /// A new request: its card in the chat, an entry in 待你处理, and a notification unless the
    /// chat or 待你处理 is in front of you (or the ⌥Space window shows the assistant). The
    /// notification says who wants a password or a key, nothing more, and cannot be typed into.
    private func take(_ request: SecretRequest) {
        guard secrets.request(request.id) == nil else { return }
        secrets.requests.append(request)
        let ask = secretAsk(request)
        asks.insert(ask, at: 0)
        if let deadline = request.deadline {
            expire(request.id, at: deadline)
        }
        guard !(NSApp.isActive && (route == .confirm || route == .chat(request.botId))),
              !QuickAsk.shared.showsAnswer(from: request.botId) else { return }
        Notifier.shared.ask(ask, from: bot(request.botId)?.name ?? request.botId)
    }

    /// Sends the answer once. `result` carries the value only for the length of this call.
    @discardableResult
    private func settleSecret(_ id: String, _ result: JSONValue, as outcome: SecretRequest.State) async -> Bool {
        guard let request = secrets.request(id) else { return false }
        if request.demo {
            close(id, as: outcome)
            return true
        }
        secrets.update(id) { request in
            request.state = .sending
            request.problem = nil
        }
        do {
            try await gateway.answer(id, result)
        } catch {
            secrets.update(id) { request in
                // withdrawn meanwhile: it stays withdrawn
                guard request.state == .sending else { return }
                request.state = .waiting
                request.problem = error.localizedDescription
            }
            return false
        }
        if secrets.request(id)?.state == .sending {
            close(id, as: outcome)
        }
        return true
    }

    /// Hermes withdrew it: someone answered (`resolved`), or it timed out, or the turn stopped.
    private func withdrawn(_ request: SecretRequest, resolved: Bool) {
        switch request.state {
        case .waiting:
            close(request.id, as: resolved ? .elsewhere : .expired)
        // ours is on its way: the send settles it, unless Hermes stopped waiting first
        case .sending where !resolved:
            close(request.id, as: .expired)
        // ours went out, yet Hermes stopped waiting without taking it
        case .sent where !resolved:
            close(request.id, as: .expired)
        default:
            break
        }
    }

    /// The turn is over: what it still asked for cannot be answered any more.
    private func endTurn(_ sessionId: String) {
        for request in secrets.requests where request.sessionId == sessionId && request.state == .waiting {
            close(request.id, as: .expired)
        }
    }

    /// Hermes's two minutes, and a little for the way: a withdrawal that never came (the
    /// connection dropped meanwhile) ends it here too.
    private func expire(_ id: String, at deadline: Date) {
        secrets.timers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 3))
            guard let self, !Task.isCancelled else { return }
            self.secrets.timers[id] = nil
            if self.secrets.request(id)?.state == .waiting {
                self.close(id, as: .expired)
            }
        }
    }

    /// It is over: its card says how, and it leaves 待你处理 and the notifications.
    private func close(_ id: String, as state: SecretRequest.State) {
        secrets.update(id) { request in
            request.state = state
            request.problem = nil
        }
        secrets.timers.removeValue(forKey: id)?.cancel()
        asks.removeAll { $0.id == id }
        Notifier.shared.withdraw(id)
    }
}
