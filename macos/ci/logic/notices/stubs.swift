import Foundation

// Stand-ins for what the store's reading of a turn's notice and of a transcript page leans on
// (AppStore.followNotices, transcriptItems, chatItems, talkBefore and what they call, cut out by
// extract.py), so it compiles and runs away from the app, on Linux or a Mac. Only what they touch;
// NoticeCards.swift, Notices.swift, Silence.swift, TurnFailure.swift, ChatMedia.swift,
// SkillReview.swift, Delivery.swift and JSONValue.swift are the app's own, and so are ChatItem and
// ChatRole (cut from Models.swift by run.sh).

final class ChatControl {
    var storedRows: [String: Int] = [:]
    var namedRows: [String: Set<Int>] = [:]
}

/// Records what every read asks for, and answers as the test scripts it.
final class Gateway {
    var asked: [JSONValue] = []
    var answer: (JSONValue) throws -> JSONValue = { _ in ["rows": [], "next_cursor": nil] }

    @discardableResult
    func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        asked.append(params)
        // the answer comes a moment after the call, as over a socket
        await Task.yield()
        return try answer(params)
    }
}

final class AppStore {
    var pagesTranscripts = true
    var loadedChats: Set<String> = []
    var sessions: [String: String] = [:]
    var chats: [String: [ChatItem]] = [:]
    let control = ChatControl()
    let gateway = Gateway()
}
