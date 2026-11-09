import Foundation

/// 总秘书's chat used from outside its page: the ⌥Space window (QuickAsk.swift) and ⌘K.
extension AppStore {
    /// Attaches 总秘书's Bot Chat and reads its newest page when a server is connected, so a
    /// sentence sent next has a chat to go into and the reply streams into rows that are shown.
    /// Waits for an opening already under way (the chat page may be opening it at the same time).
    func openChief() async {
        let id = chiefId
        await openChat(id)
        var waited = 0
        while openingChats.contains(id) && waited < 600 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
    }

    /// A sentence for 总秘书 from ⌘K, sent once the chat is open.
    func tellChief(_ text: String) {
        Task {
            await openChief()
            send(text, to: chiefId)
        }
    }
}
