import Foundation

/// What is being written to an assistant, and how it goes out: the draft kept for each chat (and
/// for each card's comment), the message it answers, and the way a message sent during a turn
/// reaches the assistant (Compose.swift).
extension AppStore {
    // MARK: the draft, and the message it answers

    /// One composer per assistant per server: a draft does not follow you to another server.
    private func composeKey(_ botId: String) -> String {
        serverKey + "|" + botId
    }

    /// What is typed and not sent. Kept here rather than in the chat's view, so it is still there
    /// after another page, another chat, or a dropped connection.
    func draft(for botId: String) -> String {
        drafts[composeKey(botId)] ?? ""
    }

    func setDraft(_ text: String, for botId: String) {
        drafts[composeKey(botId)] = text.isEmpty ? nil : text
    }

    func replyTarget(for botId: String) -> ReplyTarget? {
        replies[composeKey(botId)]
    }

    /// The next message in this chat answers `item`.
    func reply(to item: ChatItem, in botId: String) {
        // a message that was itself a reply is quoted by its own words
        let words = ReplyQuote.split(item.text).words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        replies[composeKey(botId)] = ReplyTarget(id: item.id, text: words, theirs: item.role == .assistant)
    }

    func cancelReply(in botId: String) {
        replies[composeKey(botId)] = nil
    }

