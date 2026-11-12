import Foundation
import Observation

/// One skill's review, talked over with its assistant in a session of its own: not the Bot Chat,
/// so the chat stays as it was, and a session with no tools, so the talk can change neither the
/// skill nor the assistant's memory and sets off no review of its own (Hermes reviews a turn only
/// when the session has those tools). The session is made under the card's id and remembered on
/// the card, so opening the card again goes back to it.
@Observable
final class SkillReviewTalk: Identifiable {
    let review: SkillReview
    var items: [ChatItem] = []
    var draft = ""
    /// The assistant is answering.
    var busy = false
    var opening = true
    var failure: String?
    private(set) var session: String?
    /// The reply arriving, by its item's id.
    @ObservationIgnored private var streaming: String?

    var id: String { review.id }
    /// The first message's id: what the assistant was given to review with (SkillReviewMaterial).
    var materialId: String { "shion-review-\(review.id)-material" }

    init(review: SkillReview) {
        self.review = review
        session = review.reviewSession
    }

    /// Goes back to the card's session, or makes it and gives the assistant the material.
    func open(in store: AppStore) async {
        opening = true
        failure = nil
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
                try await submit(try await store.reviewMaterial(review), id: materialId, in: store)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The session's rows, and its events on this connection from here on.
    func read(in store: AppStore) async throws {
        guard let session else { return }
        let snapshot = try await store.gateway.call("session.resume", [
            "profile": .string(review.profile), "session_id": .string(session), "display_projection": true,
        ])
        let rows = snapshot["display_messages"]?.array ?? snapshot["messages"]?.array ?? []
        items = rows.flatMap { store.chatItems(from: $0) }.filter { $0.role == .user || $0.role == .assistant }
        // the material is the first thing said, whatever id its row has
        if let first = items.first, first.role == .user {
            items[0].id = materialId
        }
        busy = snapshot["running"]?.bool ?? false
        streaming = nil
    }

    func send(in store: AppStore) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, !opening else { return }
        draft = ""
        let id = UUID().uuidString
        do {
            try await submit(text, id: id, in: store)
        } catch {
            items.removeAll { $0.id == id }
            draft = text
            failure = error.localizedDescription
        }
    }

    private func submit(_ text: String, id: String, in store: AppStore) async throws {
        guard let session else { throw GatewayError.offline }
        failure = nil
        items.append(ChatItem(id: id, role: .user, at: Date(), text: text))
        busy = true
        do {
            try await store.gateway.call("prompt.submit", [
                "profile": .string(review.profile), "session_id": .string(session), "text": .string(text),
                "submission_id": .string(id),
            ])
        } catch {
            busy = false
            throw error
        }
    }

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
            if let final = payload["text"]?.string, !final.isEmpty {
                if streaming == nil {
                    grow(final)
                } else if let index = items.firstIndex(where: { $0.id == streaming }) {
                    items[index].text = final
                }
            }
            close()
            busy = false
            if payload["status"]?.string == "error" {
                failure = AppStore.failureLine(payload, streamed: "")
            }
        case "session.info":
            busy = payload["running"]?.bool ?? busy
        default:
            break
        }
        return true
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
