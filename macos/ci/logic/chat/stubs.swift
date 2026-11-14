import Foundation

// Stand-ins for what the Bot Chat's attach and rejoin lean on, so the app's own methods (cut out
// by extract.py) compile and run away from a Mac. JSONValue.swift, EventCursors.swift and
// SecretRequest.swift are the app's own.

nonisolated enum GatewayError: Error {
    case offline
    case timeout(String)
}

enum ChatRole { case user, assistant, system, card, tool }

struct ChatItem: Identifiable, Hashable {
    var id: String
    let role: ChatRole
    var text = ""
    var streaming = false
}

/// What waits for you, as far as attach and rejoin look at it: an approval or question of a
/// session (`remote`), or a password or key (none).
struct RemotePrompt {
    var sessionId: String
}

struct Ask {
    var id: String
    var remote: RemotePrompt?
}

final class Notifier {
    static let shared = Notifier()
    var withdrawn: [String] = []
    func withdraw(_ id: String) { withdrawn.append(id) }
}

final class Gateway {
    var attached: Set<String> = []
    var calls: [String] = []
    var answer: (String, JSONValue) async throws -> JSONValue = { _, _ in .null }
    var replayAnswer = true
    var connection = 1

    @discardableResult
    func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        calls.append(method)
        let result = try await answer(method, params)
        if method == "session.resume", let session = result["session_id"]?.string {
            attached.insert(session)
        }
        return result
    }

    func replay(_ sessionId: String, profile: String) async -> Bool { replayAnswer }
}

final class AppStore {
    let gateway = Gateway()
    var serverCapabilities: Set<String> = ["event-replay-v1", "session-transcript-v1"]
    var pagesTranscripts = true
    var words = SessionWords()
    var resumeAsked: [String: Date] = [:]
    var sessions: [String: String] = [:]
    var sessionBots: [String: String] = [:]
    var streaming: [String: String] = [:]
    var attachMarks: [String: Int] = [:]
    var chats: [String: [ChatItem]] = [:]
    var olderPages: [String: String] = [:]
    var loadedChats: Set<String> = []
    /// What the sidebar says of each assistant, and whether a reply is arriving.
    var working: [String: Bool] = [:]
    var replying: [String: Bool] = [:]
    var asks: [Ask] = []
    let secrets = Secrets()
    var pagesRead = 0

    /// The approvals and questions waiting, in the order they were asked.
    var asked: [String] { asks.filter { $0.remote != nil }.map(\.id) }

    func noteFences(_ frame: JSONValue) {}
    func uniqued(_ items: [ChatItem]) -> [ChatItem] { items }
    func chatItems(from row: JSONValue) -> [ChatItem] {
        let role: ChatRole = row["role"]?.string == "user" ? .user : .assistant
        return [ChatItem(id: "row-\(row["row_id"]?.int ?? 0)", role: role, text: row["text"]?.string ?? "")]
    }
    func setRunning(_ botId: String, _ running: Bool) { working[botId] = running }
    func setReplying(_ botId: String, _ on: Bool) { replying[botId] = on }
    /// As AppStore.addPrompt: one card for a prompt, however often it is named.
    func addPrompt(_ prompt: JSONValue, sessionId: String, botId: String) {
        guard let id = prompt["prompt_id"]?.string, !asks.contains(where: { $0.id == id }) else { return }
        asks.append(Ask(id: id, remote: RemotePrompt(sessionId: sessionId)))
    }
    func loadLatestPage(_ botId: String) async throws { pagesRead += 1 }
    func reconcile(_ botId: String, caughtUp: Bool, snapshot: JSONValue) {}
    func settleCorrections(_ botId: String, _ sessionId: String) async {}

    // a password or key Hermes asks for (AppStore+Secrets.swift), as far as a resume touches it
    func secretRequest(_ method: String, id: String, params: JSONValue, botId: String, sessionId: String,
                       timed: Bool, at: Date = Date()) -> SecretRequest {
        var request = SecretRequest(id: id, kind: method == "sudo" ? .password : .key, botId: botId,
                                    sessionId: sessionId, at: at, deadline: nil)
        request.connection = gateway.connection
        return request
    }
    func secretAsk(_ request: SecretRequest) -> Ask { Ask(id: request.id) }
    func take(_ request: SecretRequest) {
        secrets.requests.append(request)
        asks.insert(secretAsk(request), at: 0)
    }
    func expire(_ id: String, at deadline: Date) {}
    func close(_ id: String, as state: SecretRequest.State) {
        secrets.update(id) { $0.state = state }
        asks.removeAll { $0.id == id }
    }
}
