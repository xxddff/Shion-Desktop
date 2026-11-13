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
        /// Whose it is (you, the assistant, a card, …), to tell a row from a live item of the
        /// same words: only what `place` goes by, for anything that is no notice's card.
        var role = ""

        var stage: Stage? { NoticeCards.stage(of: id) }

        func says(_ other: Held) -> Bool {
            event != nil && event == other.event && text == other.text
        }

        /// A row of the transcript and the chat's item for it: under the row's id, or (what
        /// came live has no row's id yet) the same words from the same side.
        func isRow(_ row: Held) -> Bool {
            id == row.id || (!text.isEmpty && role == row.role && event == row.event && text == row.text)
        }
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

    /// Where a row's card goes.
    enum Place: Equatable, Sendable {
        /// The chat has it, under the row's id.
        case held
        /// In place of the card at this index, which came as a frame and stood for it.
        case inPlaceOf(Int)
        /// A card of its own, at this index: after the last item no later than it.
        case at(Int)
    }

    /// A row of the transcript read while its chat is open: the oldest card that came as a frame
    /// and says the same is this notice (one whose turn began, before one only told of: the row is
    /// written as the turn begins), and the row takes its place, where it is: the frames came in
    /// the order things happened, and a replayed reply is dated when it was replayed, so the row's
    /// own time would put it before replies that came ahead of it. A row takes one card's place,
    /// and never another row's.
    ///
    /// A row no frame's card stood for (the gateway's board wake: its turn's start says nothing)
    /// goes where the transcript has it, among the rows of the page it was read on: ahead of the
    /// nearest row `after` it that the chat has (the reply it started), else behind the nearest
    /// row `before` it. Not by its time while a neighbour is known: a row's time is the server's,
    /// written a moment after the start is announced, and a live item's is when this Mac took its
    /// frame, so the two do not order a notice against the replies around it (run 197 had one
    /// above the reply before it). By time only when the chat has none of its neighbours.
    static func place(row card: Held, among held: [Held], before: [Held] = [], after: [Held] = []) -> Place {
        if held.contains(where: { $0.id == card.id }) { return .held }
        if let index = held.firstIndex(where: { $0.stage == .begun && $0.says(card) })
            ?? held.firstIndex(where: { $0.stage == .told && $0.says(card) }) {
            return .inPlaceOf(index)
        }
        // the same words can be in the chat more than once: the row before it is the newest of
        // them, the row after it the first one past that
        var behind: Int?
        for row in before.reversed() {
            if let index = held.lastIndex(where: { $0.isRow(row) }) { behind = index + 1; break }
        }
        let from = behind ?? 0
        for row in after {
            if let index = held[from...].firstIndex(where: { $0.isRow(row) }) { return .at(index) }
            // said on both sides of the notice: the newest of them is the row after it
            if from > 0, held[from - 1].isRow(row) { return .at(from - 1) }
        }
        if let behind { return .at(behind) }
        return .at(held.lastIndex { $0.at <= card.at }.map { $0 + 1 } ?? 0)
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

    /// A row of the transcript that started a turn, read while the chat is open (`place`).
    /// `before` and `after` are the rows of the page it was read on, around it.
    static func put<Item>(row card: Item, in items: inout [Item], before: [Item] = [], after: [Item] = [],
                          as held: (Item) -> Held) {
        switch place(row: held(card), among: items.map(held), before: before.map(held), after: after.map(held)) {
        case .held:
            break
        case .inPlaceOf(let index):
            items[index] = card
        case .at(let index):
            items.insert(card, at: index)
        }
    }

    /// A card whose turn began and whose row has not been read: the rows read did not reach it.
    static func awaitsRow<Item>(_ items: [Item], as held: (Item) -> Held) -> Bool {
        items.contains { held($0).stage == .begun }
    }
}
