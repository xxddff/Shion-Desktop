import Foundation

/// Losing the connection and getting it back (a lid closed, another Wi-Fi). Hermes goes on without
/// Shion: a turn keeps running, an approval keeps waiting, and the session keeps its last 512 frames.
/// Shion comes back and picks up from there:
/// - what each attached Bot Chat missed is replayed from its cursor (Gateway+Replay.swift), so a reply
///   under way goes on in its bubble and one that ended meanwhile shows how it ended; when the frames
///   cannot be had, the chat's newest page stands in, and no bubble is left still replying;
/// - a chat Hermes will not attach again keeps what it shows, says so over its composer with
///   再试一次, and is tried again by itself a few times (`notRejoined`, Rejoin.swift);
/// - what went out just before the connection went is checked: Hermes has it, or it shows 没发出去
///   with 重发, which sends it again under the same submission id (Delivery.swift);
/// - what you said while not connected waited under the chat, with the ⌥Space window's sentences
///   (QuickAsk.swift), and goes out in order, saying when it was written when that was long ago.
/// The sidebar says 重新连接中… and when the next try is (Gateway.nextRetry); waking from sleep or a
/// change of network tries at once (ConnectionWatch.swift).
extension AppStore {
    // MARK: saying something while not connected

    /// What is said in this chat now waits for a connection: there is none, since it went or since
    /// Shion has not connected yet and shows the last data. Ticking a todo, answering an approval and
    /// the like stay read-only meanwhile (AppStore+LastData.swift).
    func waits(_ botId: String) -> Bool {
        if lastData.shown { return bot(botId) != nil }
        return live && gateway.phase != .online
    }

    /// What waited in this chat, once connected (QuickAsk.sendWaiting): out in order, a message each,
    /// saying when it was written when that was more than five minutes before (QuickAskWaiting).
    /// Hermes queues a message sent while a turn runs behind it: a canonical prompt.submit never cuts
    /// the turn short. What cannot go out (the connection went again) waits again.
    func sendWaiting(_ sentences: [QuickAskWaiting], to botId: String) async {
        var sentences = sentences
        guard bot(botId) != nil else { return }
        if live, gateway.phase == .online, sessions[botId] == nil {
            await openChat(botId)
        }
        guard live, gateway.phase == .online, let sessionId = sessions[botId] else {
            return QuickAsk.shared.putBack(sentences)
        }
        while let sentence = sentences.first {
            let text = sentence.line(sentAt: Date())
            chats[botId, default: []].append(Self.userItem(id: sentence.id, at: Date(), text: text))
            // followed as it is said, with what else in the chat reads the same now (`say`)
            follow(sentence.id, botId: botId, text: text, at: Date())
            guard await submit(text, id: sentence.id, to: botId, sessionId: sessionId) else {
                chats[botId]?.removeAll { $0.id == sentence.id }
                return QuickAsk.shared.putBack(sentences)
            }
            sentences.removeFirst()
        }
    }

    // MARK: sending, and its receipt

    /// A new message in the chat, out at once. The item's id is its submission id: the turn's end
    /// says which row it was stored as, and sending it again can never make it twice. `mode` is
    /// how it reaches an assistant in the middle of a turn (AppStore.send: a composer's choice,
    /// else behind the turn).
    func say(_ text: String, to botId: String, sessionId: String, mode: BusyMode = .queue) {
        let id = UUID().uuidString
        let written = Date()
        // settled as it is sent: the way, and the turn running now. By the time it can go (the
        // chat may have to be attached again first) another turn may be, and that one is not its
        let sending = settled(mode, to: botId, sessionId: sessionId)
        // as the transcript will show it: words a retry sends again can start with their files' `@file:` lines
        chats[botId, default: []].append(Self.userItem(id: id, at: written, text: text))
        // followed from this moment, with what else in the chat reads the same now: it may wait
        // for the chat to be attached again before it goes, and the chat be read again meanwhile
        // (loadLatestPage), which must not take it for an older message in the same words
        follow(id, botId: botId, text: text, at: written)
        Task {
            if await !submit(text, id: id, to: botId, sessionId: sessionId, sending: sending) {
                requeue(id, text: text, at: written, to: botId)
            }
        }
    }

