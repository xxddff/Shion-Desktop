import AppKit

/// What the board means for you, on the pages that are not the board: 等你确认's cards, each
/// assistant's 工作记录, and the card notifications. The server's board while connected, the demo
/// day otherwise.
extension AppStore {
    /// The cards that wait on your answer (BoardWork.ask); not those of an assistant hidden in
    /// Settings, which Shion does not follow.
    var cardAsks: [BoardAsk] {
        guard board.active else {
            let blocks = DemoData(now: demoClock).blocks
            return cards.compactMap { card in
                guard card.status == .waiting, let ask = blocks[card.id] else { return nil }
                return BoardAsk(board: nil, cardId: card.id, title: card.title, assignee: card.assignee, ask: ask)
            }
        }
        return board.waitingOnYou.filter { !followsNot($0.assignee) }
    }

    /// An assistant hidden in Settings: its cards stay on the board, and nothing else of it comes in.
    private func followsNot(_ assignee: String?) -> Bool {
        assignee.map { roster.isHidden($0) } ?? false
    }

    /// What 等你确认 holds: approvals and questions, and the cards that wait on your answer.
    var confirmCount: Int { asks.count + cardAsks.count }

    /// Whether an assistant waits on you for something.
    func waitsOnYou(_ botId: String) -> Bool {
        asks.contains { $0.botId == botId } || cardAsks.contains { $0.assignee == botId }
    }

    /// The cards an assistant ran today, on every board, the latest first.
    func workLog(for botId: String) -> [WorkLogEntry] {
        guard board.active else {
            let runs = DemoData(now: demoClock).runs
            let start = BoardWork.today(now)
            return cards.compactMap { card -> WorkLogEntry? in
                let today = (runs[card.id] ?? []).filter { $0.profile == botId && ($0.endedAt ?? .distantFuture) >= start }
                guard !today.isEmpty else { return nil }
                return WorkLogEntry(board: nil, boardName: nil, cardId: card.id, title: card.title, assignee: card.assignee,
                                    status: card.status.demoKey, runs: today)
            }
            .sorted { $0.latest > $1.latest }
        }
        return board.workLog(botId)
    }

    /// A card of 工作记录 as the inspector shows it.
    func workItem(_ entry: WorkLogEntry) -> BoardItem {
        guard board.active, let task = board.task(entry.cardId, on: entry.board) else {
            return BoardItem(id: entry.cardId, title: entry.title, assignee: entry.assignee, status: entry.status,
                             line: card(entry.cardId)?.line ?? "", board: entry.board)
        }
        return BoardItem(
            id: task.id,
            title: task.title,
            assignee: task.assignee,
            status: task.status,
            line: board.line(task, limits: boardLimits) { self.bot($0)?.name ?? $0 },
            progress: task.progress.map { "\($0.done)/\($0.total)" },
            comments: task.comments,
            board: entry.board
        )
    }

    /// A demo card's runs, for its detail while not connected.
    func demoRuns(_ cardId: String) -> [KanbanRun] {
        DemoData(now: demoClock).runs[cardId] ?? []
    }

    /// Opens a card on the board page: from its notification, 等你确认, or a link in a card's detail.
    func openCard(_ id: String, board slug: String?) {
        board.reveal(id, on: slug)
        route = .board
    }

    /// Your answer on a card that waits on you; with `resume` it goes on. Its notification goes.
    /// Returns why it did not go through.
    func answerCard(_ ask: BoardAsk, text: String, resume: Bool) async -> String? {
        Notifier.shared.withdrawCard(ask.cardId, board: ask.board)
        guard board.active else {
            if resume, let index = cards.firstIndex(where: { $0.id == ask.cardId }) {
                cards[index].status = .queued
                cards[index].line = "等下一轮派发"
                cards[index].updatedAt = now
            }
            return nil
        }
        return await board.answer(ask.cardId, on: ask.board, text: text, resume: resume)
    }

    /// Whether a card's moment becomes a notification: not while its board is on the screen, nor
    /// a card waiting on you while 等你确认 is; a done card only when Settings say so; never one of
    /// an assistant hidden in Settings.
    func shouldNotify(_ moment: CardMoment) -> Bool {
        if followsNot(moment.assignee) { return false }
        if moment.kind == .done && !board.notifyDone { return false }
        guard NSApp.isActive else { return true }
        if route == .board && (moment.board == nil || moment.board == board.slug) { return false }
        if route == .confirm && moment.kind == .ask { return false }
        return true
    }
}
