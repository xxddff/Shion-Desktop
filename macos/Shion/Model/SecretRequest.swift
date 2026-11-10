import Foundation
import Observation

/// A password or a key an assistant asked for in the middle of a turn: Hermes's `sudo` request
/// (the terminal tool's sudo password) or its `secret` request (the value of an environment
/// variable a skill needs, NOTION_API_KEY say). It holds what is asked for and what for, never the
/// answer: that goes from the card's field straight onto the connection (AppStore+Secrets.swift).
struct SecretRequest: Identifiable, Hashable {
    enum Kind: Hashable {
        /// `sudo`: the password for a command run with sudo.
        case password
        /// `secret`: the value of an environment variable.
        case key
    }

    enum State: Hashable {
        /// Waiting for you.
        case waiting
        /// Your answer is on its way.
        case sending
        case sent
        case declined
        /// Hermes stopped waiting: its two minutes were up, or the turn ended.
        case expired
        /// Answered somewhere else: another window on the same chat.
        case elsewhere
    }

    /// The request's JSON-RPC id (`srq-…`), which the answer goes back to. Never shown.
    let id: String
    let kind: Kind
    let botId: String
    let sessionId: String
    /// When it came.
    let at: Date
    /// When Hermes stops waiting; unknown for one first seen on a resume.
    let deadline: Date?
    /// sudo: the command, as Hermes shows it (redacted on the server).
    var command = ""
    /// sudo: the tool that was running when it came (`terminal`).
    var tool: String?
    /// secret: the variable, Hermes's prompt for it, the skill that needs it, and where to get one.
    var envVar = ""
    var prompt = ""
    var skill: String?
    var help: String?
    var requiredFor: String?
    var state: State = .waiting
    /// The connection it can be answered on (Gateway.connection): after a reconnect, it waits for
    /// the resume that finds it still open.
    var connection = 0
    /// Why the answer did not go out, while it can still be given.
    var problem: String?
    /// The screenshots' made-up one: its countdown runs on the demo's clock, nothing is sent.
    var demo = false

    /// Still to be answered (or being answered).
    var isOpen: Bool { state == .waiting || state == .sending }

    /// What it asks for, in a line: 要 sudo 密码, 要 NOTION_API_KEY.
    var asking: String {
        switch kind {
        case .password: return "要 sudo 密码"
        case .key: return envVar.isEmpty ? "要一个密钥" : "要 \(envVar)"
        }
    }

    /// What it is for, in a line: the tool, or the skill and what it needs the key for.
    var purpose: String? {
        switch kind {
        case .password:
            return tool
        case .key:
            let parts = [skill.map { "技能 \($0)" }, requiredFor].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}

/// The requests seen since connecting, oldest first: the open ones, and the ones answered,
/// declined or expired, whose cards stay in their chats until Shion disconnects. Kept in memory
/// only, and only what was asked: nothing here is saved, and no answer is ever in it.
@Observable
final class Secrets {
    var requests: [SecretRequest] = []
    /// session id → the tool it last started: what a sudo password is for.
    @ObservationIgnored var tools: [String: String] = [:]
    /// request id → the wait for Hermes's two minutes to be up.
    @ObservationIgnored var timers: [String: Task<Void, Never>] = [:]

    func request(_ id: String) -> SecretRequest? {
        requests.first { $0.id == id }
    }

    func update(_ id: String, _ change: (inout SecretRequest) -> Void) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        change(&requests[index])
    }
}
