import Foundation
import Observation

/// The messages you sent that the server has not said it has (AppStore+Reconnect.swift): on their
/// way, unsure because the connection took their receipt with it, or not sent. What you say while
/// not connected is not here: it waits with the ⌥Space window's sentences (QuickAsk.swift).
@Observable
final class Deliveries {
    /// chat item id (also its submission id) → a message sent and not known to be on the server
    private(set) var sent: [String: Sent] = [:]
    /// submission ids the server has named, the last few hundred
    @ObservationIgnored private(set) var seen: Set<String> = []
    @ObservationIgnored private var seenOrder: [String] = []

    struct Sent: Equatable {
        let botId: String
        /// The words, as typed (a message's files are references before them, AppStore+Media.swift).
        let text: String
        let at: Date
        var state: Delivery
        /// The pictures and files that went with the words, up on the server already: 重发 sends
        /// them again.
        var drafts: [Draft] = []
    }

    private static let seenKept = 500

    func state(_ id: String) -> Delivery? { sent[id]?.state }

    /// Sent now, as the chat's item `id`; the server has not said it has it yet.
    func track(_ id: String, botId: String, text: String, at: Date, drafts: [Draft] = []) {
        sent[id] = seen.contains(id) ? nil : Sent(botId: botId, text: text, at: at, state: .sending, drafts: drafts)
    }

    func set(_ id: String, _ state: Delivery) {
        sent[id]?.state = state
    }

    /// It did not go out after all (no connection by the time it could): it waits again instead.
    func untrack(_ id: String) {
        sent[id] = nil
    }

    /// The server named it (a receipt, the pending list, a turn's end): it is there.
    func arrived(_ id: String) {
        if seen.insert(id).inserted {
            seenOrder.append(id)
            if seenOrder.count > Self.seenKept {
                seen.remove(seenOrder.removeFirst())
            }
        }
        sent[id] = nil
    }

    /// The messages of a chat whose receipt the connection took with it, oldest first.
    func unsure(in botId: String) -> [(id: String, sent: Sent)] {
        sent.filter { $0.value.botId == botId && $0.value.state == .unsure }
            .map { (id: $0.key, sent: $0.value) }
            .sorted { $0.sent.at < $1.sent.at }
    }

    /// A chat Shion stops following: its messages are not followed any more.
    func forget(_ botId: String) {
        sent = sent.filter { $0.value.botId != botId }
    }
}
