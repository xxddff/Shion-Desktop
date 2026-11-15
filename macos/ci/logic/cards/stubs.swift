import Foundation
import Observation

// Stand-ins for what the store's reading of Hermes's own words leans on (AppStore.noteSaid,
// shownChat, transcriptItems and what they call, cut out by extract.py), so it compiles and runs away
// from the app, on Linux or a Mac. Only what they touch; StatusCards.swift, Compose.swift,
// Notices.swift, Silence.swift, TurnFailure.swift, ChatMedia.swift and JSONValue.swift are the
// app's own, and so are ChatEvent, ChatRole and ChatItem (cut from Models.swift by run.sh).

struct LaunchOptions { var snapshot = false; static let current = LaunchOptions() }

final class ChatControl {
    var storedRows: [String: Int] = [:]
}

@Observable
final class AppStore {
    var live = true
    var chats: [String: [ChatItem]] = [:]
    var notes: [String: [ChatItem]] = [:]
    var olderPages: [String: String] = [:]
    let status = ChatStatus()
    @ObservationIgnored let control = ChatControl()
    /// The frame being taken (AppStore.swift sets it from each frame's params as it comes).
    @ObservationIgnored var frameName: String?

    /// No skill to look at, nothing asked: the cards here are Hermes's words alone.
    func skillCards(_ botId: String) -> [ChatItem] { [] }
    func withAskCards(_ items: [ChatItem], of botId: String) -> [ChatItem] { items }
}
