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

    /// Sends the draft with what is in the composer, as a reply when a message is marked. False
    /// when it did not go (a picture still going up): the draft and the mark stay.
    @discardableResult
    func sendDraft(to botId: String) -> Bool {
        let key = composeKey(botId)
        var text = (drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let target = replies[key], !text.isEmpty {
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

    /// Hands Hermes a message it has not seen, the item `id` of the chat. Normally a prompt
    /// (`prompt.submit`, which Hermes queues behind a running turn). While the assistant is in a
    /// turn and `mode` says so, it goes into that turn instead (`session.steer`,
    /// `session.redirect`), as Hermes's own clients send it: named for the run it is meant for,
    /// and words only (pictures travel with a prompt). What Hermes then says decides:
    /// - taken (`queued`, `redirected`): the item is marked as part of that turn;
    /// - refused outright, or `rejected` with `delivered: false` (the turn was just over, nothing
    ///   live could take it): no assistant saw it, so it goes as a prompt after all;
    /// - `rejected` without that: Hermes says the same after handing it over, so it is not sent
    ///   again by itself (`CorrectionError.refused`);
    /// - no answer, the connection having gone: `CorrectionError.unconfirmed`.
    func deliver(_ params: [String: JSONValue], id: String, to botId: String, sessionId: String,
                 mode: BusyMode) async throws {
        if let method = mode.correction, params["attachments"] == nil, turnRunning(botId),
           let generation = control.fences[sessionId]?.generation, let text = params["text"] {
            let answer: JSONValue?
            do {
                answer = try await gateway.call(method, [
                    "profile": .string(botId), "session_id": .string(sessionId), "text": text,
                    "execution_generation": .number(Double(generation)),
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

    /// Why a message did not reach Hermes, or may not have, on the message.
    func noteUndelivered(_ id: String, _ error: Error) {
        switch error {
        case CorrectionError.unconfirmed:
            deliveries.set(id, .unconfirmed)
        case CorrectionError.refused:
            deliveries.set(id, .unsent("助手这一轮没有接下这句话"))
        case GatewayError.rpc(_, let message, let reason):
            deliveries.set(id, .unsent(DeliveryCheck.refusal(reason) ?? reason ?? message))
        default:
            // no answer before the connection went: unsure until the server can say
            deliveries.set(id, .unsure)
        }
    }
}
