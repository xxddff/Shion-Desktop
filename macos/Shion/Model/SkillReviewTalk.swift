import Foundation
import Observation

/// One skill's review, talked over with its assistant in a session of its own: not the Bot Chat,
/// so the chat stays as it was, and a session with no tools, so the talk can change neither the
/// skill nor the assistant's memory and sets off no review of its own (Hermes reviews a turn only
/// when the session has those tools). The session is made under the card's id and remembered on
/// the card, so opening the card again goes back to it.
///
/// What is said in it is sent as the Bot Chat sends (AppStore+Reconnect.swift), under the
/// message's own id: a message stays where it was said whatever becomes of its receipt, and
/// Hermes admits an id once, so sending it again can never make it twice.
@Observable
final class SkillReviewTalk: Identifiable {
    let review: SkillReview
    var items: [ChatItem] = []
    var draft = ""
    /// The assistant is answering.
    var busy = false
    var opening = true
    /// What went wrong last, until something is tried again: the session could not be made or
    /// read, or Hermes ended the turn with an error. 再试一次 goes with it (`retry`).
    var failure: String?
    /// 再试一次 is on its way.
    var retrying = false
    /// The messages of yours Hermes has not said it has, by their item's id (also their
    /// submission id): on their way, unsure because no answer came, or not sent (Delivery).
    private(set) var sent: [String: Delivery] = [:]
    private(set) var session: String?
    /// The reply arriving, by its item's id.
    @ObservationIgnored private var streaming: String?
    /// `failure` is how the last turn ended: 再试一次 asks its message again.
    @ObservationIgnored private var turnFailed = false
    /// An item's id → the transcript row it is, as last read: a rewind names the row.
    @ObservationIgnored private var stored: [String: Int] = [:]
    @ObservationIgnored private var rejoining = false

    var id: String { review.id }
    /// The session is there to be talked in. Not while it could not be made or put on the card:
    /// nothing can be said then, and what is typed stays typed (`send`).
    var ready: Bool { session != nil }
    /// The first message's id: what the assistant was given to review with (SkillReviewMaterial).
    var materialId: String { "shion-review-\(review.id)-material" }

    init(review: SkillReview) {
        self.review = review
        session = review.reviewSession
    }

    /// What the assistant was given to review with, not something you said: folded away. The
    /// session's first message, and the same words again when its turn failed and it was asked again.
    func isMaterial(_ item: ChatItem) -> Bool {
        item.role == .user && (item.id == materialId || SkillReviewMaterial.opens(item.text))
    }

    // MARK: opening

