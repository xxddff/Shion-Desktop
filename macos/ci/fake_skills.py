"""Skills an assistant taught itself, for the CI stand-in (fake_hermes.py): what ComposeTests needs.

Shaped like Hermes main (2026-11-12) and the shion plugin's `reviews.*` (hermes-plugin/README.md,
技能审核):

- 「学一个技能（CI）」: the turn has nothing to say and answers `[SILENT]` (stored as it is: silence
  is the client's to keep off the screen, gateway/response_filters.py); the review after it says
  what it kept (`review.summary {text}`, gateway/run_turn_runner.py) and a skill card is filed for
  that profile, new. 「再改一下技能（CI）」 files a second card, a change to the same skill, and
  answers in words.
- `plugin.shion.reviews.list`, `.detail`, `.bind`, `.decide`, in the profiles that have the plugin
  (fake_profiles.py). `bind` keeps the first session; `decide` wants the card's own `entries`.
- `session.create` with `request_id` `shion-review-<card id>`: a session of its own. Asserted: no
  title (Hermes would look a titled session up first), no tools (`toolsets: []`, so the talk can
  change no skill and sets off no review of its own), `ignore_rules`. The first time a card asks,
  the session is not made: refused as Hermes answers any call whose store was busy (code 5001,
  `storage_unavailable`: gateway/session_controls.py, "clients retry"). Asked again, it is made.
- a prompt in that session is admitted as any is (fake_reconnect.py: once per submission id, an
  exact retry gets the same admission and no second turn) and answered: what the assistant was
  given to review with, with an opinion on the skill; anything said after, with 「审核回复（CI）：」
  and the words.

What can go wrong in that session, scripted by what is said in it (ComposeTests, step 7). The
sentences that start 「断线：」 work there as in a Bot Chat (fake_reconnect.py): 「断线：没收到」 is
dropped before it is admitted, 「断线：还没回执」 admitted and answered with its receipt lost. And:

- 「排队满了（CI）」: refused the first time, `queue_full`, four seconds after it came, as over a slow
  line (time to type the next sentence); taken when it comes again under the same submission id.
  Under another id it is refused for good, which is what sending it again as a new message would
  deserve: Hermes would have run it twice had the first got through.
- 「审核出错（CI）」: its turn fails as 「出个错看看」 does in a Bot Chat (fake_control.py): status
  error, the failure's row closing it. Asked again once that turn was taken back
  (`session.mutate` rewind, fake_control.py), it is answered, 「（重试）」 first.
- 「订阅断了（CI）」: a reply in eight parts; at the third this socket's subscription to the session is
  retired and it gets `session.replay_gap` instead, the socket kept (fake_reconnect.py retire):
  the rest reaches only who attaches again.
- 「快照迟到（CI）」: the same loss after the first part, and then every `session.resume` of the
  session is answered as Hermes answers one while frames keep coming (gateway/
  session_authority.py attach): the session is read and this socket joined to its frames at
  once, and the answer is written a moment later, behind what was published meanwhile. Behind
  each of the first three snapshots that is a part of the reply and the pending list again
  (`session.info`); behind the fourth, the last part and the turn's end (`message.complete`,
  `session.info`). So each snapshot says a turn runs and has no row of the reply, and each is
  older than a frame its socket already got. Four are as many as Shion asks for before it goes
  by the one it has (one, and SessionWords.rereads more); should it ask for fewer, the turn ends
  after a while by itself, in words that say so.
"""
import datetime
import itertools
import threading
import time

import fake_control
import fake_profiles
import fake_reconnect
import fake_words

LEARN = "学一个技能（CI）"
CHANGE = "再改一下技能（CI）"
SUMMARY = "💾 学会了技能 ci-notes；记下了：你喜欢简短的回答（CI）"
OPINION = "审核意见（CI）：这个技能写得清楚，只在整理课堂录音时用得上，建议批准。"
SKILL = "# ci-notes\n整理课堂录音：先转文字，再按小节列要点。\n"
MATERIAL = "请和我一起审核"  # how what the assistant is given to review with starts (SkillReviewMaterial)
ANSWER = "审核回复（CI）："
REFUSED = "排队满了（CI）"
REFUSED_AFTER = 4.0  # seconds before its refusal goes out
FAILS = "审核出错（CI）"
LAGS = "订阅断了（CI）"
LAG_PARTS = 8
LAG_RETIRED_AT = 3
BEHIND = "快照迟到（CI）"
BEHIND_ASKS = 4  # snapshots Shion asks for before it goes by the one it has (EventCursors.swift: 1 + SessionWords.rereads)
BEHIND_WAIT = 15.0  # seconds the turn waits for them
BEHIND_UNASKED = "（没按剧本：快照只要了 {} 次）"

