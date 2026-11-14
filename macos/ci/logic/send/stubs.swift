import Foundation
import Observation

// Stand-ins for what the store's sending and retrying methods lean on, so the production methods
// (cut out by extract.py, and AppStore+Compose.swift whole) compile and run away from the app, on
// Linux or a Mac. Only what they touch. ChatItem and ChatRole are the app's own (cut from
// Models.swift by run.sh), and so is the reading of a page's rows (AppStore.transcriptItems,
// chatItems: extract.py), with ChatMedia.swift, Notices.swift and Silence.swift whole.

struct LaunchOptions { var snapshot = false; static let current = LaunchOptions() }

nonisolated enum GatewayError: Error {
    case offline
    case rpc(code: Int, message: String, reason: String?)
}

struct Draft: Identifiable, Equatable {
    let id = UUID()
    var kind: ChatMedia.Kind
    var name: String
    var mime = "application/octet-stream"
    var sha256: String?
    var path: String?
    var ref: String?
    var ready = true
    var isReady: Bool { ready }
    var media: ChatMedia { ChatMedia(kind: kind, name: name) }
}

nonisolated struct QuickAskWaiting: Equatable, Sendable {
    let id: String
    let text: String
    let at: Date
    var botId: String?
}

final class QuickAsk {
    static let shared = QuickAsk()
    var waiting: [QuickAskWaiting] = []
    func putBack(_ sentences: [QuickAskWaiting]) { waiting = sentences + waiting }
    func sentences(for botId: String?) -> [QuickAskWaiting] { waiting.filter { $0.botId == botId } }
    func wait(_ text: String, for botId: String, at written: Date? = nil) {
        waiting.append(QuickAskWaiting(id: UUID().uuidString, text: text, at: written ?? Date(), botId: botId))
    }
}

final class DiskStub { func keep(_ hash: String) async {} }

final class MediaStub {
    var drafts: [String: [Draft]] = [:]
    let disk = DiskStub()
    func takeDrafts(_ botId: String) -> [Draft] {
        defer { drafts[botId] = nil }
        return drafts[botId] ?? []
    }
}

final class ChatControl {
    struct Fence { var generation: Int?; var revision: Int? }
    var stopping: Set<String> = []
    var retrying: Set<String> = []
    var fences: [String: Fence] = [:]
    var storedRows: [String: Int] = [:]
    #if BEFORE
    // sources from before rows were known by their time and words keep these by their numbers
    var confirmedRows: [String: Set<Int>] = [:]
    #else
    var confirmedRows: [String: Set<StoredUserRow.Identity>] = [:]
    #endif
    var namedRows: [String: Set<Int>] = [:]
    struct Began { var generation: Int; var by: String }
    var began: [String: Began] = [:]

    /// As the production one: never backwards, but for a refusal's fresh fences.
    func note(_ sessionId: String, generation: Int?, revision: Int?, replacing: Bool = false) {
        var fence = fences[sessionId] ?? Fence()
        if let generation { fence.generation = replacing ? generation : max(generation, fence.generation ?? generation) }
        if let revision { fence.revision = replacing ? revision : max(revision, fence.revision ?? revision) }
        fences[sessionId] = fence
    }
}

/// Records every call, and answers as the test scripts it.
final class Gateway {
    enum Phase: Equatable { case offline, connecting, online }
    var phase = Phase.online
    var attached: Set<String> = []
    var calls: [(method: String, params: JSONValue)] = []
    var answer: (String, JSONValue) throws -> JSONValue = { _, _ in ["status": "queued"] }

    @discardableResult
    func call(_ method: String, _ params: JSONValue = [:], keepRefusal: Bool = false) async throws -> JSONValue {
        calls.append((method, params))
        let reply = try answer(method, params)
        // Hermes's refusal (its error object), as the production one hands it to a caller that reads it
        if keepRefusal, let error = reply["error"] { return ["refusal": error] }
        // a session is attached on this socket once its resume is answered
        if method == "session.resume", let session = params["session_id"]?.string { attached.insert(session) }
        return reply
    }

    /// Whether the frames a session missed could be had (Gateway+Replay.swift): as the test says.
    var replays = true
    func replay(_ sessionId: String, profile: String) async -> Bool { replays }

    var methods: [String] { calls.map(\.method) }
}

@Observable
final class AppStore {
    static let pageSize = 50
    var serverKey = "ci"
    var drafts: [String: String] = [:]
    var replies: [String: ReplyTarget] = [:]
    var chats: [String: [ChatItem]] = [:]
    var chatErrors: [String: String] = [:]
    var sessions: [String: String] = [:]
    var sessionBots: [String: String] = [:]
    var busyMode = BusyMode.queue
    var live = true
    var readOnly = false
    var pagesTranscripts = true
    var now: Date { Date() }
    /// bot ids whose turn is under way
    var running: Set<String> = []
    @ObservationIgnored let deliveries = Deliveries()
    @ObservationIgnored let control = ChatControl()
    @ObservationIgnored let gateway = Gateway()
    @ObservationIgnored let media = MediaStub()

    func turnRunning(_ botId: String) -> Bool { live && sessions[botId] != nil && running.contains(botId) }

    // what rejoin and loadLatestPage lean on
    var serverCapabilities: Set<String> = ["event-replay-v1", "session-transcript-v1"]
    /// The chats this socket could not attach again (AppStore.swift): none here, where every
    /// resume is answered. What a refusal does is checked in ../chat, with the production method.
    var unattached: [String: Rejoin.Refused] = [:]
    func notRejoined(_ botId: String, _ sessionId: String, _ error: Error, refused: Int) {}
    var streaming: [String: String] = [:]
    var attachMarks: [String: Int] = [:]
    var loadedChats: Set<String> = []
    var olderPages: [String: String] = [:]
    var olderErrors: [String: String] = [:]
    func resumeParams(_ botId: String, _ sessionId: String) -> JSONValue {
        ["profile": .string(botId), "session_id": .string(sessionId), "omit_messages": true]
    }
    /// As the production one for a snapshot without messages: the rows held stay up until the
    /// newest page replaces them, and what comes meanwhile lands after this mark.
    func attach(_ botId: String, snapshot: JSONValue) {
        guard let sessionId = snapshot["session_id"]?.string else { return }
        sessions[botId] = sessionId
        streaming[botId] = nil
        attachMarks[botId] = chats[botId]?.count ?? 0
        if snapshot["running"]?.bool == true { running.insert(botId) } else { running.remove(botId) }
    }
    func settleAsks(_ sessionId: String, snapshot: JSONValue) {}
    // as AppStore.swift has them, with no frame overtaking a snapshot here
    func resumed(_ botId: String, _ sessionId: String) async throws -> JSONValue {
        try await gateway.call("session.resume", resumeParams(botId, sessionId))
    }
    func runs(_ snapshot: JSONValue) -> Bool { snapshot["running"]?.bool ?? false }
    func waits(_ botId: String) -> Bool { false }
    func uploadAgain(_ drafts: [Draft], botId: String) async -> [Draft]? { nil }
}
