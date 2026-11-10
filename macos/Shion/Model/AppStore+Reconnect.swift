import Foundation

/// Losing the connection and getting it back (a lid closed, another Wi-Fi). Hermes goes on without
/// Shion: a turn keeps running, an approval keeps waiting, and the session keeps its last 512 frames.
/// Shion comes back and picks up from there:
/// - what each attached Bot Chat missed is replayed from its cursor (Gateway+Replay.swift), so a reply
///   under way goes on in its bubble and one that ended meanwhile shows how it ended; when the frames
///   cannot be had, the chat's newest page stands in, and no bubble is left still replying;
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
            guard await submit(text, id: sentence.id, to: botId, sessionId: sessionId) else {
                chats[botId]?.removeAll { $0.id == sentence.id }
                return QuickAsk.shared.putBack(sentences)
            }
            sentences.removeFirst()
        }
    }

    // MARK: sending, and its receipt

    /// A new message in the chat, out at once. The item's id is its submission id: the turn's end
    /// says which row it was stored as, and sending it again can never make it twice.
    func say(_ text: String, to botId: String, sessionId: String) {
        let id = UUID().uuidString
        let written = Date()
        // as the transcript will show it: words a retry sends again can start with their files' `@file:` lines
        chats[botId, default: []].append(Self.userItem(id: id, at: written, text: text))
        Task {
            if await !submit(text, id: id, to: botId, sessionId: sessionId) {
                requeue(id, text: text, at: written, to: botId)
            }
        }
    }

    /// `prompt.submit` for a message already in the chat, under its item's id: Hermes admits a
    /// submission id once, and an exact retry gets the same admission back. The receipt says Hermes
    /// has it; a refusal that it does not (没发出去, with 重发); no answer, the connection having gone,
    /// leaves it unsure until the server can say (`comeBack`). False when it did not go out at all:
    /// no connection by the time it could.
    @discardableResult
    func submit(_ text: String, id: String, to botId: String, sessionId: String) async -> Bool {
        deliveries.track(id, botId: botId, text: text, at: Date())
        await waitForChat(botId)
        guard gateway.phase == .online, sessions[botId] == sessionId else {
            deliveries.untrack(id)
            return false
        }
        do {
            try await gateway.call("prompt.submit", [
                "profile": .string(botId),
                "session_id": .string(sessionId),
                "text": .string(text),
                "submission_id": .string(id),
            ])
            deliveries.arrived(id)
        } catch GatewayError.rpc(_, let message, let reason) {
            deliveries.set(id, .unsent(DeliveryCheck.refusal(reason) ?? reason ?? message))
        } catch {
            deliveries.set(id, .unsure)
        }
        return true
    }

    /// Hermes takes a prompt, or an answer to an approval, only on a connection that has the session
    /// attached: on a new socket they wait until the chat is attached again (`comeBack`), half a
    /// minute at most.
    func waitForChat(_ botId: String) async {
        let deadline = Date().addingTimeInterval(30)
        while gateway.phase == .online, let sessionId = sessions[botId], !gateway.attached.contains(sessionId),
              Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// It did not go out after all: it waits again, as written.
    private func requeue(_ id: String, text: String, at: Date, to botId: String) {
        chats[botId]?.removeAll { $0.id == id }
        QuickAsk.shared.putBack([QuickAskWaiting(id: id, text: text, at: at, botId: botId)])
    }

    /// 重发: the same words under the same submission id, so that, should Hermes have them after
    /// all, it answers with that admission and runs nothing twice. The message moves to the bottom,
    /// after what Hermes has, as Hermes puts it.
    func resend(_ id: String, in botId: String) {
        guard let sent = deliveries.sent[id], sent.state.unsent, canResend(botId), let sessionId = sessions[botId]
        else { return }
        let written = Date()
        chats[botId]?.removeAll { $0.id == id }
        chats[botId, default: []].append(Self.userItem(id: id, at: written, text: sent.text))
        Task {
            if await !submit(sent.text, id: id, to: botId, sessionId: sessionId) {
                requeue(id, text: sent.text, at: written, to: botId)
            }
        }
    }

    /// 重发 can go now: connected, and the chat attached on this socket.
    func canResend(_ botId: String) -> Bool {
        guard live, gateway.phase == .online, !readOnly, let sessionId = sessions[botId] else { return false }
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
    /// still under way keeps its bubble, with an ellipsis where the lost part was.
    func rejoin(_ botId: String, _ sessionId: String) async {
        var caughtUp = false
        if serverCapabilities.contains("event-replay-v1") && serverCapabilities.contains("session-transcript-v1") {
            caughtUp = await gateway.replay(sessionId, profile: botId)
        }
        guard sessions[botId] == sessionId,
              let snapshot = try? await gateway.call("session.resume", resumeParams(botId, sessionId)),
              sessions[botId] == sessionId
        else { return }
        let reply = streaming[botId]
        // the session's run, revision, busy state and asks, as on any attach
        attach(botId, snapshot: snapshot)
        settleAsks(sessionId, snapshot: snapshot)
        let running = snapshot["running"]?.bool == true
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
    /// ordinary message again), or 没发出去 with 重发 (DeliveryCheck).
    private func reconcile(_ botId: String, caughtUp: Bool, snapshot: JSONValue) {
        let doubtful = deliveries.unsure(in: botId)
        guard !doubtful.isEmpty else { return }
        let pending = DeliveryCheck.pending(in: snapshot)
        let rows = (chats[botId] ?? []).filter { $0.role == .user && deliveries.state($0.id) == nil }
            .map { StoredUserRow(text: $0.text, at: $0.at) }
        for (id, sent) in doubtful {
            // as a row shows it: a file's `@file:` line is not among its words
            let row = Self.userItem(id: id, at: sent.at, text: sent.text)
            if DeliveryCheck.arrived(id: id, text: row.text, at: sent.at, seen: deliveries.seen, caughtUp: caughtUp,
                                     pending: pending, rows: rows) {
                deliveries.arrived(id)
            } else {
                deliveries.set(id, .unsent(nil))
                // a page read in its place: it goes back at the bottom
                if chats[botId]?.contains(where: { $0.id == id }) != true {
                    chats[botId, default: []].append(row)
                }
            }
        }
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
        guard Self.reconnectDemo else { return }
        let demo = DemoData(now: demoClock)
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