cards = {}  # card id -> the card, as reviews.list gives it
talks = {}  # request id -> the review session it made
unmade = set()  # the request ids whose session was refused once
refused = {}  # review session -> the submission id 「排队满了（CI）」 was refused under
behind = {}  # review session -> the turn of 「快照迟到（CI）」 under way: every snapshot of it is overtaken
row_ids = itertools.count(9000)
lock = threading.Lock()


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def handles_prompt(params):
    return params.get("text") in (LEARN, CHANGE) or str(params.get("session_id", "")).startswith("review-")


def refuse(conn, rid, code, words):
    conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {"code": 4001, "message": "plugin_rpc_failed", "data": {
        "reason": "plugin_rpc_failed", "detail": f"ShionError: {code}: {words}"}}})
    return True


def rpc(conn, log, transcripts, method, params, rid):
    """True when the call was one of these, and answered."""
    def reply(result):
        conn.send_json({"jsonrpc": "2.0", "id": rid, "result": result})
        return True

    if method.startswith("plugin.shion.reviews."):
        profile = params.get("profile")
        if not profile or not fake_profiles.has_plugin(profile, "shion"):
            return False  # no such method there, as for the rest of the plugin
        name = method.rsplit(".", 1)[-1]
        with lock:
            if name == "list":
                mine = [card for card in cards.values() if card["profile"] == profile]
                return reply({"reviews": list(reversed(mine)), "available": True})
            card = cards.get(params.get("id"))
            if card is None or card["profile"] != profile:
                return refuse(conn, rid, "not_found", f"no skill review {params.get('id')!r}")
            if name == "detail":
                before = None if card["kind"] == "created" else SKILL
                after = SKILL if card["kind"] == "created" else SKILL + "遇到听不清的地方标出来（CI）。\n"
                diff = "--- 变更前/ci-notes/SKILL.md\n+++ 变更后/ci-notes/SKILL.md\n@@\n+遇到听不清的地方标出来（CI）。"
                return reply({"review": {**card, "available": True,
                                         "files": [{"path": "ci-notes/SKILL.md", "before": before, "after": after, "diff": diff}],
                                         "document": {"path": "ci-notes/SKILL.md", "text": after}}})
            if name == "bind":
                if card["review_session"] not in (None, params.get("review_session")):
                    return refuse(conn, rid, "conflict", "这张卡已经有审核会话了")
                card["review_session"] = params.get("review_session")
                return reply({"review": card})
            if name == "decide":
                if params.get("entries") != card["entries"]:
                    return refuse(conn, rid, "conflict", "这个技能又有了新的变更，请重新看一遍")
                if card["status"] not in ("pending", params.get("decision")):
                    return refuse(conn, rid, "conflict", "这张卡已经处理过了")
                card["status"] = params.get("decision")
                card["decided_at"] = now()
                log(f"    skill review {card['id']}: {card['status']}")
                return reply({"review": card, "revision": 1})
        return False

    if method == "session.create" and str(params.get("request_id", "")).startswith("shion-review-"):
        assert "title" not in params, "a review session is made by its request id alone"
        assert params.get("toolsets") == [], "a review session has no tools"
        assert params.get("ignore_rules") is True and params.get("hidden") is True
        with lock:
            first = params["request_id"] not in unmade
            unmade.add(params["request_id"])
        if first:
            # the store was busy: nothing made, nothing kept under the request id
            log(f"    no review session for {params['request_id']} this time: storage_unavailable")
            conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {
                "code": 5001, "message": "storage_unavailable", "data": {"reason": "storage_unavailable"}}})
            return True
        with lock:
            session_id = talks.setdefault(params["request_id"], "review-" + params["request_id"][len("shion-review-"):])
        log(f"    a review session of its own: {session_id}")
        conn.subscribed.add(session_id)
        return reply(conn.snapshot(session_id, {}))

    if method == "session.resume":
        return overtaken(conn, log, params, rid)
    if method != "prompt.submit" or not handles_prompt(params):
        return False
    session_id, text = params.get("session_id"), params.get("text", "")
    if session_id.startswith("review-"):
        return talk(conn, log, transcripts, params, rid)
    reply({"status": "queued", "admission_id": f"adm-{rid}"})
    changed = text == CHANGE
    with lock:
        ident = "sr_ci2" if changed else "sr_ci1"
        cards[ident] = {"id": ident, "profile": params.get("profile"), "skill": "ci-notes", "session": session_id,
                        "kind": "updated" if changed else "created", "entries": ["0000000000c2" if changed else "0000000000c1"],
                        "status": "pending", "review_session": None, "at": now(), "decided_at": None}
    say(conn, transcripts, session_id, text, "改好了（CI）。" if changed else "[SILENT]")
    conn.event("review.summary", session_id, {"text": SUMMARY})
    return True


