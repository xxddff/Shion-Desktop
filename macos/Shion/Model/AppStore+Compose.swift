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
    /// they stand now (DeliveryCheck.Before): those stored as a known row, and how many more are
    /// not known not to be there (said and not stored yet, or their own receipt still out). The
    /// words are the item's, or (the item gone from the chat) the ones it was sent with, as a
    /// row shows them.
    func sameWords(as id: String, in botId: String) -> DeliveryCheck.Before {
        var before = DeliveryCheck.Before()
        let items = chats[botId] ?? []
        guard let words = items.first(where: { $0.id == id })?.text
            ?? deliveries.sent[id].map({ Self.userItem(id: id, at: $0.at, text: $0.text).text })
        else { return before }
        for item in items where item.role == .user && item.id != id && item.text == words {
            switch deliveries.state(item.id) {
            case .unsent?, .unconfirmed?:
                // not there, or in doubt itself: it is looked for apart (settleCorrections)
                continue
            case nil, .sending?, .unsure?, .declined?:
                if let row = DeliveryCheck.row(of: item.id) ?? control.storedRows[item.id] {
                    before.rows.insert(row)
                } else {
                    before.unstored += 1
                }
            }
        }
        return before
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
