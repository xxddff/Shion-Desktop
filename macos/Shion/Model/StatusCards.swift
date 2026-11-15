import Foundation
import Observation

/// What Hermes says on its own around a chat's turns that is no row of its transcript, read as the
/// official client reads it (apps/desktop/src/app/session/hooks/use-message-stream/gateway-event:
/// status.ts and message-stream.ts, Hermes 611bf53), each a card in the chat whose session it came
/// on (AppStore+Events.swift):
/// - a compaction (`status.update` kinds `compacting` and `compressing`, ended by `compacted` and
///   `ready`): one card while it runs, the same card once it is over, and the transcript's
///   compaction row once a page has it (`ChatStatus`);
/// - an explained wait for the model provider (`thinking.delta` saying what is waited for): one card
///   while the wait lasts, gone once the reply goes on or the turn ends (`ChatStatus`);
/// - a switch to the fallback model, a /goal verdict, a turn picked up again after a crash
///   (`status.update`), the answer to a /btw side question and what a /bg side task came back with
///   (`btw.complete`, `background.complete`) and Hermes's out-of-band notices (`notification.show`,
///   `notification.clear`): kept with the cards the review leaves (AppStore.notes, `StatusNotes`),
///   since no transcript row holds them.
/// The board's word (`status.update` kind `process`) is NoticeCards'. Foundation only, so it can be
/// checked away from a Mac.
nonisolated enum HermesStatus {
    /// A `status.update`'s word on a compaction: one runs, in Hermes's line for it now, or it is over.
    enum Compaction: Equatable, Sendable {
        case runs(String)
        case over(String)
    }

    /// `compacting` (a compaction Hermes runs by itself, every line of it: the preflight's, the
    /// summarizing one, the heartbeat a long one repeats every minute) or `compressing` (/compress
    /// in Hermes's own terminal client) runs until `compacted` or `ready`
    /// (agent/conversation_compression.py, gateway/run_turn_progress.py `_viewer_status_kind`).
    /// Not a warning the gateway tags `compacting` because it speaks of compression ("⚠️  Session
    /// compressed 2 times — accuracy may degrade…", the summary model's feasibility notice), which
    /// Hermes sends once a compaction is done and again as the next turn starts: nothing runs for it
    /// and no `compacted` follows (macos/ci/real, stage held). Hermes marks its warnings with ⚠, its
    /// compaction's lines with 🗜️, 📦 and 💤.
    static func compaction(kind: String?, text: String) -> Compaction? {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case "compacting", "compressing": return isWarning(said) ? nil : .runs(said)
        case "compacted", "ready": return .over(said)
        default: return nil
        }
    }

    /// A line Hermes marks as a warning: it opens with ⚠ (U+26A0, alone or as the emoji ⚠️).
    static func isWarning(_ text: String) -> Bool {
        text.unicodeScalars.first == "\u{26A0}"
    }

    /// A line that says the session left its model for the fallback one: kind `fallback`, or a
    /// lifecycle line in Hermes's words for it ("⚠️ Model fallback: … unavailable (…); using …",
    /// agent/chat_completion_helpers.py), as the official client's isFallbackSwitchStatus reads it.
    static func isFallbackSwitch(kind: String?, text: String) -> Bool {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == "fallback" { return !said.isEmpty }
        return said.range(of: "model fallback|provider fallback|switched to fallback|switching to fallback",
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Hermes picking up a turn a crash or a restart cut off, as it says so right before that turn
    /// starts: a `process` line, "Resuming interrupted turn…" (tui_gateway/session_auto_continue.py;
    /// at 611bf53 only the sidecar of Hermes's own clients says it, the gateway Shion talks to does not).
    static func isResume(_ text: String) -> Bool {
        text.range(of: "^resuming interrupted turn", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The wait a `thinking.delta` explains, in Hermes's words: a provider that has said nothing
    /// for a minute ("⏳ waiting on <model> — 60s waiting for the first stream chunk …",
    /// agent/chat_completion_wait_notice.py), a local model loading, a prompt being read. Nil for
    /// every other such frame (the spinner's faces, and the empty one that clears it): the
    /// official client's providerWaitText.
    static func providerWait(_ text: String) -> String? {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let explained = "^(?:⏳|⚠|↻|⚙)\\s*(?:(?:still\\s+)?waiting on|loading|processing prompt|no (?:output|response)"
            + "|model returned|rate limited|provider (?:overloaded|temporarily unavailable))"
        return said.range(of: explained, options: [.regularExpression, .caseInsensitive]) != nil ? said : nil
    }

    /// Frames after which a wait for the provider is over: the reply, a tool, the turn's end
    /// (the official PROVIDER_WAIT_SUPERSEDING_EVENT_TYPES).
    static let endsWait: Set<String> = [
        "error", "message.complete", "message.delta", "message.interim", "message.start", "reasoning.available",
        "reasoning.delta", "tool.complete", "tool.generating", "tool.start",
    ]

    /// Frames that say a turn went on after a compaction in it: the model's output or a tool. A
    /// compaction in a turn has no start of its own to end it (the official
    /// COMPACTION_RESUME_EVENT_TYPES). Hermes says nothing while it summarizes: the next of these
    /// comes after its `compacted`, or, when it gave up (too little to fold, a summary that
    /// failed), after nothing (macos/ci/real, stage held).
    static let resumesTurn: Set<String> = [
        "message.delta", "message.interim", "thinking.delta", "reasoning.delta", "reasoning.available",
        "moa.reference", "moa.aggregating", "moa.progress", "moa.phase", "tool.start", "tool.generating", "tool.complete",
    ]

    /// Frames after which nothing a turn began runs any more: its end, its failure, the start of
    /// the next one (a compaction runs inside a turn).
    static let endsTurn: Set<String> = ["message.complete", "message.start", "error"]
}

/// The live part of what a chat shows of Hermes's own words: the compaction under way and the ones
/// seen since connecting, and the wait for the provider under way. Not kept: once the transcript is
/// read again a compaction is its row there (AppStore.transcriptItems), and a wait that is over is
/// gone. Keyed by assistant, as the chats are.
@Observable
final class ChatStatus {
    /// bot id → the compaction under way: Hermes's line for it now, and when it began. Its card
    /// is the newest of `compactions`, once the chat's rows are loaded.
    private(set) var running: [String: Running] = [:]
    /// bot id → the cards of the compactions seen while the chat was open, oldest first.
    private(set) var compactions: [String: [ChatItem]] = [:]
    /// bot id → the wait for the provider under way, as its card.
    private(set) var waits: [String: ChatItem] = [:]
    /// card id → the highest transcript row the chat knew when its compaction began. Hermes stores
    /// a compaction's summary as a row of its own, under a number past every row before it (row
    /// numbers only grow: macos/ci/real, stage compact), so a summary row past this is the card's
    /// or a later compaction's.
    @ObservationIgnored private var after: [String: Int] = [:]

    struct Running: Equatable {
        var line: String
        var since: Date
    }

    static let compactionPrefix = "status-compaction-"
    static let waitPrefix = "status-wait-"
    /// The compactions of a chat it keeps cards of, the newest.
    static let kept = 20

    /// Hermes is compacting the chat's session: what is sent meanwhile can wait (排队) or go into the
    /// turn (引导), not turn it now (打断, Compose.swift).
    func compacting(_ botId: String) -> Bool {
        running[botId] != nil
    }

    // MARK: frames

    /// A frame of the chat's session, live or replayed, as AppStore.apply takes it. `shown`: the
    /// chat's rows are loaded, so the compaction has its card now (else once they are: `opened`);
    /// `after` is the highest transcript row the chat knows, for a compaction that begins now.
    func take(_ type: String, _ payload: JSONValue, in botId: String, at: Date, shown: Bool, after row: Int?) {
        if HermesStatus.endsWait.contains(type) { endWait(botId) }
        if HermesStatus.resumesTurn.contains(type) || HermesStatus.endsTurn.contains(type) { end(botId) }
        switch type {
        case "status.update":
            guard let said = HermesStatus.compaction(kind: payload["kind"]?.string, text: payload["text"]?.string ?? "")
            else { break }
            switch said {
            case .runs(let line): runs(line, in: botId, at: at, shown: shown, after: row)
            case .over(let line): over(line, in: botId)
            }
        case "thinking.delta":
            think(payload["text"]?.string ?? "", in: botId, at: at)
        case "session.info" where payload["running"]?.bool == false:
            // nothing runs: whatever ran is over, also when its own end was not seen (the official
            // client's reconcile on a gateway-authored running=false)
            end(botId)
            endWait(botId)
        default:
            break
        }
    }

    /// A compaction runs, in this line: the one under way says it, or one begins.
    func runs(_ line: String, in botId: String, at: Date, shown: Bool, after row: Int?) {
        if running[botId] == nil {
            running[botId] = Running(line: line, since: at)
            if shown { begin(botId, at: at, line: line, after: row) }
            return
        }
        running[botId]?.line = line
        if let last = compactions[botId]?.indices.last, Self.state(of: compactions[botId]![last]) == .running {
            compactions[botId]![last].text = line
        } else if shown {
            begin(botId, at: running[botId]!.since, line: line, after: row)
        }
    }

    /// Hermes says the compaction is over (`compacted`, `ready`): its card is done. Said after its
    /// turn ended first (nothing seen in between), it is the newest card's word all the same.
    func over(_ line: String, in botId: String) {
        if running[botId] != nil { running[botId] = nil }
        guard let last = compactions[botId]?.indices.last, Self.state(of: compactions[botId]![last]) != .done else { return }
        compactions[botId]![last].event = .compaction(.done, messages: nil)
        if !line.isEmpty { compactions[botId]![last].text = line }
    }

    /// The compaction under way stopped without Hermes's word that it is done: its turn went on,
    /// ended, failed, or nothing runs any more. Most likely nothing was compacted (Hermes gives up
    /// on one with too little to fold without a word), unless the transcript turns out to have its
    /// summary (`settle`).
    func end(_ botId: String) {
        // only a write that changes something: every piece of a reply comes through here, and each
        // write would have the chat's composer drawn again
        guard running[botId] != nil else { return }
        running[botId] = nil
        if let last = compactions[botId]?.indices.last, Self.state(of: compactions[botId]![last]) == .running {
            compactions[botId]![last].event = .compaction(.ended, messages: nil)
        }
    }

    /// The chat's rows were loaded while a compaction ran: its card, from when it began, past the
    /// rows the chat now knows (`after`).
    func opened(_ botId: String, after row: Int?) {
        guard let running = running[botId],
              compactions[botId]?.last.map({ Self.state(of: $0) == .running }) != true
        else { return }
        begin(botId, at: running.since, line: running.line, after: row)
    }

    /// A snapshot of the session (an attach, a rejoin): when it says nothing runs, nothing that ran is
    /// running still, whatever its last frames said.
    func attached(_ botId: String, running: Bool) {
        guard !running else { return }
        end(botId)
        endWait(botId)
    }

    /// The wait for the provider is over, if there is one (a write only then: the spinner's every
    /// face comes through here, and each write would have the chat drawn again).
    private func endWait(_ botId: String) {
        if waits[botId] != nil { waits[botId] = nil }
    }

    private func begin(_ botId: String, at: Date, line: String, after row: Int?) {
        let id = Self.compactionPrefix + UUID().uuidString
        var cards = compactions[botId] ?? []
        cards.append(ChatItem(id: id, role: .card, at: at, text: line, event: .compaction(.running, messages: nil)))
        if let row { after[id] = row }
        for gone in cards.dropLast(Self.kept) { after[gone.id] = nil }
        compactions[botId] = Array(cards.suffix(Self.kept))
    }

    /// A `thinking.delta`: a wait it explains shows as one card, its words the newest, from when the
    /// wait began; any other such frame (the spinner, the empty one that clears it) ends it.
    func think(_ text: String, in botId: String, at: Date) {
        guard let wait = HermesStatus.providerWait(text) else {
            endWait(botId)
            return
        }
        if waits[botId] != nil {
            waits[botId]?.text = wait
        } else {
            waits[botId] = ChatItem(id: Self.waitPrefix + UUID().uuidString, role: .card, at: at, text: wait,
                                    event: .providerWait)
        }
    }

    // MARK: the transcript

    /// The chat now holds these rows (a page was read): a compaction whose summary row is among
    /// them is done, and is that row from now on (`cards`).
    func settle(_ botId: String, rows: [ChatItem]) {
        guard let cards = compactions[botId] else { return }
        for index in Self.matched(cards, rows: rows, after: after).keys {
            if Self.state(of: cards[index]) == .running { running[botId] = nil }
            if Self.state(of: cards[index]) != .done {
                compactions[botId]?[index].event = .compaction(.done, messages: nil)
            }
        }
    }

    /// The live cards a chat shows among `rows`: each compaction no summary row of `rows` stands for,
    /// and the wait under way.
    func cards(_ botId: String, rows: [ChatItem]) -> [ChatItem] {
        let live = compactions[botId] ?? []
        let matched = Self.matched(live, rows: rows, after: after)
        var shown = live.indices.filter { matched[$0] == nil }.map { live[$0] }
        if let wait = waits[botId] { shown.append(wait) }
        return shown
    }

    /// Which compaction card (by index) a summary row of `rows` stands for (its number), from the
    /// newest card back: a card's row is the newest summary row past the rows known when it began
    /// and before the row of the card after it. A compaction that folded nothing has no row, and
    /// keeps its card.
    static func matched(_ cards: [ChatItem], rows: [ChatItem], after: [String: Int]) -> [Int: Int] {
        let summaries = rows.compactMap { compactionRow($0.id) }.sorted()
        var matched: [Int: Int] = [:]
        var below = Int.max
        for index in cards.indices.reversed() {
            let floor = after[cards[index].id] ?? Int.min
            guard let row = summaries.last(where: { $0 > floor && $0 < below }) else { continue }
            matched[index] = row
            below = row
        }
        return matched
    }

    /// The row a page's compaction item is (AppStore.transcriptItems): `compaction-21`.
    static func compactionRow(_ id: String) -> Int? {
        guard id.hasPrefix("compaction-") else { return nil }
        return Int(id.dropFirst("compaction-".count).prefix { $0.isNumber })
    }

    static func state(of item: ChatItem) -> ChatEvent.Compacting? {
        if case .compaction(let state, _)? = item.event { return state }
        return nil
    }

    // MARK: letting go

    func forget(_ botId: String) {
        running[botId] = nil
        waits[botId] = nil
        for card in compactions.removeValue(forKey: botId) ?? [] { after[card.id] = nil }
    }

    func forgetAll() {
        running = [:]
        compactions = [:]
        waits = [:]
        after = [:]
    }
}

/// The cards kept among a chat's notes (AppStore.notes, with what the review kept) for frames no
/// transcript row holds: a switch to the fallback model, a /goal verdict and a turn picked up again
/// (`status.update`), a
/// side question's and a side task's answer (`btw.complete`, `background.complete`), and Hermes's
/// notices (`notification.show`). Each is said in Hermes's own words, under a Chinese title
/// (EventCards.swift). A frame names itself in its session's stream (`frame`: its epoch and seq),
/// so the same frame again is the same card; a notice is its key's, so a notice said again with
/// new words is the same card with them (the official client's toast id).
enum StatusNotes {
    static let prefix = "status-"
    /// A card whose frame did not name itself (a server that does not number its frames).
    private static let unnamed = prefix + "unnamed-"
    /// The same words of such a card within this are its frame said again.
    static let saidAgain: TimeInterval = 300

    /// The card `type` and `payload` keep, if any.
    static func card(_ type: String, _ payload: JSONValue, frame: String?, at: Date) -> ChatItem? {
        let text = (payload["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let id = frame.map { prefix + $0 } ?? unnamed + UUID().uuidString
        switch type {
        case "status.update":
            let kind = payload["kind"]?.string
            if kind == "process", HermesStatus.isResume(text) {
                return ChatItem(id: id, role: .card, at: at, text: text, event: .resumed)
            }
            // the compaction's are live (ChatStatus), the board's word is NoticeCards'
            guard HermesStatus.compaction(kind: kind, text: text) == nil, kind != "process" else { return nil }
            if kind == "goal" {
                return ChatItem(id: id, role: .card, at: at, text: text, event: .goal)
            }
            return HermesStatus.isFallbackSwitch(kind: kind, text: text)
                ? ChatItem(id: id, role: .card, at: at, text: text, event: .fallback) : nil
        case "btw.complete":
            let question = (payload["question"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatItem(id: task(payload) ?? id, role: .card, at: at, text: text, event: .aside(question: question))
        case "background.complete":
            return ChatItem(id: task(payload) ?? id, role: .card, at: at, text: text, event: .sideTask)
        case "notification.show":
            let key = payload["key"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            // the whole of what a short line stands for (the low-disk question), under it, as the
            // official client's toast unfolds it
            let detail = (payload["detail"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatItem(id: key.map(noticeId) ?? id, role: .card, at: at, text: detail.isEmpty ? text : text + "\n\n" + detail,
                            event: .notice(level: payload["level"]?.string ?? "info", key: key, cleared: false))
        default:
            return nil
        }
    }

    /// A side task's card is its task's (`task_id`): said again, it is the same answer.
    private static func task(_ payload: JSONValue) -> String? {
        payload["task_id"]?.string.flatMap { $0.isEmpty ? nil : prefix + "task-" + $0 }
    }

    static func noticeId(_ key: String) -> String {
        prefix + "notice-" + key
    }

    /// `card` among `notes`, the newest `limit` of them kept. The same card again (the same frame,
    /// the same task) changes nothing; a notice of a key already there takes that card's place
    /// with its words, its level and its time, so the chat never has two for one key and the
    /// newest word is where it came, unless it says exactly what the card says already.
    static func keep(_ card: ChatItem, in notes: inout [ChatItem], limit: Int) {
        if let index = notes.firstIndex(where: { $0.id == card.id }) {
            guard case .notice = card.event, notes[index].event != card.event || notes[index].text != card.text
            else { return }
            notes.remove(at: index)
        } else if card.id.hasPrefix(unnamed), let last = notes.last(where: { $0.event == card.event }),
                  last.text == card.text, abs(last.at.timeIntervalSince(card.at)) < saidAgain {
            // a frame that names nothing: the same words a moment ago are the same frame again
            return
        }
        notes.append(card)
        notes = Array(notes.suffix(limit))
    }

    /// `notification.clear`: Hermes took the notice of this key back (the access it said was paused
    /// is back, say). Its card stays, settled.
    static func clear(key: String, in notes: inout [ChatItem]) {
        guard let index = notes.firstIndex(where: { $0.id == noticeId(key) }),
              case .notice(let level, let key, false)? = notes[index].event
        else { return }
        notes[index].event = .notice(level: level, key: key, cleared: true)
    }
}