    /// `prompt.submit` for a message already in the chat, under its item's id: Hermes admits a
    /// submission id once, and an exact retry gets the same admission back. The receipt says Hermes
    /// has it; a refusal that it does not (没发出去, with 重发); no answer, the connection having gone,
    /// leaves it unsure until the server can say (`comeBack`). False when it did not go out at all:
    /// no connection by the time it could. While the assistant is still in the turn it was sent
    /// for, `sending` may put it into that turn instead (AppStore+Compose.swift). What else in the
    /// chat read the same when it was said stays on its record (Deliveries.track).
    @discardableResult
    func submit(_ text: String, id: String, to botId: String, sessionId: String, sending: Sending = .queued) async -> Bool {
        deliveries.track(id, botId: botId, text: text, at: Date())
        await waitForChat(botId)
        guard gateway.phase == .online, sessions[botId] == sessionId else {
            deliveries.untrack(id)
            return false
        }
        do {
            try await deliver([
                "profile": .string(botId),
                "session_id": .string(sessionId),
                "text": .string(text),
                "submission_id": .string(id),
            ], id: id, to: botId, sessionId: sessionId, sending: sending)
            deliveries.arrived(id)
        } catch {
            noteUndelivered(id, error)
        }
        return true
    }

    /// Hermes takes a prompt, or an answer to an approval, only on a connection that has the session
    /// attached: on a new socket they wait until the chat is attached again (`comeBack`), half a
    /// minute at most. Not once Hermes refused to attach it and it is not tried again (`rejoin`):
    /// nothing is coming to wait for. What goes then is refused, and says so under it.
    func waitForChat(_ botId: String) async {
        let deadline = Date().addingTimeInterval(30)
        while gateway.phase == .online, let sessionId = sessions[botId], !gateway.attached.contains(sessionId),
              unattached[botId].map({ $0.trying || $0.next != nil }) ?? true, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// It did not go out after all: it waits again, as written.
    private func requeue(_ id: String, text: String, at: Date, to botId: String) {
        chats[botId]?.removeAll { $0.id == id }
        QuickAsk.shared.putBack([QuickAskWaiting(id: id, text: text, at: at, botId: botId)])
    }

    /// 重发: the same words under the same submission id, so that, should Hermes have them after
    /// all, it answers with that admission and runs nothing twice; its pictures and files by the
    /// same references (a picture the server cleared meanwhile goes up again, under a new id:
    /// AppStore+Media.swift). The message moves to the bottom, after what Hermes has, as Hermes
    /// puts it. 再发一次, under a message a running turn did not take (Delivery.declined), is the
    /// same call: a message of its own, behind the turn. That one was never a submission, so
    /// Hermes cannot tell it from the first: it is for you to press, never done by itself.
    func resend(_ id: String, in botId: String) {
        guard let sent = deliveries.sent[id], sent.state.resendable, canResend(botId), let sessionId = sessions[botId]
        else { return }
        let written = Date()
        let media = chats[botId]?.first(where: { $0.id == id })?.media ?? sent.drafts.map(\.media)
        chats[botId]?.removeAll { $0.id == id }
        var item = Self.userItem(id: id, at: written, text: sent.text)
        item.media = media
        chats[botId, default: []].append(item)
        // said again now: what else reads the same is what the chat has at this moment
        followAgain(id, in: botId)
        Task {
            if !sent.drafts.isEmpty {
                await submit(sent.text, sent.drafts, botId: botId, sessionId: sessionId, submission: id, again: false)
            } else if await !submit(sent.text, id: id, to: botId, sessionId: sessionId) {
                requeue(id, text: sent.text, at: written, to: botId)
            }
        }
    }

    /// 重发 can go now: connected, and the chat attached on this socket. Whether Hermes refused to
    /// attach it is asked too, so that the button comes on as it is attached after all (`rejoin`):
    /// what the socket has attached is not watched.
    func canResend(_ botId: String) -> Bool {
        guard live, gateway.phase == .online, !readOnly, let sessionId = sessions[botId], unattached[botId] == nil
        else { return false }
        return gateway.attached.contains(sessionId)
    }

    // MARK: every frame

    /// Every frame, live or replayed (Gateway.onFrame), before the chat takes it: the submissions it
    /// says Hermes has; a session whose frames stopped coming on this socket (`session.replay_gap`:
    /// Hermes ended a subscription that fell behind) catches up and is attached again; and once a
    /// turn is over, no bubble is left still replying.
    func noteDelivery(_ frame: JSONValue) {
        for id in DeliveryCheck.submissions(in: frame) {
            deliveries.arrived(id)
        }
        guard let sessionId = frame["session_id"]?.string, let botId = sessionBots[sessionId] else { return }
        switch frame["type"]?.string {
        case "message.complete":
            // after the chat has taken the frame
            Task { endStrayReplies(botId) }
        case "session.replay_gap":
            guard gateway.phase == .online, gateway.attached.contains(sessionId) else { break }
            gateway.attached.remove(sessionId)
            Task { await rejoin(botId, sessionId) }
        default:
            break
        }
    }

    /// A bubble still marked replying that is not the reply under way: a frame lost on the way left
    /// it. It keeps what it has, or goes when it has nothing.
    private func endStrayReplies(_ botId: String) {
        guard let items = chats[botId] else { return }
        for index in items.indices.reversed() where items[index].streaming && items[index].id != streaming[botId] {
            if items[index].text.isEmpty {
                chats[botId]?.remove(at: index)
            } else {
                chats[botId]?[index].streaming = false
            }
        }
    }

    // MARK: coming back

    /// The connection came back (Gateway.onReconnect). Each attached Bot Chat in turn, the one on
    /// screen first, then 总秘书's: what it missed comes in and it is attached again (`rejoin`), and
    /// what went out as the connection went is checked. What waited goes out as each chat is
    /// attached again (QuickAsk.sendWaiting, `waitForChat`).
    func comeBack() async {
        let socket = gateway.connection
        // a new socket: every chat is attached afresh, whatever the last one could not attach
        unattached = [:]
        let order = sessions.keys.sorted { rank($0) == rank($1) ? $0 < $1 : rank($0) < rank($1) }
        for botId in order {
            guard gateway.connection == socket, live, gateway.phase == .online else { return }
            if let sessionId = sessions[botId] {
                await rejoin(botId, sessionId)
            }
        }
        guard gateway.connection == socket, live, gateway.phase == .online else { return }
        // the plugin's pushes are not replayed: catch up on what changed while away
        await syncPluginData()
        await loadAllSkillReviews()
        // the 总秘书 chosen on this Mac, where the plugin's setting differs (LocalData.swift)
        await local.syncChief()
    }

    private func rank(_ botId: String) -> Int {
        if route == .chat(botId) { return 0 }
        return botId == chiefId ? 1 : 2
    }

    /// One Bot Chat on a socket that has not attached it: the frames it missed, then attached again
    /// (`session.resume`, which first sends what came between the two). A reply under way goes on
    /// in its bubble. When the frames cannot be had (a server without replay, or one that no longer
    /// keeps them), the newest page stands in for them: a reply that ended meanwhile is on it, one
    /// still under way keeps its bubble, with an ellipsis where the lost part was. Refused, the chat
    /// says so and is tried again (`notRejoined`), one try at a time: `tries` is how many in a row
    /// were refused before this one; 再试一次 (ChatComposer) starts over.
    func rejoin(_ botId: String, _ sessionId: String, tries: Int = 0) async {
        guard unattached[botId]?.trying != true else { return }
        unattached[botId]?.trying = true
        var caughtUp = false
        if serverCapabilities.contains("event-replay-v1") && serverCapabilities.contains("session-transcript-v1") {
            caughtUp = await gateway.replay(sessionId, profile: botId)
        }
        guard sessions[botId] == sessionId else { return }
        let snapshot: JSONValue
        do {
            snapshot = try await resumed(botId, sessionId)
        } catch {
            return notRejoined(botId, sessionId, error, refused: tries + 1)
        }
        guard sessions[botId] == sessionId else { return }
        unattached[botId] = nil
        let reply = streaming[botId]
        // the session's run, revision, busy state and asks, as on any attach
        attach(botId, snapshot: snapshot)
        settleAsks(sessionId, snapshot: snapshot)
        // by a frame taken since the snapshot was read, where one said (AppStore.runs)
        let running = runs(snapshot)
        if caughtUp {
            // the rows held are whole: no page to read
            attachMarks[botId] = nil
            if running, let reply, chats[botId]?.contains(where: { $0.id == reply && $0.streaming }) == true {
                streaming[botId] = reply
            }
        } else {
            keepReply(botId, reply, running: running)
            if loadedChats.contains(botId) {
                try? await loadLatestPage(botId)
            } else {
                attachMarks[botId] = nil
            }
        }
        reconcile(botId, caughtUp: caughtUp, snapshot: snapshot)
        await settleCorrections(botId, sessionId)
    }

    /// Hermes would not attach the chat again (`rejoin`, refused `refused` times in a row). The chat
    /// keeps what it shows (its rows, a reply that was arriving, what you said and where that
    /// stands) and says so over the composer, with 再试一次 (`rejoinNote`). The session's frames do
    /// not come as they are published meanwhile, so a turn is no longer shown as running on the
    /// word of the ones before: the session's own word comes with the attach. It is tried again by
    /// itself after a moment, a few times (Rejoin), unless trying again would change nothing. Not
    /// when the socket itself went: the next one attaches every chat again (`comeBack`).
    func notRejoined(_ botId: String, _ sessionId: String, _ error: Error, refused: Int) {
        guard gateway.phase == .online, sessions[botId] == sessionId else { return }
        let delay = Rejoin.delay(after: refused, error)
        let next = delay.map { Date().addingTimeInterval($0) }
        unattached[botId] = Rejoin.Refused(why: Rejoin.words(error), next: next)
        setRunning(botId, false)
        setReplying(botId, false)
        guard let delay else { return }
        let socket = gateway.connection
        Task {
            try? await Task.sleep(for: .seconds(delay))
            // tried meanwhile (再试一次), attached, let go of, or another socket: not this try's to make
            guard gateway.connection == socket, gateway.phase == .online, sessions[botId] == sessionId,
                  let waiting = unattached[botId], waiting.next == next, !waiting.trying
            else { return }
            await rejoin(botId, sessionId, tries: refused)
        }
    }

    /// What is said over the composer of a chat this socket could not attach again (`rejoin`): what
    /// failed and why, and when it is tried again by itself.
    func rejoinNote(_ botId: String) -> String? {
        guard live, gateway.phase == .online, let refused = unattached[botId] else { return nil }
        return Rejoin.line("这个对话", refused.why, next: refused.next)
    }

    /// No replay: what came while away is not in the chat until the page is read. A reply still
    /// under way keeps its bubble and what it had, and goes on in it; the page takes the place of
    /// what is above it. One that ended goes: the page has it whole.
    private func keepReply(_ botId: String, _ reply: String?, running: Bool) {
        guard let reply, let index = chats[botId]?.firstIndex(where: { $0.id == reply }) else { return }
        if running {
            if chats[botId]?[index].text.isEmpty == false {
                chats[botId]?[index].text += "\n\n…\n\n"
            }
            streaming[botId] = reply
            attachMarks[botId] = index
        } else {
            chats[botId]?.remove(at: index)
            attachMarks[botId] = min(attachMarks[botId] ?? 0, chats[botId]?.count ?? 0)
        }
    }

    /// The approvals and questions still waiting are the snapshot's: any other of this session's was
    /// answered or withdrawn while away.
    private func settleAsks(_ sessionId: String, snapshot: JSONValue) {
        let open = Set((snapshot["prompts"]?.array ?? []).compactMap { $0["prompt_id"]?.string })
        for ask in asks where ask.remote?.sessionId == sessionId && !open.contains(ask.id) {
            Notifier.shared.withdraw(ask.id)
        }
        asks.removeAll { $0.remote?.sessionId == sessionId && !open.contains($0.id) }
    }

    /// What went out just before the connection went, now that the server can say: there (an
    /// ordinary message again), or 没发出去 with 重发 (DeliveryCheck). What was put into a running
    /// turn then has no receipt to go by: `settleCorrections`.
    private func reconcile(_ botId: String, caughtUp: Bool, snapshot: JSONValue) {
        let doubtful = deliveries.unsure(in: botId)
        guard !doubtful.isEmpty else { return }
        let pending = DeliveryCheck.pending(in: snapshot)
        // a row known to name a submission is that prompt's (one that named this message was
        // taken for it as the page was read: `onPage`), so it is not what says this one arrived
        let named = sessions[botId].flatMap { control.namedRows[$0] } ?? []
        let rows = (chats[botId] ?? []).filter { $0.role == .user && deliveries.state($0.id) == nil }
            .filter { !(DeliveryCheck.row(of: $0.id).map(named.contains) ?? false) }
            .map { StoredUserRow(text: $0.text, at: $0.at) }
        for (id, sent) in doubtful {
            // as a row shows it: a file's `@file:` line is not among its words
            let row = Self.userItem(id: id, at: sent.at, text: sent.text)
            if DeliveryCheck.arrived(id: id, text: row.text, at: sent.at, seen: deliveries.seen, caughtUp: caughtUp,
                                     pending: pending, rows: rows) {
                deliveries.arrived(id)
            } else {
                deliveries.set(id, .unsent(nil))
                // a page read in its place: it goes back at the bottom, with what went with it
                if chats[botId]?.contains(where: { $0.id == id }) != true {
                    var back = row
                    back.media += sent.drafts.map(\.media)
                    chats[botId, default: []].append(back)
                }
            }
        }
    }

    /// What was put into a running turn as the connection went (引导, 打断), now that the server
    /// can be asked. No receipt names such a message, so only the transcript can say it got
    /// there: the newest page is read for a row of yours in the same words that is not a message
    /// the chat had before it was sent (DeliveryCheck.stored). The rows the chat holds cannot say:
    /// with the frames replayed they are the ones from before, where the same words can only be
    /// an earlier message. Found, it is an ordinary message again: the page's row where the chat
    /// was read again, else the item itself, marked as part of that turn. Not found (or the page
    /// could not be read), it stays as it is, in doubt, and is never sent again by itself. A row
    /// that confirmed one message is that message's for as long as the session is the chat's
    /// (ChatControl.confirmedRows): at the next look it does not confirm another in the same
    /// words, which was not there to be found the first time. Rows that are other messages' are
    /// known by their time and words too (StoredUserRow.Identity), not only by their numbers:
    /// compacted, the session has the messages it kept under new numbers, and an older 「继续」
    /// under its new one was taken for one just said that never got there. The other messages in
    /// its words are asked what became of them at each look (AppStore.others): one that was on
    /// its way when this was said and was then refused is on no row, so it no longer keeps this
    /// one in doubt; one said after this, and stored, has a row that is not this one's; a prompt
    /// is known by the row that names it once a page has shown it (transcriptPage), its turn's
    /// end seen or not.
    private func settleCorrections(_ botId: String, _ sessionId: String) async {
        let unconfirmed = deliveries.unconfirmed(in: botId)
        guard !unconfirmed.isEmpty else { return }
        var page: [StoredUserRow] = []
        if pagesTranscripts, let read = try? await transcriptPage(botId, sessionId, limit: Self.pageSize) {
            // a row that names a submission is a prompt's, not what was put into a turn
            let named = Set(DeliveryCheck.named(in: read).values)
            page = transcriptItems(read).filter { $0.role == .user }
                .map { StoredUserRow(text: $0.text, at: $0.at, row: DeliveryCheck.row(of: $0.id)) }
                .filter { !($0.row.map(named.contains) ?? false) }
        }
        guard sessions[botId] == sessionId else { return }
        var taken = control.confirmedRows[sessionId] ?? []
        for (id, sent) in unconfirmed where deliveries.state(id) == .unconfirmed {
            // as a row shows it: a file's `@file:` line is not among its words
            let item = Self.userItem(id: id, at: sent.at, text: sent.text)
            // the other messages in its words, as each stands now (AppStore.others)
            guard let stored = DeliveryCheck.stored(item.text, others: others(of: id, in: botId, taken: taken), page: page) else {
                // a page read in its place: it goes back at the bottom, still in doubt
                if chats[botId]?.contains(where: { $0.id == id }) != true {
                    chats[botId, default: []].append(item)
                }
                continue
            }
            deliveries.arrived(id)
            taken.insert(stored.identity)
            control.confirmedRows[sessionId, default: []].insert(stored.identity)
            guard let row = stored.row else { continue }
            // its row is known from here on, to the messages that counted it among theirs too
            control.storedRows[id] = row
            if chats[botId]?.contains(where: { $0.id == "row-\(row)" }) == true {
                // the chat was read again and has the row: this is the same message
                chats[botId]?.removeAll { $0.id == id }
            } else if let index = chats[botId]?.firstIndex(where: { $0.id == id }) {
                chats[botId]?[index].midTurn = true
            }
        }
    }

    /// The messages of yours in `held` that Hermes has not said it has, when a page is read in the
    /// chat's place (loadLatestPage): true where a row of the page is that message, so the page's
    /// copy stands for it; false where none can be, so its bubble stays under the page with what
    /// it says about getting there. A row that names the submission is it (Hermes keeps a
    /// prompt's `submission_id` on its row), and Hermes has it; such a row is known as its
    /// prompt's from the moment the page was read (transcriptPage), the prompt followed here or
    /// not. Without one, a row of yours in the same words that is no other message's
    /// (DeliveryCheck.stored, with the others in those words as each stands now: `others`, as
    /// `settleCorrections` looks): never a row that was there before, nor one of a message said
    /// since, which read the same and are other messages. One Hermes refused, or a turn did not
    /// take, is on no row.
    func onPage(_ held: [ChatItem], page: JSONValue, rows: [ChatItem], botId: String) -> [String: Bool] {
        let named = DeliveryCheck.named(in: page)
        let prompts = Set(named.values)
        // a row that names a submission is that prompt, found by its name just below: it never
        // stands for another message because it reads the same
        let stored = rows.filter { $0.role == .user }
            .map { StoredUserRow(text: $0.text, at: $0.at, row: DeliveryCheck.row(of: $0.id)) }
            .filter { !($0.row.map(prompts.contains) ?? false) }
        var taken = sessions[botId].flatMap { control.confirmedRows[$0] } ?? []
        var there: [String: Bool] = [:]
        for item in held where item.role == .user {
            guard let sent = deliveries.sent[item.id] else { continue }
            if named[item.id] != nil {
                there[item.id] = true
                deliveries.arrived(item.id)
                continue
            }
            switch sent.state {
            case .unsent, .declined:
                there[item.id] = false
            case .sending, .unsure, .unconfirmed:
                let row = DeliveryCheck.stored(item.text, others: others(of: item.id, in: botId, taken: taken), page: stored)
                there[item.id] = row != nil
                if let row {
                    taken.insert(row.identity)
                }
            }
        }
        return there
    }

    // MARK: the sidebar

    /// The line under the server while a connection that had worked is down: 重新连接中…, and when
    /// it is tried again (or now, while it is).
    var reconnectNote: String? {
        if Self.reconnectDemo {
            return "重新连接中… · \(Self.retryClock.string(from: demoClock.addingTimeInterval(41))) 再试"
        }
        guard live, gateway.reconnecting else { return nil }
        guard gateway.phase != .connecting, let next = gateway.nextRetry else { return "重新连接中…" }
        return "重新连接中… · \(Self.retryClock.string(from: next)) 再试"
    }

    /// The dot beside the server: warm while a connection that had worked is being got back.
    var reconnecting: Bool {
        Self.reconnectDemo || (live && gateway.reconnecting)
    }

    private static let retryClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// The screenshot of a connection being got back (`-ShionReconnectDemo YES`), never outside them.
    private static var reconnectDemo: Bool {
        LaunchOptions.current.snapshot && UserDefaults.standard.bool(forKey: "ShionReconnectDemo")
    }

    // MARK: at launch

    /// Waking from sleep and network changes reconnect at once (never in screenshot runs); the
    /// screenshot of a connection being got back has 詩音's chat with a message that did not go out,
    /// one whose receipt the connection took with it, and two that wait.
    func startReconnect() {
        if !LaunchOptions.current.snapshot {
            ConnectionWatch.shared.start(gateway)
        }
        guard Self.reconnectDemo, let demo else { return }
        chats[chiefId, default: []] += demo.reconnectChat
        for item in demo.reconnectChat {
            deliveries.track(item.id, botId: chiefId, text: item.text, at: item.at)
            deliveries.set(item.id, item.id == demo.reconnectUnsent ? .unsent(nil) : .unsure)
        }
        for sentence in demo.reconnectWaiting {
            QuickAsk.shared.wait(sentence.text, for: chiefId, at: sentence.at)
        }
    }
}
