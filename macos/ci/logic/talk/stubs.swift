import Foundation

// Stand-ins for what SkillReviewTalk.swift uses of the app, for a check away from a Mac. The talk
// itself, SkillReview.swift, Delivery.swift and JSONValue.swift are the app's own files.

enum ChatRole { case user, assistant, system, card, tool }

struct ChatItem: Identifiable, Hashable {
    var id: String
    let role: ChatRole
    let at: Date
    var text = ""
    var streaming = false
    var failure: TurnFailure?
}

nonisolated enum GatewayError: LocalizedError {
    case offline
    case timeout(String)
    case rpc(code: Int, message: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case .offline: return "没有连上服务器"
        case .timeout(let what): return "等 \(what) 超时了"
        case .rpc(_, let message, let reason): return reason ?? message
        }
    }
}

nonisolated enum ControlError: LocalizedError {
    case unknownRun
    case notStored
    case refused(String, detail: String?)

    var errorDescription: String? {
        switch self {
        case .unknownRun: return "unknown run"
        case .notStored: return "not stored"
        case .refused(let reason, _):
            switch reason {
            case "session_busy": return "这一轮还没结束"
            case "revision_conflict", "stale_generation": return "对话刚刚变过，再点一次"
            default: return "服务器拒绝了（\(reason)）"
            }
        }
    }
}

final class Gateway {
    enum Phase { case online, connecting }
    var phase = Phase.online
    var attached: Set<String> = []
    /// Every call made, in order.
    var calls: [(method: String, params: JSONValue)] = []
    var answer: (String, JSONValue) async throws -> JSONValue = { _, _ in .null }
    var replays: [String] = []
    var replayAnswer = true

    @discardableResult
    func call(_ method: String, _ params: JSONValue = [:], timeout: Double = 30, keepRefusal: Bool = false) async throws -> JSONValue {
        calls.append((method, params))
        let result = try await answer(method, params)
        if method == "session.resume" || method == "session.create", let session = result["session_id"]?.string {
            attached.insert(session)
        }
        return result
    }

    func replay(_ sessionId: String, profile: String) async -> Bool {
        replays.append(sessionId)
        return replayAnswer
    }
}

final class AppStore {
    let gateway = Gateway()
    var serverCapabilities: Set<String> = ["event-replay-v1"]
    /// The app's own SessionWords (Gateway/EventCursors.swift), noted as Gateway.onFrame does.
    var words = SessionWords()
    var bindFails = false
    var fencesNoted = 0
    var bound: [String] = []
    var rewinds: [Int] = []
    var rewindAnswer: (Int) async throws -> JSONValue = { _ in .null }
    var material = "请和我一起审核你自己沉淀的技能「ci-notes」（这次改过）。资料……"

    func noteFences(_ frame: JSONValue) { fencesNoted += 1 }

    /// As AppStore.chatItems(from:), for the rows a review's session has.
    func chatItems(from row: JSONValue) -> [ChatItem] {
        let at = Date()
        let id = row["row_id"]?.int.map { "row-\($0)" } ?? UUID().uuidString
        let body = row["text"]?.string ?? ""
        switch row["role"]?.string {
        case "user":
            return [ChatItem(id: id, role: .user, at: at, text: body)]
        case "assistant":
            if row["display_kind"]?.string == "failed_turn" {
                let failure = TurnFailure.stored(row, body: body)
                return [ChatItem(id: id, role: .system, at: at, text: failure.line, failure: failure)]
            }
            return body.isEmpty ? [] : [ChatItem(id: id, role: .assistant, at: at, text: body)]
        default:
            return []
        }
    }

    func rewind(to row: Int, botId: String, sessionId: String) async throws -> JSONValue {
        rewinds.append(row)
        return try await rewindAnswer(row)
    }

    func bindReview(_ review: SkillReview, to sessionId: String) async throws {
        if bindFails { throw GatewayError.timeout("plugin.shion.reviews.bind") }
        bound.append(sessionId)
    }

    func reviewMaterial(_ review: SkillReview) async throws -> String { material }

    static func userItem(id: String, at: Date, text: String) -> ChatItem {
        ChatItem(id: id, role: .user, at: at, text: text)
    }
}
