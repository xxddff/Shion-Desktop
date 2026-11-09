import Foundation

/// 詩音's chat used from outside its page: the ⌥Space window (QuickAsk.swift) and ⌘K.
extension AppStore {
    /// Attaches 詩音's Bot Chat and reads its newest page when a server is connected, so a
    /// sentence sent next has a chat to go into and her reply streams into rows that are shown.
    /// Waits for an opening already under way (her chat page may be opening it at the same time).
    func openChief() async {
        let id = chiefId
        await openChat(id)
        var waited = 0
        while openingChats.contains(id) && waited < 600 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
    }

    /// A sentence for 詩音 from ⌘K, sent once her chat is open.
    func tellChief(_ text: String) {
        Task {
            await openChief()
            send(text, to: chiefId)
        }
    }
}
