import Foundation

/// The cards a chat shows for what happened around its messages (ChatEvent). Most are rows of the
/// transcript read for what they are (Notices.swift, in AppStore.chatItems). Here: the ones that
/// come while the chat is open, and the ones that are no row at all.
extension AppStore {
    // MARK: as they come

    /// A turn Hermes started itself says with what, as it starts (`message.start` with a card's
    /// `display_kind`, `display_text` and the turn's `text`: gateway/session_automation.py). The
    /// card the notice was told with, if it was, is this one, and comes to where its turn begins:
    /// it may have waited behind another turn for as long as that took.
    func noteTurnStart(_ payload: JSONValue, in botId: String) {
        guard let text = payload["text"]?.string, !text.isEmpty else { return }
        let notices = Notices.read(text, kind: payload["display_kind"]?.string, display: payload["display_text"]?.string)
        for card in Self.noticeCards(notices, id: NoticeCards.id(.begun), at: Date()) {
            NoticeCards.begin(card, in: &chats[botId, default: []]) { Self.notice($0) }
        }
    }

    /// The board's word as Hermes's own poller sends it, ahead of the turn it starts
    /// (`status.update`, kind process). Other status lines are not for the chat.
    func noteStatus(_ payload: JSONValue, in botId: String) {
        guard payload["kind"]?.string == "process", let text = payload["text"]?.string else { return }
        let notices = Notices.read(text, kind: nil, display: nil).filter { $0.event == .board }
        for card in Self.noticeCards(notices, id: NoticeCards.id(.told), at: Date()) {
            NoticeCards.tell(card, in: &chats[botId, default: []]) { Self.notice($0) }
        }
    }

    /// A chat's item as NoticeCards tells notices apart: only an event's card says a notice.
    private static func notice(_ item: ChatItem) -> NoticeCards.Held {
        // a row read from a page is under its own id: its number, or its call's for a tool's row
        NoticeCards.Held(id: item.id, event: item.role == .card ? item.event : nil, text: item.text, at: item.at,
                         role: String(describing: item.role),
                         stored: item.id.hasPrefix("row-") || item.id.hasPrefix("tool-") || item.id.hasPrefix("compaction-"))
    }

    /// How many of the newest rows are read for what started a turn, and how many pages further
    /// up (of a page's rows each) when the row is not among them: more turns came while away
    /// than the first read reached.
    private static let noticeRows = 12
    private static let noticePagesAtMost = 6

    /// A turn this Mac did not start (the board's word, another assistant's message, a background
    /// result): Hermes stores what started it as a row and tells a viewer nothing more, so the
    /// newest rows are read for it. At the turn's start, unless it plainly answers a message of
    /// yours, and at the end of a turn that was not one of yours (the row is written as the turn
    /// begins, a moment after the start is announced). The end names the row (`row`:
    /// persisted_turn's user_row_id), and the transcript is read further up until that row was
    /// read: after a long time away each turn's notice is found, not only the ones among the
    /// newest rows (the board's wake and a teammate's message start a turn that says nothing, so
    /// no card that came as a frame asks for its row: the review's RR09).
    ///
    /// A page's rows are matched to the chat's items from the newest back (NoticeCards.put): a row
    /// takes the place of the card that came for it as a frame, live or replayed, and brings its
    /// own id and time; a row no card came for goes in beside the rows it stands between in the
    /// transcript; two rows are two cards, whatever they say. A later read of the page has them
    /// under the same ids.
    func followNotices(_ botId: String, atStart: Bool, row: Int? = nil) {
        guard pagesTranscripts, loadedChats.contains(botId), let sessionId = sessions[botId] else { return }
        if atStart, awaitsOwnReply(botId) { return }
        Task {
            if atStart {
                try? await Task.sleep(for: .milliseconds(600))
            }
            var cursor: String?
            var above: String?
            var read: [Int] = []
            var pages = 0
            while true {
                let asked: JSONValue? = if let cursor {
                    try? await gateway.call("session.transcript", [
                        "profile": .string(botId), "session_id": .string(sessionId), "order": "latest",
                        "limit": .number(Double(Self.pageSize)), "cursor": .string(cursor),
                    ])
                } else {
                    try? await gateway.call("session.transcript", [
                        "profile": .string(botId), "session_id": .string(sessionId), "order": "latest",
                        "limit": .number(Double(Self.noticeRows)),
                    ])
                }
                guard let page = asked, sessions[botId] == sessionId, loadedChats.contains(botId) else { return }
                // the chat may have changed while the page was read: the place is found again by its item
                let put = NoticeCards.put(page: transcriptItems(page), in: &chats[botId, default: []], above: above) {
                    Self.notice($0)
                }
                pages += 1
                read += (page["rows"]?.array ?? []).compactMap { $0["row_id"]?.int }
                guard !atStart, pages <= Self.noticePagesAtMost, let older = page["next_cursor"]?.string,
                      NoticeCards.readsFurther(for: row, read: read, pages: pages,
                                               awaiting: NoticeCards.awaitsRow(chats[botId] ?? [], as: { Self.notice($0) }))
                else { return }
                cursor = older
                above = put.top ?? above
            }
        }
    }

    /// The last message of yours in the chat has no answer yet: the turn starting now is its.
    private func awaitsOwnReply(_ botId: String) -> Bool {
        let items = chats[botId] ?? []
        guard let asked = items.lastIndex(where: { $0.role == .user && !$0.midTurn }) else { return false }
        return !items[(asked + 1)...].contains { item in
            (item.role == .assistant && !item.streaming) || (item.role == .system && (item.stopped || item.failure != nil))
        }
    }

    // MARK: what the review kept

    /// The newest of them are kept: they are not on the server to read again.
    static let notesKept = 30

    /// What the assistant's own review after a turn kept (skills, memory), in its words
    /// (`review.summary`). No row of the transcript and nothing Hermes keeps: it shows while this
    /// Mac has it (the last data keeps the newest). A skill it wrote has its own card, read now.
    func noteLearned(_ payload: JSONValue, in botId: String) {
        let text = (payload["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Silence.isMarker(text) else { return }
        var kept = notes[botId] ?? []
        // a frame replayed after reconnecting says the same again
        if kept.last?.text != text {
            kept.append(ChatItem(id: "note-\(UUID().uuidString)", role: .card, at: Date(), text: text, event: .learned))
            notes[botId] = Array(kept.suffix(Self.notesKept))
        }
        Task { await loadSkillReviews(botId) }
    }

    // MARK: a chat as it shows

    /// The transcript's rows, and among them, by their time, the cards that are not rows: what the
    /// review kept, the skills to look at, and what was asked (withAskCards). Only the cards as
    /// old as the rows read so far: the rest wait above, with the older pages.
    func shownChat(_ botId: String) -> [ChatItem] {
        let rows = chats[botId] ?? []
        let reaches = olderPages[botId] == nil ? Date.distantPast : (rows.first?.at ?? .distantFuture)
        let cards = ((notes[botId] ?? []) + skillCards(botId)).filter { $0.at >= reaches }
        return withAskCards(Self.placing(cards, among: rows), of: botId)
    }

    /// `cards` put among `items` by their time, each after the last item no later than it.
    static func placing(_ cards: [ChatItem], among items: [ChatItem]) -> [ChatItem] {
        var merged = items
        for card in cards.sorted(by: { $0.at < $1.at }) {
            let index = merged.lastIndex { $0.at <= card.at }.map { $0 + 1 } ?? 0
            merged.insert(card, at: index)
        }
        return merged
    }
}