def talk(conn, log, transcripts, params, rid):
    """A prompt in a review's session. It got here attached and not seen before: fake_reconnect.py
    has answered a prompt on a socket that has not attached the session (permission_denied), an
    exact retry (the same admission, no second turn) and the 「断线：」 sentences."""
    session_id, text, submission = params.get("session_id"), params.get("text", ""), params.get("submission_id")

    def admitted():
        conn.send_json({"jsonrpc": "2.0", "id": rid, "result": fake_reconnect.receipt(params)})

    if text == REFUSED:
        with lock:
            first = refused.get(session_id)
            if first is None:
                refused[session_id] = submission
        if first is None:
            log(f"    {text!r} in {session_id}: refused in {REFUSED_AFTER:.0f} s (queue_full), under {submission}")
            threading.Timer(REFUSED_AFTER, conn.send_late, args=({"jsonrpc": "2.0", "id": rid, "error": {
                "code": 4001, "message": "queue_full", "data": {"reason": "queue_full"}}},)).start()
            return True
        if first != submission:
            # sent again as a new message: had the first got through, this would be a second turn
            log(f"    {text!r} in {session_id} came again under ANOTHER submission id ({submission}, first {first})")
            return refuse(conn, rid, "conflict", "sent again under another submission id")
        log(f"    {text!r} in {session_id} came again under the same submission id: taken")
    if text == LAGS:
        return lag(conn, log, params, rid)
    if text == BEHIND:
        return fall_behind(conn, log, params, rid)
    admitted()
    if text == FAILS and fake_words.sent(text) not in fake_control.rewound:
        threading.Thread(target=fail, args=(conn, log, transcripts, session_id, text, submission), daemon=True).start()
        return True
    if text.startswith(MATERIAL):
        answer = OPINION
    else:
        answer = ("（重试）" if fake_words.sent(text) in fake_control.rewound else "") + ANSWER + text
    say(conn, transcripts, session_id, text, answer, submission)
    return True


def keep(transcripts, session_id, role, words, **more):
    row_id = next(row_ids)
    with lock:
        transcripts.setdefault(session_id, []).append(
            {"row_id": row_id, "row_kind": "message", "role": role, "text": words, "timestamp": time.time(), **more})
    return row_id


def idle(conn, session_id):
    """As a turn's end says it (session_authority._publish_pending): not running, and the session's
    run and revision, which a rewind names."""
    current = fake_control.fence(session_id)
    conn.event("session.info", session_id, {
        "running": False, "execution_generation": current["generation"], "revision": current["revision"],
        "pending": [], "stored_session_id": session_id})


def say(conn, transcripts, session_id, prompt, answer, submission=None):
    """A turn and its two rows. A review's session names whose turn it was (`submission`), as
    Hermes's `persisted_turn` does."""
    asked = keep(transcripts, session_id, "user", fake_words.sent(prompt))
    answered = keep(transcripts, session_id, "assistant", answer)
    complete = {"text": answer, "status": "complete"}
    if submission is not None:
        complete["persisted_turn"] = {"row_ids": [asked, answered], "complete": True, "user_row_id": asked,
                                      "user_row_ids": [asked], "final_assistant_row_id": answered,
                                      "submission_id": submission}
    conn.event("message.start", session_id, {})
    conn.event("message.delta", session_id, {"text": answer[:4]})
    conn.event("message.delta", session_id, {"text": answer[4:]})
    conn.event("message.complete", session_id, complete)
    conn.event("session.info", session_id, {"running": False})


def fail(conn, log, transcripts, session_id, text, submission):
    """The turn ends as a provider's rate limit ends one (fake_control.py run_fail): nothing of a
    reply, `message.complete` with status error and Hermes's words about it, and the failure's row
    closing the turn in the transcript."""
    with lock:
        current = fake_control.fence(session_id)
        current["generation"] += 1
        generation = current["generation"]
    asked = keep(transcripts, session_id, "user", fake_words.sent(text))
    try:
        fake_reconnect.publish(session_id, "message.start", {}, generation)
        time.sleep(1)
        closing = keep(transcripts, session_id, "assistant", fake_control.FAILED_TURN_NOTICE, display_kind="failed_turn",
                       display_metadata={"error": fake_control.PROVIDER_SAID, "error_surface": fake_control.FAIL_SURFACE})
        with lock:
            fake_control.fence(session_id)["revision"] += 1
        said = f"{fake_control.FAIL_COPY}\n\n{fake_control.FAILED_TURN_NOTICE}"
        fake_reconnect.publish(session_id, "message.complete", {
            "text": said, "content": said, "outcome": "failed", "status": "error",
            "error_surface": fake_control.FAIL_SURFACE,
            "persisted_turn": {"row_ids": [asked, closing], "complete": False, "user_row_id": asked,
                               "user_row_ids": [asked], "submission_id": submission}}, generation)
        idle(conn, session_id)
        log(f"  -> the review's turn on {session_id} failed: rate limit (its message is row {asked})")
    except OSError:
        pass


