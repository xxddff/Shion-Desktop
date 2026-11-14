import Foundation

/// Skills the assistants taught themselves, looked at after the fact: the cards the shion plugin
/// files from Hermes's skill ledger (`plugin.shion.reviews.*`, hermes-plugin/README.md). Each
/// assistant has its own skills, so every call names its profile; a profile without the plugin
/// (or with one before 0.2) simply has no cards.
extension AppStore {
    /// An assistant's cards, read again: on connecting, when the plugin says they changed, and
    /// when the assistant's review after a turn says it kept something.
    func loadSkillReviews(_ botId: String) async {
        guard live, gateway.phase == .online, serverCapabilities.contains("plugin-rpc-v1") else { return }
        let server = serverKey
        guard let reply = try? await gateway.call("plugin.shion.reviews.list", ["profile": .string(botId)]),
              server == serverKey, live
        else { return }
        skillReviews[botId] = (reply["reviews"]?.array ?? []).compactMap(SkillReview.init)
    }

    func loadAllSkillReviews() async {
        for bot in bots {
            await loadSkillReviews(bot.id)
        }
    }

    func skillReview(_ id: String) -> SkillReview? {
        for reviews in skillReviews.values {
            if let found = reviews.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// The ones not decided yet, of the assistants in the sidebar, newest first: 待你处理 has them.
    var pendingSkillReviews: [SkillReview] {
        bots.flatMap { skillReviews[$0.id] ?? [] }
            .filter { $0.status == .pending }
            .sorted { $0.at > $1.at }
    }

    /// An assistant's cards in its chat, each at the time the skill was written. The plugin keeps
    /// that time to the second, so a card goes after whatever else that second holds: a skill
    /// written within a second of the message that led to it is not shown before the message.
    func skillCards(_ botId: String) -> [ChatItem] {
        (skillReviews[botId] ?? []).map { review in
            ChatItem(id: "skill-\(review.id)", role: .card, at: review.at.addingTimeInterval(0.999),
                     event: .skill(review.id))
        }
    }

    /// Your decision on a card. 批准 writes it down; 拒绝 has Hermes take the change back, which
    /// it refuses when the skill has changed since. Returns why it did not go through, in the
    /// plugin's words.
    func decide(_ review: SkillReview, _ decision: SkillReview.Status) async -> String? {
        guard !readOnly else { return "没有连上服务器" }
        do {
            let reply = try await gateway.call("plugin.shion.reviews.decide", [
                "profile": .string(review.profile), "id": .string(review.id),
                "decision": .string(decision.rawValue),
                "entries": .array(review.entries.map { .string($0) }),
            ], timeout: 120, keepRefusal: true)
            await loadSkillReviews(review.profile)
            return reply["refusal"].map { PluginRefusal.words($0) }
        } catch {
            return error.localizedDescription
        }
    }

    /// Opens the card's own session, to talk the skill over with the assistant (SkillReviewTalk).
    func openReview(_ review: SkillReview) {
        guard !readOnly else { return }
        let talk = SkillReviewTalk(review: review)
        reviewing = talk
        Task { await talk.open(in: self) }
    }

    func bindReview(_ review: SkillReview, to sessionId: String) async throws {
        let reply = try await gateway.call("plugin.shion.reviews.bind", [
            "profile": .string(review.profile), "id": .string(review.id), "review_session": .string(sessionId),
        ], keepRefusal: true)
        if let refusal = reply["refusal"] {
            throw ControlError.refused(PluginRefusal.words(refusal), detail: nil)
        }
        await loadSkillReviews(review.profile)
    }

    /// What the assistant reviews the skill with (SkillReviewMaterial): the chat before the write,
    /// the change, and the skill as it is.
    func reviewMaterial(_ review: SkillReview) async throws -> String {
        let reply = try await gateway.call("plugin.shion.reviews.detail", [
            "profile": .string(review.profile), "id": .string(review.id),
        ], keepRefusal: true)
        if let refusal = reply["refusal"] {
            throw ControlError.refused(PluginRefusal.words(refusal), detail: nil)
        }
        let detail = reply["review"]
        let files = (detail?["files"]?.array ?? []).compactMap { file -> SkillReviewMaterial.File? in
            file["path"]?.string.map { SkillReviewMaterial.File(path: $0, diff: file["diff"]?.string ?? "") }
        }
        return SkillReviewMaterial.prompt(
            skill: review.skill, kind: review.kind, assistant: bot(review.profile)?.name ?? review.profile,
            talk: await talkBefore(review), files: files, document: detail?["document"]?["text"]?.string,
            complete: detail?["available"]?.bool ?? false)
    }

    /// The last things said in the assistant's Bot Chat before the skill was written: your words
    /// and its own, oldest first, read back a page at a time until there are enough. Not tool
    /// calls, nor the turns Hermes started itself, nor a marker for nothing to say.
    private func talkBefore(_ review: SkillReview) async -> [(mine: Bool, words: String)] {
        guard pagesTranscripts, let sessionId = sessions[review.profile] else { return [] }
        let written = review.at.timeIntervalSince1970
        var found: [(mine: Bool, words: String)] = []
        var cursor: String?
        pages: for _ in 0..<8 {
            guard let page = try? await transcriptPage(review.profile, sessionId, limit: 100, cursor: cursor) else { break }
            for row in (page["rows"]?.array ?? []).reversed() {
                guard row["row_kind"]?.string != "compaction", let role = row["role"]?.string,
                      role == "user" || role == "assistant", (row["timestamp"]?.number ?? .infinity) <= written
                else { continue }
                let kind = row["display_kind"]?.string ?? ""
                let words = text(of: row).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty, kind != "hidden", kind != "failed_turn", !Notices.machineKinds.contains(kind),
                      !words.hasPrefix("［专注检查］"), !Silence.isMarker(words)
                else { continue }
                found.append((role == "user", words))
                if found.count == SkillReviewMaterial.talkLimit { break pages }
            }
            guard let next = page["next_cursor"]?.string else { break }
            cursor = next
        }
        return found.reversed()
    }
}