    /// Goes back to the card's session, or makes it and gives the assistant the material.
    func open(in store: AppStore) async {
        opening = true
        failure = nil
        turnFailed = false
        defer { opening = false }
        do {
            if session == nil {
                // asked for under the card's id: asked twice (a lost answer), Hermes gives the same
                // session. No title: Hermes would look for a session of that title first
                let made = try await store.gateway.call("session.create", [
                    "profile": .string(review.profile), "request_id": .string("shion-review-\(review.id)"),
                    "source": "gui", "hidden": true, "toolsets": [], "ignore_rules": true,
                ])
                guard let made = made["session_id"]?.string else { throw GatewayError.offline }
                try await store.bindReview(review, to: made)
                session = made
            }
            try await read(in: store)
            if items.isEmpty {
                let material = try await store.reviewMaterial(review)
                items.append(ChatItem(id: materialId, role: .user, at: Date(), text: material))
                await deliver(materialId, in: store)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The session's rows, and its events on this connection from here on (`session.resume`
    /// attaches it). What the session says settles what is not known here: a message sent
    /// without a receipt is there or it is not (SkillReviewDelivery), a turn runs or it does not,
    /// and the last one failed if its row says so. A reply under way keeps its bubble: what a
    /// replay brought is in it (`caughtUp`); otherwise an ellipsis stands where the part lost was.
    ///
    /// The snapshot is the session as Hermes read it, and its answer comes a moment later, the
    /// session's frames coming on this socket meanwhile: a turn that ends in that moment has ended
    /// here (its reply whole, nothing answering) before a snapshot that has neither the reply's
    /// row nor the end. Put over what the frames said, it would take the reply away and leave the
    /// talk answering for good, no frame being left to say otherwise. So a snapshot older than a
    /// frame already taken is asked for again (SessionWords), and whether a turn runs is the
    /// newest word there is: a later frame's before the snapshot's.
    func read(in store: AppStore, caughtUp: Bool = false) async throws {
        guard let session else { return }
        let params: JSONValue = [
            "profile": .string(review.profile), "session_id": .string(session), "display_projection": true,
        ]
        var snapshot = try await store.gateway.call("session.resume", params)
        var again = 0
        while again < SessionWords.rereads, store.words.outdate(snapshot) {
            again += 1
            snapshot = try await store.gateway.call("session.resume", params)
        }
        // the session's run and revision, which taking a failed turn back names (AppStore.rewind)
        store.noteFences(snapshot)
        let rows = snapshot["display_messages"]?.array ?? snapshot["messages"]?.array ?? []
        let running = store.words.running(after: snapshot) ?? snapshot["running"]?.bool ?? false
        var fresh: [ChatItem] = []
        var places: [String: Int] = [:]
        // how the last turn ended, when Hermes closed it with a failure's row and nothing came since
        var failed: String?
        for var item in rows.flatMap({ store.chatItems(from: $0) }) {
            if item.role == .user || item.role == .assistant {
                let row = item.id.hasPrefix("row-") ? Int(item.id.dropFirst(4)) : nil
                // the material is the first thing said, whatever id its row has
                if fresh.isEmpty, item.role == .user {
                    item.id = materialId
                }
                places[item.id] = row
                fresh.append(item)
                failed = nil
            } else if item.role == .system, let failure = item.failure {
                failed = Self.words(failure)
            }
        }
        // what was said without a receipt: Hermes has it, or it stays under what Hermes has.
        // Words are compared as a row shows them (a file's `@file:` line is not among them)
        let waiting = items.filter { $0.role == .user && sent[$0.id] != nil }
        let found = SkillReviewDelivery.found(
            waiting: waiting.map { (id: $0.id, text: Self.shown($0)) },
            known: items.filter { $0.role == .user && sent[$0.id] == nil }.map(Self.shown),
            rows: fresh.filter { $0.role == .user }.map(\.text),
            pending: DeliveryCheck.pending(in: snapshot))
        for item in waiting {
            switch found[item.id] {
            case .stored?:
                // a row is this message
                sent[item.id] = nil
            case .admitted?:
                sent[item.id] = nil
                fresh.append(item)
            case nil:
                // no answer came, and the session does not have it: it did not get there
                if sent[item.id] == .unsure {
                    sent[item.id] = .unsent(nil)
                }
                fresh.append(item)
            }
        }
        if running, let id = streaming, var reply = items.first(where: { $0.id == id }) {
            if !caughtUp, !reply.text.isEmpty {
                reply.text += "\n\n…\n\n"
            }
            fresh.append(reply)
        } else {
            streaming = nil
        }
        items = fresh
        stored = places
        // a message a row now stands for has nothing more to be told
        sent = sent.filter { state in fresh.contains { $0.id == state.key } }
        busy = running || sent.values.contains(.sending)
        if running {
            // a turn under way: the last one's failure is behind it
            if turnFailed {
                failure = nil
                turnFailed = false
            }
        } else if let failed {
            failure = failed
            turnFailed = true
        } else if turnFailed, fresh.last?.role == .assistant {
            failure = nil
            turnFailed = false
        }
    }

    private static func shown(_ item: ChatItem) -> String {
        AppStore.userItem(id: item.id, at: item.at, text: item.text).text
    }

    /// A failed turn in words: the line a chat gives it, and what to do about it where Shion
    /// has something to say (TurnFailure).
    private static func words(_ failure: TurnFailure) -> String {
        [failure.line, failure.advice].compactMap { $0 }.joined(separator: "\n")
    }

    // MARK: sending

    /// What is typed goes to the session, once there is one. Before that (it could not be made,
    /// or not put on the card: 再试一次 is over the composer) nothing is sent and the draft stays:
    /// a bubble for it would be with nobody, and gone once the session is read.
    func send(in store: AppStore) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !text.isEmpty, !busy, !opening, !retrying else { return }
        draft = ""
        let id = UUID().uuidString
        items.append(ChatItem(id: id, role: .user, at: Date(), text: text))
        await deliver(id, in: store)
    }

    /// 重发: the same words under the same submission id, so that, should Hermes have them after
    /// all, it answers with that admission and runs nothing twice. The message moves to the
    /// bottom, after what Hermes has.
    func resend(_ id: String, in store: AppStore) async {
        guard ready, sent[id]?.resendable == true, !busy, !opening, !retrying,
              let index = items.firstIndex(where: { $0.id == id })
        else { return }
        items.append(items.remove(at: index))
        await deliver(id, in: store)
    }

    /// `prompt.submit` for a message already in `items`, under its item's id. The message stays
    /// where it is whatever comes of it, and the composer is not touched (what was typed since is
    /// yours). The receipt says Hermes has it; a refusal that it does not (没发出去, with 重发); no
    /// answer leaves it unsure, and the session is asked at once, or once the connection is back
    /// (`read`). Every caller has the session (`open`, `send`, `resend`, `askAgain`): a message is
    /// never in `items` without one.
    private func deliver(_ id: String, in store: AppStore) async {
        guard let session, let text = items.first(where: { $0.id == id })?.text else { return }
        sent[id] = .sending
        busy = true
        // Hermes takes a prompt only on a socket that has the session attached
        if !store.gateway.attached.contains(session) {
            try? await read(in: store)
        }
        // a new try begins: what the last one left is no longer what is wrong
        failure = nil
        turnFailed = false
        do {
            try await store.gateway.call("prompt.submit", [
                "profile": .string(review.profile), "session_id": .string(session), "text": .string(text),
                "submission_id": .string(id),
            ])
            sent[id] = nil
        } catch GatewayError.rpc(_, let message, let reason) {
            sent[id] = .unsent(DeliveryCheck.refusal(reason) ?? reason ?? message)
            busy = false
        } catch {
            sent[id] = .unsure
            busy = false
            try? await read(in: store)
        }
    }

    // MARK: trying again

    /// 再试一次, by what went wrong: a session not made or not read is opened again; a message that
    /// did not go out goes again, under its id; a turn Hermes ended with an error is asked again
    /// (`askAgain`). Until the new try starts, what went wrong stays said.
    func retry(in store: AppStore) async {
        guard !opening, !retrying, !busy else { return }
        guard session != nil else { return await open(in: store) }
        if let unsent = items.last(where: { sent[$0.id]?.resendable == true }) {
            return await resend(unsent.id, in: store)
        }
        guard turnFailed else { return await open(in: store) }
        retrying = true
        defer { retrying = false }
        await askAgain(in: store)
    }

    /// The turn that failed, again, as the Bot Chat's 重试 does (AppStore.retryReply): the message
    /// it was for and everything after it are taken back (`session.mutate` rewind), then the same
    /// words go in as a new turn, a new submission. Where Hermes will not take them back in this
    /// session, the words are asked again after them. Nothing of the review is run twice either
    /// way: the session has no tools.
    private func askAgain(in store: AppStore) async {
        guard let session else { return }
        do {
            // the rows as they are now, and which row each is
            try await read(in: store)
        } catch {
            failure = "没能重试：\(error.localizedDescription)"
            return
        }
        // answered meanwhile, or answering: nothing failed any more
        guard turnFailed, !busy, let index = items.lastIndex(where: { $0.role == .user && sent[$0.id] == nil })
        else { return }
        let prompt = items[index]
        var words = prompt.text
        if let row = stored[prompt.id] {
            do {
                let receipt = try await store.rewind(to: row, botId: review.profile, sessionId: session)
                if let typed = receipt["target_message"]?["content"]?.string, !typed.isEmpty {
                    words = typed
                }
                // gone on the server: here too, but for what never got there
                items = Array(items[..<index]) + items[(index + 1)...].filter { sent[$0.id] != nil }
            } catch ControlError.refused(let reason, let detail)
                where ["session_busy", "revision_conflict", "stale_generation"].contains(reason) {
                // the session moved under the rewind: said, and tried again by hand
                failure = "没能重试：\(ControlError.refused(reason, detail: detail).localizedDescription)"
                return
            } catch is ControlError {
                // Hermes will not take the turn back here: the words go in again after it
            } catch {
                failure = "没能重试：\(error.localizedDescription)"
                return
            }
        }
        let id = UUID().uuidString
        items.append(ChatItem(id: id, role: .user, at: Date(), text: words))
        await deliver(id, in: store)
    }

    // MARK: its events

    /// An event of this talk's session, taken; false for any other session's.
    func take(_ type: String, sessionId: String?, _ payload: JSONValue) -> Bool {
        guard let session, sessionId == session else { return false }
        switch type {
        case "message.start":
            busy = true
        case "message.delta":
            grow(payload["text"]?.string ?? "")
        case "message.interim":
            if payload["already_streamed"]?.bool != true {
                grow(payload["text"]?.string ?? "")
            }
            close()
        case "message.complete":
            // a turn that failed ends with Hermes's words about the failure, not with a reply:
            // they are said over the composer, and what had come of the reply stays as it came
            let failed = payload["status"]?.string == "error"
            let streamed = items.first(where: { $0.id == streaming })?.text ?? ""
            if !failed, let final = payload["text"]?.string, !final.isEmpty {
                if streaming == nil {
                    grow(final)
                } else if let index = items.firstIndex(where: { $0.id == streaming }) {
                    items[index].text = final
                }
            }
            close()
            busy = false
            // whose turn it was: Hermes has that message
            if let submission = payload["persisted_turn"]?["submission_id"]?.string {
                sent[submission] = nil
            }
            if failed {
                failure = Self.words(TurnFailure.live(payload, streamed: streamed))
                turnFailed = true
            }
        case "session.info":
            busy = payload["running"]?.bool ?? busy
            // the admissions Hermes lists are there (DeliveryCheck)
            for admission in payload["pending"]?.array ?? [] {
                if let submission = admission["input_id"]?.string {
                    sent[submission] = nil
                }
            }
        default:
            // `session.replay_gap` among them: the store has the session attached again (`rejoin`)
            break
        }
        return true
    }

    /// Hermes ended this session's subscription on a socket that is still up (`session.replay_gap`:
    /// it fell behind), so nothing more of it would come: what it missed is replayed where the
    /// server keeps it, as for a Bot Chat (AppStore.rejoin), and the session is read and attached
    /// again. Whether a turn runs is the session's word, so the talk is not left answering forever.
    func rejoin(in store: AppStore) async {
        guard let session, !opening, !rejoining, store.gateway.phase == .online,
              store.gateway.attached.contains(session)
        else { return }
        rejoining = true
        defer { rejoining = false }
        store.gateway.attached.remove(session)
        var caughtUp = false
        if store.serverCapabilities.contains("event-replay-v1") {
            caughtUp = await store.gateway.replay(session, profile: review.profile)
        }
        do {
            try await read(in: store, caughtUp: caughtUp)
        } catch {
            // not attached: nothing would come. Said, with 再试一次, which reads it again
            busy = false
            failure = "这个会话的后续没有接上：\(error.localizedDescription)"
            turnFailed = false
        }
    }

    private func grow(_ text: String) {
        guard !text.isEmpty else { return }
        if streaming == nil {
            let id = UUID().uuidString
            items.append(ChatItem(id: id, role: .assistant, at: Date(), streaming: true))
            streaming = id
        }
        if let index = items.firstIndex(where: { $0.id == streaming }) {
            items[index].text += text
        }
    }

    private func close() {
        guard let id = streaming, let index = items.firstIndex(where: { $0.id == id }) else { return }
        streaming = nil
        items[index].streaming = false
        if items[index].text.isEmpty {
            items.remove(at: index)
        }
    }
}
