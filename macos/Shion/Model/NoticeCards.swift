import Foundation

/// Which card a notice has in a chat. Hermes says a notice (the board's word, another assistant's
/// message, a background result) up to three times, and none of them names the others: a status
/// line when it has the notice (`status.update`), the start of the turn the notice begins
/// (`message.start`, at once or once the turn under way is over), and the row of the transcript
/// that turn is stored with. A frame carries no time and no row; a frame replayed after a reconnect
/// is no different from a live one. So a card that came as a frame is a card for now: it says so
/// in its id, and the row takes its place when the transcript is read, with the row's id and the
/// row's time. Rows are never one another: two rows are two notices, whatever they say. How near
/// in time two cards are decides nothing but whether a status line was said twice (`toldAgain`).
/// Foundation only, so it can be checked away from a Mac.
nonisolated enum NoticeCards {
    /// How far a card that came as a frame has got.
    enum Stage: Equatable, Sendable {
        /// Hermes told of the notice: its turn has not begun (it waits behind the one under way).
        case told
        /// Its turn began: Hermes stores its row now.
        case begun
    }

    private static let toldPrefix = "notice-told-"
    private static let begunPrefix = "notice-begun-"

    /// A new id for a card that came as a frame.
    static func id(_ stage: Stage) -> String {
        (stage == .told ? toldPrefix : begunPrefix) + UUID().uuidString
    }

    /// Nil for a card with a row behind it (and for anything that is not a notice's card).
    static func stage(of id: String) -> Stage? {
        if id.hasPrefix(toldPrefix) { return .told }
        if id.hasPrefix(begunPrefix) { return .begun }
        return nil
    }

    /// A chat's item, as far as telling notices apart goes. `event` is nil for what is no event's card.
    struct Held: Equatable, Sendable {
        var id: String
        var event: ChatEvent?
        var text: String
        var at: Date
        /// Whose it is (you, the assistant, a card, …): with its words, what tells which row an
        /// item that came live is.
        var role = ""
        /// It is a row of the transcript under the row's own id (read from a page), not something
        /// that came as a frame or was said here: it is that row and no other, whatever it says.
        var stored = false
        /// The transcript row it is known to be: a row read from a page says so in its id, and
        /// what came live learns it as its turn ends (the end names the rows the turn was stored
        /// as: `persisted_turn`). Nil while its turn is under way.
        var row: Int?

        var stage: Stage? { NoticeCards.stage(of: id) }

        /// Hermes gave it to the assistant as a turn: its card stands where that turn begins.
        var startsTurn: Bool { event?.startsTurn == true }

        func says(_ other: Held) -> Bool {
            event != nil && event == other.event && text == other.text
        }

        /// Something that came live and may be this row: the same words from the same side, and
        /// not known to be any row yet.
        func isLive(_ row: Held) -> Bool {
            !stored && self.row == nil && stage == nil && !text.isEmpty && role == row.role && event == row.event
                && text == row.text
        }

        /// This row as read before a compaction stored it again under a new number: a compaction
        /// keeps a row's time (Hermes's, on both) and its words. A notice's card is also the same
        /// card of its row (a row of several notices is several cards, at one time); its words
        /// decide nothing there, its time does: two notices can say the same.
        func wasCopied(as row: Held) -> Bool {
            guard stored, row.stored, id != row.id, role == row.role, at == row.at else { return false }
            return event != nil ? NoticeCards.card(of: id) == NoticeCards.card(of: row.id) : text == row.text
        }
    }

    /// Which of its row's cards an item of a page is (AppStore.noticeCards): `row-12` the first,
    /// `row-12-card2` the second.
    static func card(of id: String) -> Int {
        id.range(of: "-card", options: .backwards).flatMap { Int(id[$0.upperBound...]) } ?? 1
    }

    /// The same status line again within this is the notice said twice (Hermes means to say it
    /// once, and remembers that it did only while its poller lives:
    /// tui_gateway/session_notifications.py, `emitted`); later than this it is another notice in
    /// the same words (a worker that crashed twice).
    static let toldAgain: TimeInterval = 300

    /// A notice Hermes tells of ahead of its turn: whether the chat has its card, told the same way
    /// a moment ago and not begun.
    static func isTold(_ card: Held, among held: [Held]) -> Bool {
        held.contains { $0.stage == .told && $0.says(card) && abs($0.at.timeIntervalSince(card.at)) < toldAgain }
    }

    /// A notice whose turn begins: the card it was told with, if it was (the oldest such, however
    /// long ago: a notice waits as long as the turn before it takes). That card is this one, and
    /// belongs where the turn begins. Nil: it was not told first, and is a new card. A card whose
    /// turn began already is an earlier notice, never this one.
    static func toldBefore(_ card: Held, among held: [Held]) -> Int? {
        held.firstIndex { $0.stage == .told && $0.says(card) }
    }

    /// The notice a frame's card says has its row in the chat already: the newest row saying the
    /// same, with nothing of its turn after it yet (at most other cards that start a turn: a notice
    /// of several lines is several cards). A row with a reply after it is an earlier notice, and
    /// the frame a new one.
    static func hasRow(_ card: Held, among held: [Held]) -> Bool {
        guard let row = held.lastIndex(where: { $0.stage == nil && $0.says(card) }) else { return false }
        return held[(row + 1)...].allSatisfy { $0.event?.startsTurn == true }
    }

    // MARK: rows of the transcript

    /// What a page's rows came to in a chat (`put(page:)`).
    struct Put: Equatable, Sendable {
        /// Cards put in for rows no card stood for.
        var added = 0
        /// Cards that came as frames and are their rows now.
        var settled = 0
        /// The chat's item for the oldest row of the page that the chat has now: the rows of an
        /// older page go above it.
        var top: String?
    }

    /// How far below the newest place it may stand a row is looked for among what came live: the
    /// rows of the page still to place, and this many items that are no row (cards told of, a
    /// line about a turn). Words said again long before are not this row.
    private static let reach = 8

    /// A page of the transcript read while its chat is open, oldest row first: every row that
    /// started a turn has its card in the chat afterwards, once, where the transcript has it.
    ///
    /// The page's rows and the chat's items tell of the same things in the same order, so they are
    /// matched from the newest back, each row to an item above the one the row after it was
    /// matched to:
    /// - the item under the row's own id is the row (read before), and so is the item that was the
    ///   row before a compaction stored it again under a new number (`wasCopied`): it stays as it
    ///   is, the same card or bubble, not one more;
    /// - the item known to be that row is the row: what came live in a turn that is over (its
    ///   reply, the card its start made) was told its rows by the turn's end. Whatever else says
    ///   the same, before or after, is another row (the review's RR10 and RR11 at their root);
    /// - only for a turn still under way, whose items know no row yet: a card that came as a
    ///   frame and says the same is this notice (the newest such card for the newest row), and
    ///   for any other row something that came live in the same words from the same side, none
    ///   further up than the page can reach.
    /// The row takes the place of a card that came as a frame, with its id and its time.
    /// A row that started a turn and has none of these (the gateway's board wake and another
    /// assistant's message: their turn's start says nothing) gets its card: ahead of the item
    /// of the nearest row after it (the reply it started), else behind that of the nearest row
    /// before it, and by its time only when the chat has no row of the page at all. Not by time
    /// otherwise: a row's time is the server's, a live item's is when this Mac took its frame.
    ///
    /// `above` is `top` of the page read before this one (a newer one): nothing of this page is
    /// looked for or put at or below that item.
    @discardableResult
    static func put<Item>(page: [Item], in items: inout [Item], above: String? = nil, as held: (Item) -> Held) -> Put {
        var among = items.map(held)
        var result = Put()
        // the chat's items from here on are of rows after the ones still to place
        var limit = above.flatMap { id in among.firstIndex { $0.id == id } } ?? among.count
        // where the nearest row after the one being placed stands, once one does
        var next: Int?
        // cards with no row after them in the chat yet, the newest first
        var waiting: [Item] = []
        for index in page.indices.reversed() {
            let row = held(page[index])
            let floor = max(0, limit - (index + 1 + reach))
            var found = among[..<limit].lastIndex { $0.id == row.id || $0.wasCopied(as: row) }
            var takesPlace = false
            if found == nil, row.startsTurn {
                // the card its turn's start made, known by the row the turn's end named; else one
                // of a turn still under way that says the same
                found = row.row.flatMap { number in among[..<limit].lastIndex { $0.stage != nil && $0.row == number && $0.says(row) } }
                    ?? among[floor..<limit].lastIndex { $0.stage == .begun && $0.row == nil && $0.says(row) }
                    ?? among[floor..<limit].lastIndex { $0.stage == .told && $0.row == nil && $0.says(row) }
                takesPlace = found != nil
            } else if found == nil {
                found = row.row.flatMap { number in among[..<limit].lastIndex { !$0.stored && $0.stage == nil && $0.row == number } }
                    ?? among[floor..<limit].lastIndex { $0.isLive(row) }
            }
            if let found {
                if takesPlace {
                    items[found] = page[index]
                    among[found] = row
                    result.settled += 1
                }
                // the cards after this row with nothing after them: right behind it, in their order
                for card in waiting {
                    items.insert(card, at: found + 1)
                    among.insert(held(card), at: found + 1)
                    result.added += 1
                }
                waiting = []
                limit = found
                next = found
                result.top = among[found].id
            } else if row.startsTurn {
                if let next {
                    items.insert(page[index], at: next)
                    among.insert(row, at: next)
                    result.added += 1
                    limit = next
                    result.top = row.id
                } else {
                    waiting.append(page[index])
                }
            }
        }
        // the chat has no row of the page: each by its time, among what is above `above`
        for card in waiting {
            let row = held(card)
            let place = among[..<limit].lastIndex { $0.at <= row.at }.map { $0 + 1 } ?? 0
            items.insert(card, at: place)
            among.insert(row, at: place)
            result.added += 1
            limit = place
            result.top = row.id
        }
        return result
    }

    /// Whether to read further up the transcript after `pages` pages, for the row that started a
    /// turn now over (`row`, as its end names it) or for a card that came as a frame and still
    /// has no row (`awaiting`: a turn that failed names none). `read` are the ids of the rows read
    /// so far: a tool call's row has none, so pages of tool calls alone add nothing to them, and
    /// the row is not passed until a row stored before it was read. The row is looked for until it
    /// was read or passed, however far up that is; a card without a row is worth one more page. So
    /// notices that came while away are all found, however many turns there were, and nothing is
    /// read for a turn whose row is among the newest.
    static func readsFurther(for row: Int?, read: [Int], pages: Int, awaiting: Bool) -> Bool {
        if let row, !read.contains(where: { $0 <= row }) { return true }
        return awaiting && pages < 2
    }

    // MARK: on a chat's items

    /// A notice Hermes tells of ahead of its turn (`status.update`): its card at the end of the
    /// chat, unless the chat has it. `held` reads an item as this file tells notices apart.
    static func tell<Item>(_ card: Item, in items: inout [Item], as held: (Item) -> Held) {
        let among = items.map(held)
        if !isTold(held(card), among: among), !hasRow(held(card), among: among) {
            items.append(card)
        }
    }

    /// A notice whose turn begins (`message.start`): its card at the end of the chat, where the
    /// turn's reply follows it; the card it was told with, if it was, goes: it is this one. No
    /// card when the chat has the notice's row already.
    static func begin<Item>(_ card: Item, in items: inout [Item], as held: (Item) -> Held) {
        if let told = toldBefore(held(card), among: items.map(held)) {
            items.remove(at: told)
        }
        if !hasRow(held(card), among: items.map(held)) {
            items.append(card)
        }
    }

    /// A card whose turn began and whose row has not been read: the rows read did not reach it.
    static func awaitsRow<Item>(_ items: [Item], as held: (Item) -> Held) -> Bool {
        items.contains { held($0).stage == .begun }
    }
}