    /// Sends the draft with what is in the composer, as a reply when a message is marked: the
    /// quote goes with words, and with pictures or files that go without any. False when it did
    /// not go (a picture still going up, or nothing to send: a mark is not a message by itself):
    /// the draft and the mark stay.
    @discardableResult
    func sendDraft(to botId: String) -> Bool {
        let key = composeKey(botId)
        var text = (drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend(botId, text) else { return false }
        if let target = replies[key] {
            text = ReplyQuote.wrap(text, replyingTo: target)
        }
        guard sendMessage(text, to: botId) else { return false }
        drafts[key] = nil
        replies[key] = nil
        return true
    }

    // MARK: a comment on a card

    /// What is typed under a card and not sent, kept as a chat's draft is: it is still there when
    /// the card's detail goes from beside the board to over the page and back, or the board is
    /// left and come back to.
    func cardDraft(for id: String, on board: String?) -> String {
        drafts[cardKey(id, board)] ?? ""
    }

    func setCardDraft(_ text: String, for id: String, on board: String?) {
        drafts[cardKey(id, board)] = text.isEmpty ? nil : text
    }

    private func cardKey(_ id: String, _ board: String?) -> String {
        serverKey + "|card|" + (board ?? "") + "|" + id
    }

    // MARK: during a turn

    /// How a message typed into this chat's composer goes, settled now: the way chosen for a busy
    /// assistant, and the turn running at this moment (Sending). The ⌥Space window, a shortcut,
    /// 今天's field and a notification's reply never ask: theirs is `Sending.queued`.
    func settled(_ mode: BusyMode, to botId: String, sessionId: String) -> Sending {
        Sending(mode: mode, generation: turnRunning(botId) ? control.fences[sessionId]?.generation : nil)
    }

    /// Hands Hermes a message it has not seen, the item `id` of the chat. Normally a prompt
    /// (`prompt.submit`, which Hermes queues behind a running turn). While the assistant is still
    /// in the turn the message was sent for and `sending` says so, it goes into that turn instead
    /// (`session.steer`, `session.redirect`), as Hermes's own clients send it: named for the run
    /// it was meant for, and words only (pictures travel with a prompt). A turn that began since
    /// (the chat had to be attached again first) is not interrupted for it: it goes as a prompt.
    /// What Hermes then says decides:
    /// - taken (`queued`, `redirected`): the item is marked as part of that turn;
    /// - refused outright, or `rejected` with `delivered: false` (the turn was just over, nothing
    ///   live could take it): no assistant saw it, so it goes as a prompt after all;
    /// - `rejected` without that: Hermes says the same after handing it over, so it is not sent
    ///   again by itself (`CorrectionError.refused`);
    /// - no answer, the connection having gone: `CorrectionError.unconfirmed`.
    func deliver(_ params: [String: JSONValue], id: String, to botId: String, sessionId: String,
                 sending: Sending) async throws {
        if params["attachments"] == nil, let text = params["text"],
           let correction = sending.correction(running: turnRunning(botId), generation: control.fences[sessionId]?.generation) {
            // should the connection go before the answer: what else in the chat read the same
            // when it was said (`say`). Not asked of the chat now: it may have been read again
            // while this waited to go, and its item taken for an older row in the same words
            if deliveries.sent[id]?.before == nil {
                deliveries.aim(id, past: sameWords(as: id, in: botId))
            }
            let answer: JSONValue?
            do {
                answer = try await gateway.call(correction.method, [
                    "profile": .string(botId), "session_id": .string(sessionId), "text": text,
                    "execution_generation": .number(Double(correction.generation)),
                ])
            } catch GatewayError.rpc {
                answer = nil
            } catch {
                throw CorrectionError.unconfirmed
            }
            if let answer {
                if ["queued", "redirected"].contains(answer["status"]?.string ?? "") {
                    if let index = chats[botId]?.firstIndex(where: { $0.id == id }) {
                        chats[botId]?[index].midTurn = true
                    }
                    return
                }
                guard answer["delivered"]?.bool == false else { throw CorrectionError.refused }
            }
        }
        try await gateway.call("prompt.submit", .object(params))
    }

    /// The chat's other messages in the same words as item `id` that Hermes has or may have, as
    /// they stand now (DeliveryCheck.Before): those stored as a known row (read from the
    /// transcript, also by their time and words), and (by their ids) the ones not known not to be
    /// there, said and not stored yet or their own receipt still out. The words are the item's,
    /// or (the item gone from the chat) the ones it was sent with, as a row shows them. And the
    /// item that began the turn under way, which Hermes stored before it.
    func sameWords(as id: String, in botId: String) -> DeliveryCheck.Before {
        var before = DeliveryCheck.Before()
        let items = chats[botId] ?? []
        if let index = items.firstIndex(where: { $0.id == id }),
           let start = items[..<index].last(where: { Self.startsTurn($0) }) {
            // one read from the transcript has its row's time already
            before.turn = DeliveryCheck.TurnStart(id: start.id, at: Self.rowNumber(start.id) == nil ? nil : start.at)
        }
        guard let words = words(of: id, in: botId) else { return before }
        for item in items where item.role == .user && item.id != id && item.text == words {
            switch deliveries.state(item.id) {
            case .unsent?, .unconfirmed?:
                // not there, or in doubt itself: it is looked for apart (settleCorrections)
                continue
            case nil, .sending?, .unsure?, .declined?:
                if let row = DeliveryCheck.row(of: item.id) {
                    before.rows.insert(row)
                    // a row read from the transcript has Hermes's time, which stays with it when a
                    // compaction stores it again under a new number
                    before.identities.insert(StoredUserRow(text: item.text, at: item.at).identity)
                } else if let row = control.storedRows[item.id] {
                    before.rows.insert(row)
                } else {
                    before.others.insert(item.id)
                }
            }
        }
        return before
    }

    /// A message's words as a row shows them: the chat's item's, or the ones it was sent with.
    private func words(of id: String, in botId: String) -> String? {
        chats[botId]?.first(where: { $0.id == id })?.text
            ?? deliveries.sent[id].map { Self.userItem(id: id, at: $0.at, text: $0.text).text }
    }

    /// A message is said, as the chat's item `id` (already in the chat): followed from this
    /// moment, before anything is awaited, with what else in the chat reads the same now on its
    /// record. It may wait for the chat to be attached again before it goes, and the chat be read
    /// again meanwhile (loadLatestPage), which must not take it for an older message in the same
    /// words. The messages in its words that Hermes has not said it has learn of it too: it was
    /// said after them (`noteSaid`).
    func follow(_ id: String, botId: String, text: String, at: Date, drafts: [Draft] = []) {
        deliveries.track(id, botId: botId, text: text, at: at, drafts: drafts, before: sameWords(as: id, in: botId))
        noteSaid(id, in: botId)
    }

    /// A message said again (重发, 再发一次), moved to the bottom of the chat: what else reads the
    /// same is what the chat has at this moment, all of it before this one.
    func followAgain(_ id: String, in botId: String) {
        deliveries.saidAgain(id, past: sameWords(as: id, in: botId))
        noteSaid(id, in: botId)
    }

    /// The messages in `id`'s words that the server has not said it has are told `id` was said
    /// after them: should Hermes store it, its row is not theirs (DeliveryCheck.Others.later).
    private func noteSaid(_ id: String, in botId: String) {
        guard let words = words(of: id, in: botId) else { return }
        for (other, sent) in deliveries.sent where other != id && sent.botId == botId
            && Self.userItem(id: other, at: sent.at, text: sent.text).text == words {
            deliveries.said(id, after: other)
        }
    }

    /// What is known now of the other messages in the words of message `id`, for looking at the
    /// transcript for it (DeliveryCheck.stored). The messages its record names (the ones that
    /// read the same when it was said, and the ones said after it) are asked one by one what
    /// became of them: one whose row is known by now is that row; one Hermes does not have
    /// counts for nothing; one Hermes may still have, as a row nobody can name, counts as one.
    /// `taken` are rows that have confirmed other messages put into a turn, by their time and words.
    func others(of id: String, in botId: String, taken: Set<StoredUserRow.Identity> = []) -> DeliveryCheck.Others {
        let sent = deliveries.sent[id]
        let before = sent?.before ?? sameWords(as: id, in: botId)
        var known = DeliveryCheck.Others(rows: before.rows, identities: before.identities.union(taken))
        known.earlier = unknown(before.others, in: botId, rows: &known.rows)
        known.later = unknown(sent?.later ?? [], in: botId, rows: &known.rows)
        return known
    }

    /// Of these messages, how many Hermes may have as a row not known. The rows of the ones
    /// whose row is known by now go into `rows`.
    private func unknown(_ ids: Set<String>, in botId: String, rows: inout Set<Int>) -> Int {
        var count = 0
        for id in ids {
            if let row = control.storedRows[id] {
                rows.insert(row)
            } else if !absent(id, in: botId) {
                count += 1
            }
        }
        return count
    }

    /// A message that has no row to be mistaken for another's. Hermes refused it or it was found
    /// not to have got there (没发出去), or the turn it was put into did not take it (most
    /// assistants then never saw it; one that runs on Codex may have, and Hermes does not say
    /// which, so this is the likelier reading and not a certainty). It never went out, and waits
    /// with what is said while not connected. Or it is in doubt itself: it is looked for by
    /// itself, ahead of a later one, and a row found for it is taken.
    private func absent(_ id: String, in botId: String) -> Bool {
        switch deliveries.state(id) {
        case .unsent?, .declined?, .unconfirmed?:
            return true
        case .sending?, .unsure?:
            return false
        case nil:
            return QuickAsk.shared.sentences(for: botId).contains { $0.id == id }
        }
    }

    /// Why a message did not reach Hermes, or may not have, on the message.
    func noteUndelivered(_ id: String, _ error: Error) {
        switch error {
        case CorrectionError.unconfirmed:
            deliveries.set(id, .unconfirmed)
        case CorrectionError.refused:
            deliveries.set(id, .declined)
        case GatewayError.rpc(_, let message, let reason):
            deliveries.set(id, .unsent(DeliveryCheck.refusal(reason) ?? reason ?? message))
        default:
            // no answer before the connection went: unsure until the server can say
            deliveries.set(id, .unsure)
        }
    }
}