def lag(conn, log, params, rid):
    """A reply in parts, with fake_reconnect.py's turns (its rows, run and pending list as any
    turn's): at one part this socket's subscription is retired, as a viewer that cannot keep up
    loses it, and the part reaches only the kept frames."""
    session_id, text = params.get("session_id"), fake_words.sent(params.get("text", ""))
    admission = fake_reconnect.admit(session_id, params.get("submission_id"), text, params.get("profile"))
    turn = {"what": "review lag", "session_id": session_id, "text": text, "admission": admission, "handler": conn,
            "said": "", "answered": threading.Event(), "choice": None, "meanwhile": threading.Event()}
    with fake_reconnect.bus:
        fake_reconnect.running[session_id] = turn
    fake_reconnect.publish_pending(session_id)
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": fake_reconnect.receipt_of(admission)})

    def run():
        fake_reconnect.begin(turn)
        for n in range(1, LAG_PARTS + 1):
            time.sleep(0.4)
            if n == LAG_RETIRED_AT:
                with fake_reconnect.bus:
                    fake_reconnect.watchers.get(session_id, {}).pop(conn, None)
            fake_reconnect.say(turn, f"第{n}节。")
            if n == LAG_RETIRED_AT:
                fake_reconnect.retire(conn, session_id)
        with fake_reconnect.bus:
            back = conn in fake_reconnect.watchers.get(session_id, {})
        log(f"  -> the review's reply on {session_id} ends; this socket "
            + ("attached the session again" if back else "DID NOT attach the session again"))
        fake_reconnect.end(turn)

    threading.Thread(target=run, daemon=True).start()
    return True


def fall_behind(conn, log, params, rid):
    """A reply whose frames overtake every snapshot asked for while it comes (fake_reconnect.py's
    turns, as `lag`): one part, then this socket's subscription is retired with the second, so the
    session is attached again; from there `overtaken` answers each `session.resume`."""
    session_id, text = params.get("session_id"), fake_words.sent(params.get("text", ""))
    admission = fake_reconnect.admit(session_id, params.get("submission_id"), text, params.get("profile"))
    turn = {"what": "review behind", "session_id": session_id, "text": text, "admission": admission, "handler": conn,
            "said": "", "answered": threading.Event(), "choice": None, "meanwhile": threading.Event(),
            "asked": 0, "over": threading.Event()}
    with fake_reconnect.bus:
        fake_reconnect.running[session_id] = turn
    fake_reconnect.publish_pending(session_id)
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": fake_reconnect.receipt_of(admission)})

    def run():
        fake_reconnect.begin(turn)
        time.sleep(0.4)
        fake_reconnect.say(turn, "第1段。")
        time.sleep(0.4)
        with lock:
            behind[session_id] = turn
        with fake_reconnect.bus:
            fake_reconnect.watchers.get(session_id, {}).pop(conn, None)
        fake_reconnect.say(turn, "第2段。")
        fake_reconnect.retire(conn, session_id)
        if turn["over"].wait(BEHIND_WAIT):
            return
        with lock:
            waiting = behind.pop(session_id, None) is not None
        if waiting:
            log(f"  -> NOT AS SCRIPTED: {session_id}'s snapshot was asked for {turn['asked']} time(s), not "
                f"{BEHIND_ASKS}; the turn ends by itself")
            fake_reconnect.say(turn, BEHIND_UNASKED.format(turn["asked"]))
            fake_reconnect.end(turn)

    threading.Thread(target=run, daemon=True).start()
    return True


def overtaken(conn, log, params, rid):
    """`session.resume` of a session whose turn is 「快照迟到（CI）」's: answered here, True; any other
    is not (False). The session is read and this socket joined to its frames first (`snapshot`),
    then more is published, and only then is the answer written: what Hermes's attach does when
    frames come between its snapshot and its reply. The fourth snapshot is overtaken by the
    turn's end."""
    session_id = params.get("session_id")
    with lock:
        turn = behind.get(session_id)
        if turn is None:
            return False
        turn["asked"] += 1
        asked = turn["asked"]
        if asked == BEHIND_ASKS:
            del behind[session_id]
    result = conn.snapshot(session_id, params)
    conn.subscribed.add(session_id)
    fake_reconnect.say(turn, f"第{asked + 2}段。")
    if asked == BEHIND_ASKS:
        fake_reconnect.end(turn)
        turn["over"].set()
    else:
        fake_reconnect.publish_pending(session_id, turn["generation"])
    log(f"    snapshot {asked} of {session_id} (seq {result['last_sequence']}, running {result['running']}, "
        f"{len(result.get('messages', []))} rows) answered behind "
        + ("the turn's end" if asked == BEHIND_ASKS else "a part and the pending list"))
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": result})
    return True
