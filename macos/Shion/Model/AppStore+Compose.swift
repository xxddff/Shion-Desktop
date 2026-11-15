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
    /// assistant (打断 as 排队 while Hermes compacts the session: BusyMode.now), and the turn running
    /// at this moment (Sending). The ⌥Space window, a shortcut, 今天's field and a notification's
    /// reply never ask: theirs is `Sending.queued`.
    func settled(_ mode: BusyMode, to botId: String, sessionId: String) -> Sending {
        Sending(mode: mode.now(compacting: compacting(botId)),
                generation: turnRunning(botId) ? control.fences[sessionId]?.generation : nil)
    }

    /// Hands Hermes a message it has not seen, the item `id` of the chat. Normally a prompt
    /// (`prompt.submit`, which Hermes queues behind a running turn). While the assistant is still
    /// in the turn the message was sent for and `sending` says so, it goes into that turn instead
    /// (`session.steer`, `session.redirect`), as Hermes's own clients send it: named for the run
    /// it was meant for, and words only (pictures travel with a prompt). A turn that began since
    /// (the chat had to be attached again first) is not interrupted for it: it goes as a prompt.
    /// Nor is a turn in which Hermes is compacting the session now: 打断 goes as a prompt then,
    /// whenever it was settled (Sending.correction). What Hermes then says decides:
    /// - taken (`queued`, `redirected`): the item is marked as part of that turn;
    /// - refused outright, or `rejected` with `delivered: false` (the turn was just over, nothing
    ///   live could take it): no assistant saw it, so it goes as a prompt after all;
    /// - `rejected` without that: Hermes says the same after handing it over, so it is not sent
    ///   again by itself (`CorrectionError.refused`);
    /// - no answer, the connection having gone: `CorrectionError.unconfirmed`, for good: nothing
    ///   Hermes publishes names a correction, and no row of the transcript is taken for it.
    func deliver(_ params: [String: JSONValue], id: String, to botId: String, sessionId: String,
                 sending: Sending) async throws {
        if params["attachments"] == nil, let text = params["text"],
           let correction = sending.correction(running: turnRunning(botId), generation: control.fences[sessionId]?.generation,
                                               compacting: compacting(botId)) {
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

    /// A message is said, as the chat's item `id` (already in the chat): followed from this
    /// moment, before anything is awaited. It may wait for the chat to be attached again before it
    /// goes, and the chat be read again meanwhile (loadLatestPage), which must not take it for an
    /// older message in the same words: a message followed is taken for a row only by the row that
    /// names its submission (AppStore.onPage).
    func follow(_ id: String, botId: String, text: String, at: Date, drafts: [Draft] = []) {
        deliveries.track(id, botId: botId, text: text, at: at, drafts: drafts)
    }

    /// Why a message did not reach Hermes, or may not have, on the message.
    func noteUndelivered(_ id: String, _ error: Error) {
        switch error {
        case CorrectionError.unconfirmed:
            deliveries.set(id, .unconfirmed)
            // put into the running turn: it starts no turn of its own, whether it got there or not
            // (重试 and the notices' reading go by what starts a turn)
            if let botId = deliveries.sent[id]?.botId, let index = chats[botId]?.firstIndex(where: { $0.id == id }) {
                chats[botId]?[index].midTurn = true
            }
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
