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
        /// The chat's other messages in the same words as it was said (DeliveryCheck.Before): what
        /// Hermes had, or may have had, that reads the same. Taken then and kept here, not read
        /// off the chat later: by the time it is needed (no receipt came, and only the transcript
        /// can say whether it got there) the chat may have been read again and its item replaced.
        var before: DeliveryCheck.Before?
    }

    private static let seenKept = 500

    func state(_ id: String) -> Delivery? { sent[id]?.state }

    /// Sent now, as the chat's item `id`; the server has not said it has it yet. `before` is what
    /// else in the chat read the same as it was said; a message already followed keeps the one
    /// it has (it is said once, and may go out a moment later).
    func track(_ id: String, botId: String, text: String, at: Date, drafts: [Draft] = [],
               before: DeliveryCheck.Before? = nil) {
        let before = before ?? sent[id]?.before
        sent[id] = seen.contains(id) ? nil
            : Sent(botId: botId, text: text, at: at, state: .sending, drafts: drafts, before: before)
    }

    func set(_ id: String, _ state: Delivery) {
        sent[id]?.state = state
    }

    /// What else in the chat reads the same as it, as it stands now (a message sent again).
    func aim(_ id: String, past before: DeliveryCheck.Before) {
        sent[id]?.before = before
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
        those(in: botId, .unsure)
    }

    /// The messages of a chat put into a running turn as the connection went, oldest first.
    func unconfirmed(in botId: String) -> [(id: String, sent: Sent)] {
        those(in: botId, .unconfirmed)
    }

    private func those(in botId: String, _ state: Delivery) -> [(id: String, sent: Sent)] {
        sent.filter { $0.value.botId == botId && $0.value.state == state }
            .map { (id: $0.key, sent: $0.value) }
            .sorted { $0.sent.at < $1.sent.at }
    }

    /// A chat Shion stops following: its messages are not followed any more.
    func forget(_ botId: String) {
        sent = sent.filter { $0.value.botId != botId }
    }
}
