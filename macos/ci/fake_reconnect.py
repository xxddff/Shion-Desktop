"""Dropped connections and coming back, for the CI stand-in (fake_hermes.py): what ReconnectTests needs.

Shaped like Hermes main at b3746e35 (2026-11-09):

- Every frame a session publishes carries `seq` (that session's own count, from 1) and
  `replay_epoch` beside its payload, and the session keeps its last 512 (tui_gateway/event_replay.py
  _stamp_event and _REPLAY_BUFFER_MAX; gateway/session_events.py publish). A socket that drops is
  detached as an orphan, and the turn it watched goes on: its frames are kept for nobody
  (gateway/session_authority.py detach, gateway/session_viewer_close.py arm_detached_orphan_close).
- `session.events.since {session_id, last_sequence (or last_seen), replay_epoch}`
  (CanonicalEventsParams; `profile` only routes) answers the frames after the cursor, or none and
  `snapshot_required` (and `truncated`) when the epoch is not the session's, the cursor is ahead of
  the newest frame, or the kept frames no longer reach back to it (gateway/session_events.py since,
  event_replay.is_truncated). Asked on a connection that has not attached the session, it notes how
  far it answered: that connection's next session.resume first writes every frame published since,
  then attaches, so nothing falls between the two (gateway/session_controls.py events_since and
  resume, SessionEvents.catch_up).
- `session.resume` and `session.create` answer `replay_epoch` and `last_sequence` (where a cursor
  starts), `subscription_id`, `running`, `pending` (the admissions still queued or started: the
  receipt's fields and `input_id`, which is the submission id) and `prompts` (the approvals and
  questions still waiting) (CanonicalSnapshot).
- `prompt.submit` needs the session attached on this connection (permission_denied otherwise) and
  admits a submission once per (session, submission_id): an exact retry gets the same admission's
  receipt and no second turn, the same id with other words is refused admission_conflict
  (gateway/session_controls.py submission; hermes_state_runtime.py admit_session_input). The reply
  is the receipt {admission_id, ref, sequence, status, outcome, authority_epoch,
  execution_generation}. Once admitted, `session.info` lists the pending admissions
  (gateway/session_authority.py _publish_pending), and the turn's `message.complete` names its
  submission in `persisted_turn.submission_id`. A sentence sent while a turn runs waits behind it:
  a canonical prompt.submit only queues (Submission intent "queue", the admission FIFO), it never
  cuts the running turn short.
- `approval.respond {session_id, execution_generation, prompt_id, choice}`: a closed key set, from a
  connection that has the session attached; another run's generation is refused stale_generation
  (gateway/session_controls.py respond, gateway/session_authority.py respond).
- A connection that cannot keep up loses its subscription, not its socket: the owner retires the
  viewer and writes it one `session.replay_gap {replay_epoch, latest_seq}` (no seq of its own) in
  place of the frame that overflowed, and the turn runs on. The socket still answers; the session is
  no longer attached on it until a session.resume (gateway/session_events.py publish's overflow,
  gateway/session_authority.py _retire_overflowed).

The scripted turns, in 詩音's chat, are sentences that start 「断线：」. Each drops Shion's socket at
one moment, as a network does (no close frame), and the tunnel goes down: every request gets
Cloudflare's 502 until the test brings it back with `POST /ci/tunnel/up` (StandIn.swift), a word no
real tunnel has, which comes through whatever the tunnel's state. The test says it once it has seen
what it looks for while Shion is away, so nothing hangs on how fast it types or on when Shion's tries
fall; the word is answered once what the script does meanwhile is done (the end of a reply that ends
while Shion is away, the parts its replay will have), and Shion is back at its next try. Only if
nobody says it does the tunnel come back by itself, after NOBODY seconds, so that a step that failed
before saying so does not take the rest of the test with it:

  讲到一半   80 parts 0.3 s apart; the socket drops after the 5th, the 6th to the 20th come while
             Shion is away, and the reply waits at the 20th until Shion is back and asks what it
             missed, as a reply longer than the outage would: the rest streams into the same bubble
  讲完了     10 parts 0.2 s apart, dropped after the 3rd: the reply ends while Shion is away (the
             tunnel comes back only after it has)
  还没回执   admitted, then dropped before its receipt went out; the answer's frames that follow are
             kept, and the tunnel comes back once the answer is over
  没收到     dropped before it was admitted, the first time its submission id comes; sent again with
             that id, it is admitted like any other sentence
  等你批准   asks for an approval, then drops while it waits; answered once Shion is back, the turn
             finishes
  说很多     600 one-character parts while Shion is away (the tunnel comes back once they are all
             out), more than the session keeps: the replay cannot reach back, so Shion reads the
             newest page instead
  图和文件   said with a picture and a file (the words after the file's reference): dropped before it
             was admitted, the first time; the picture is cleared from the staging folder meanwhile,
             as Hermes's cache does, so the same submission comes back refused (fake_media.py) and
             the picture goes up again, under a new id
  跟不上     40 parts 0.25 s apart; the 6th does not fit: the socket's subscription is retired and
             it gets a session.replay_gap instead, the socket kept. Nothing drops; the 6th part is
             only in the kept frames, so Shion has it from its replay on the same socket
  回传       a short reply, then the socket drops; while Shion is away Hermes starts three turns by
             itself, with what came in the user's name (`unasked`): the board's word that a card is
             done, as the gateway wakes a session with it (fake_kanban.wake, captured from Hermes
             itself: only the row says it, the start frame nothing), its card on no board any more
             (as one archived since); then the same message from another assistant twice, two
             minutes apart, whose start frames say what they start with. Shion has the frames from
             its replay, which say neither when nor which row, and the rows from the transcript
  引导两遍   a reply that waits for what is put into it (`session.steer`). The first such message is
             stored (a row of the turn, as Hermes keeps a steer) and not answered; at the second the
             socket drops, so neither has an answer. The reply ends while Shion is away. One row
             for two messages in the same words: it can say that one of them got there, never both
  又说一遍   the first time, a short reply, then the socket drops and the session's frames start
             over under another epoch, as after a restart of the server: once back, the replay
             cannot be had and the newest page is read instead. That `session.resume` is not
             answered until the test says so (`POST /ci/attach/go`), so what the test says in
             between is said while the chat is being attached again. Said again (another
             submission), it is lost: the socket drops before it is admitted, once the newest page
             has been asked for and answered. Sent again under that id, it is admitted like any
             other sentence

Stdlib only.
"""
import collections
import itertools
import json
import os
import socket
import threading
import time
import uuid

import fake_kanban
import fake_words

try:  # the run and revision a turn bumps, kept with the stop and retry module's where it is there
    import fake_control
except ImportError:
    fake_control = None

PREFIX = "断线："
CONTROL = "/ci/tunnel/up"  # the test's word that brings the tunnel back (StandIn.swift)
ATTACH = "/ci/attach/go"  # the test's word that lets a held session.resume be answered (又说一遍)
HOLD = 25.0  # seconds such a session.resume waits for that word: under the 30 s Shion waits for an answer
NOBODY = 60.0  # seconds a tunnel waits for that word before it comes back by itself
MEANWHILE = 30.0  # seconds the word waits for what a script does while Shion is away
KEPT = 512  # frames a session keeps (tui_gateway/event_replay.py _REPLAY_BUFFER_MAX)
APPROVAL = {"kind": "approval", "prompt_id": "ap-reconnect", "command": "df -h /",
            "description": "要看一下服务器的磁盘还剩多少吗？", "choices": ["once", "session", "always", "deny"]}
EVENTS_KEYS = {"session_id", "last_sequence", "last_seen", "replay_epoch"}
RESPOND_KEYS = {"session_id", "execution_generation", "prompt_id", "choice"}
CHUNK = 3  # characters per message.delta of a plain answer

state = {"log": print, "transcripts": {}, "lock": threading.Lock()}
# publishing, attaching and replaying: one at a time, as under SessionEvents.lock
bus = threading.RLock()
streams = {}  # session id -> {"epoch", "seq", "kept": frames' params, oldest first, "evicted": seq evicted through}
watchers = {}  # session id -> {handler: subscription id}: the connections that have it attached
cursors = {}  # handler -> {session id: (epoch, seq)}: how far events.since answered before it attached
admissions = {}  # (session id, submission id) -> the admission
sequence = itertools.count(1)
prompts = {}  # session id -> {prompt id: the approval still waiting}
running = {}  # session id -> the turn under way here
waiting = collections.defaultdict(list)  # session id -> admissions queued behind it
dropped = set()  # submission ids whose socket was dropped before they were admitted
gone = set()  # the words of messages with pictures and files dropped once, whatever their id
repeats = {}  # session id -> where 又说一遍 is, from its first saying until the second is lost
tunnel = threading.Lock()
down = {"held": False, "since": 0.0, "why": "", "meanwhile": None}
awaited = {}  # session id -> set once a connection asks for it again (Shion is back): a reply waits
local_fences = {}
row_ids = itertools.count(7000)


def setup(log, transcripts, lock):
    state.update(log=log, transcripts=transcripts, lock=lock)


def log(*parts):
    state["log"](*parts)


def fence(session_id):
    """The session's run and revision: the stop and retry module's when the stand-in has it."""
    if fake_control is not None:
        return fake_control.fence(session_id)
    return local_fences.setdefault(session_id, {"generation": 1, "revision": 1})


# ---- the tunnel --------------------------------------------------------------------------------

def tunnel_down(handler):
    """What the tunnel answers before the stand-in sees a request: while it is down, Cloudflare's 502
    to every request; and the test's word that brings it back (POST /ci/tunnel/up), whatever the
    tunnel's state. True when answered here."""
    if handler.command == "POST" and handler.path.split("?")[0] == CONTROL:
        bring_up(handler)
        return True
    if handler.command == "POST" and handler.path.split("?")[0] == ATTACH:
        # the test's other word here: the session.resume held back is answered now (又说一遍)
        let_attach(handler)
        return True
    with tunnel:
        held = down["held"]
        if held and time.time() - down["since"] >= NOBODY:
            down["held"] = held = False
            log(f"  -> nobody brought the tunnel back: it is up again by itself after {NOBODY:.0f} s")
    if not held:
        return False
    log(f"{handler.command} {handler.path.split('?')[0]} -> 502 (the tunnel is down)")
    body = b"<h1>502 Bad Gateway</h1><p>CI stand-in: the tunnel is down.</p>"
    handler.close_connection = True
    handler.send_response(502)
    handler.send_header("Content-Type", "text/html")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Connection", "close")
    handler.end_headers()
    handler.wfile.write(body)
    return True


def bring_up(handler):
    """POST /ci/tunnel/up: the test has seen what it looks for while Shion is away. Answered once what
    the script does meanwhile is done, with how long the tunnel was down; 409 when it is not down."""
    with tunnel:
        held, since, why, meanwhile = down["held"], down["since"], down["why"], down["meanwhile"]
    if not held:
        log(f"POST {CONTROL} -> 409 (the tunnel is not down)")
        return word(handler, 409, {"down": False})
    done = meanwhile is None or meanwhile.wait(MEANWHILE)
    with tunnel:
        down["held"] = False
    took = time.time() - since
    log(f"POST {CONTROL} -> the tunnel is back after {took:.1f} s (dropped {why})"
        + ("" if done else f"; what the script does meanwhile was not done after {MEANWHILE:.0f} s"))
    word(handler, 200, {"down": True, "seconds": round(took, 1), "meanwhile": "done" if done else "not done"})


def word(handler, status, answer):
    """The stand-in's own answer to the test's word, then the connection closes: it is no Hermes
    route, so none of the Access gate's headers go with it."""
    body = json.dumps(answer).encode()
    handler.close_connection = True
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Connection", "close")
    handler.end_headers()
    handler.wfile.write(body)


def drop(handler, why, meanwhile=None):
    """Shion's socket goes as it does when the network goes, without a close frame, and the tunnel
    goes down until the test brings it back (POST /ci/tunnel/up), not before `meanwhile` is set if
    there is one: what the script does while Shion is away. The sessions the socket had attached
    lose it, as Hermes detaches an orphan."""
    with tunnel:
        down.update(held=True, since=time.time(), why=why, meanwhile=meanwhile)
    with bus:
        forget(handler)
    log(f"  -> dropped the socket {why}; the tunnel is down until the test brings it back")
    try:
        handler.connection.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


# ---- frames ------------------------------------------------------------------------------------

def stream(session_id):
    found = streams.get(session_id)
    if found is None:
        found = streams[session_id] = {"epoch": uuid.uuid4().hex, "seq": 0, "kept": collections.deque(),
                                       "evicted": 0}
    return found


def back_for(session_id):
    """An event set once a connection asks for the session again, after a drop: Shion is back."""
    with bus:
        event = awaited[session_id] = threading.Event()
    return event


def asked_again(session_id):
    """events.since or session.resume for a session: a reply waiting for Shion goes on. The caller
    holds the bus."""
    event = awaited.pop(session_id, None)
    if event is not None:
        event.set()


def forget(handler):
    """The caller holds the bus."""
    for watched in watchers.values():
        watched.pop(handler, None)
    cursors.pop(handler, None)


def closed(handler):
    """A socket's loop ended (closed by Shion, or dropped): nothing more goes to it."""
    with bus:
        forget(handler)


def publish(session_id, kind, payload, generation=None, admission_id=None):
    """One frame of a session: stamped with its seq and epoch, kept, and sent to every connection
    that has the session attached (none, while Shion is away)."""
    with bus:
        found = stream(session_id)
        found["seq"] += 1
        params = {"type": kind, "session_id": session_id, "payload": payload, "replay_epoch": found["epoch"],
                  "seq": found["seq"]}
        if generation is not None:
            params.update(authority_epoch=1, execution_generation=generation)
        if admission_id is not None:
            params["admission_id"] = admission_id
        found["kept"].append(params)
        while len(found["kept"]) > KEPT:
            found["evicted"] = found["kept"].popleft()["seq"]
        # what still waits for an answer, for the snapshot (the session's PendingControls)
        if kind in ("approval.request", "clarify.request") and isinstance(payload, dict) and payload.get("prompt_id"):
            prompts.setdefault(session_id, {})[payload["prompt_id"]] = {"kind": kind.split(".")[0], **payload}
        elif kind in ("approval.settled", "clarify.settled") and isinstance(payload, dict):
            prompts.get(session_id, {}).pop(payload.get("prompt_id"), None)
        for handler in list(watchers.get(session_id, {})):
            try:
                handler.send_json({"jsonrpc": "2.0", "method": "event", "params": params})
            except (OSError, ValueError):  # gone; a closed handler's file raises ValueError
                forget(handler)


def attach(handler, session_id):
    """session.resume or session.create on this connection: first the frames published since the
    cursor its events.since answered, then the session's frames as they come. Returns what the
    snapshot adds."""
    hold(session_id)  # 又说一遍: not before the test says so
    with bus:
        asked_again(session_id)
        found = stream(session_id)
        cursor = cursors.get(handler, {}).pop(session_id, None)
        caught = 0
        if cursor is not None and cursor[0] == found["epoch"] and cursor[1] >= found["evicted"]:
            for params in list(found["kept"]):
                if params["seq"] > cursor[1]:
                    handler.send_json({"jsonrpc": "2.0", "method": "event", "params": params})
                    caught += 1
        subscription = "sub-" + uuid.uuid4().hex[:12]
        watchers.setdefault(session_id, {})[handler] = subscription
        fields = {"replay_epoch": found["epoch"], "last_sequence": found["seq"], "subscription_id": subscription,
                  "pending": pending(session_id)}
        if session_id in running:
            fields["running"] = True
        if prompts.get(session_id):
            fields["prompts"] = list(prompts[session_id].values())
    if cursor is not None:
        log(f"    attached {session_id} after a replay to seq {cursor[1]}: {caught} frames caught up first")
    return fields


def events_since(handler, params, rid):
    args = {key: value for key, value in params.items() if key != "profile"}
    unknown = sorted(set(args) - EVENTS_KEYS)
    session_id = args.get("session_id")
    after = args.get("last_sequence", args.get("last_seen", 0))
    epoch = args.get("replay_epoch")
    if unknown or not isinstance(session_id, str) or type(after) is not int or after < 0 or (
            epoch is not None and not isinstance(epoch, str)):
        return refuse(handler, rid, "invalid_params", fields=unknown or ["last_sequence"])
    with state["lock"]:
        known = session_id in state["transcripts"]
    if not known:
        return refuse(handler, rid, "not_found")
    with bus:
        asked_again(session_id)
        found = stream(session_id)
        latest, current = found["seq"], found["epoch"]
        missing = epoch != current or after > latest or after < found["evicted"]
        events = [] if missing else [dict(params) for params in found["kept"] if params["seq"] > after]
        if not missing and handler not in watchers.get(session_id, {}):
            cursors.setdefault(handler, {})[session_id] = (current, max([e["seq"] for e in events], default=after))
    if missing:
        why = ("another epoch" if epoch != current else "a cursor ahead of the newest frame" if after > latest
               else f"frames up to {found['evicted']} no longer kept")
        log(f"    events since {after} on {session_id}: snapshot required ({why}; newest is {latest})")
    else:
        log(f"    events since {after} on {session_id}: {len(events)} frames, up to {latest}")
    handler.send_json({"jsonrpc": "2.0", "id": rid, "result": {
        "events": events, "latest_seq": latest, "last_sequence": latest, "epoch": current, "replay_epoch": current,
        "truncated": missing, "snapshot_required": missing, "count": len(events), "open_requests": []}})
    return True


# ---- admissions --------------------------------------------------------------------------------

def admit(session_id, submission, text, profile):
    with bus:
        admission = {"admission_id": "adm-" + uuid.uuid4().hex[:12], "session_id": session_id,
                     "profile": profile or "shion", "input_id": submission, "text": text, "sequence": next(sequence),
                     "status": "queued", "outcome": None, "generation": None}
        admissions[(session_id, submission)] = admission
    return admission


def receipt_of(admission):
    return {"admission_id": admission["admission_id"],
            "ref": {"profile_id": admission["profile"], "session_id": admission["session_id"]},
            "sequence": admission["sequence"], "status": admission["status"], "outcome": admission["outcome"],
            "authority_epoch": 1, "execution_generation": admission["generation"]}


def pending(session_id):
    """The session's admissions still queued or started, oldest first (PendingAdmission)."""
    with bus:
        rows = sorted((a for a in admissions.values()
                       if a["session_id"] == session_id and a["status"] in ("queued", "started")),
                      key=lambda a: a["sequence"])
        return [{**receipt_of(a), "input_id": a["input_id"], "text": a["text"], "controls": [], "steering": False}
                for a in rows]


def publish_pending(session_id, generation=None):
    current = fence(session_id)
    publish(session_id, "session.info", {
        "stored_session_id": session_id, "pending": pending(session_id), "authority_epoch": 1,
        "desktop_protocol": "hermes-gateway-v1", "running": session_id in running,
        "execution_generation": current["generation"], "revision": current["revision"]}, generation)


def receipt(params):
    """The receipt of a sentence the stand-in answers itself (fake_hermes.py): admitted here, so an
    exact retry is known, and published as pending first, as every admission is. Its turn runs at
    once and is over before anything else comes."""
    admission = admit(params.get("session_id"), params.get("submission_id") or params.get("input_id"),
                      fake_words.sent(params.get("text", "")), params.get("profile"))
    publish_pending(admission["session_id"])
    answer = receipt_of(admission)
    admission.update(status="terminal", outcome="completed")
    return answer


def submit(handler, params, rid):
    """prompt.submit. True when answered here: a refusal, an exact retry, a scripted turn, or a
    sentence that waits behind the turn under way. False leaves an ordinary sentence to the
    stand-in's own answers, whose reply is receipt()."""
    # the words as the scripts read them (fake_hermes.py); what was sent is what Hermes keeps
    session_id, text, profile = params.get("session_id"), params.get("text", ""), params.get("profile")
    original = fake_words.sent(text)
    submission = params.get("submission_id") or params.get("input_id")
    if not isinstance(submission, str) or not submission:
        return refuse(handler, rid, "invalid_params", fields=["submission_id"])
    with bus:
        attached = handler in watchers.get(session_id, {})
        known = admissions.get((session_id, submission))
    if not attached:
        # Hermes takes a prompt only from a connection that has the session attached
        log(f"    {session_id} is not attached on this connection")
        return refuse(handler, rid, "permission_denied")
    if known is not None:
        if known["text"] != original:
            return refuse(handler, rid, "admission_conflict", field="request_id",
                          detail="this request id was already admitted with another payload")
        log(f"    exact retry of {submission}: the same admission ({known['status']}), no second turn")
        handler.send_json({"jsonrpc": "2.0", "id": rid, "result": receipt_of(known)})
        return True
    words = said(text)
    if words == PREFIX + "图和文件" and words not in gone:
        # sent as the connection went, before Hermes had it; its picture cleared meanwhile, so the
        # same submission sent again finds it gone, and the picture goes up again, a new submission
        gone.add(words)
        expire(params.get("attachments"))
        drop(handler, f"before {words!r} with its picture and file was admitted")
        return True
    if text.startswith(PREFIX) and submission not in dropped:
        what = text[len(PREFIX):].strip()
        if what in SCRIPTS:
            return scripted(handler, what, session_id, submission, original, profile, rid)
    if session_id in running:
        admission = admit(session_id, submission, original, profile)
        log(f"    {original!r} waits behind the turn under way")
        handler.send_json({"jsonrpc": "2.0", "id": rid, "result": receipt_of(admission)})
        with bus:
            waiting[session_id].append(admission)
        publish_pending(session_id)
        return True
    return False


def answer(handler, method, params, rid):
    """The requests this module answers itself; True once answered."""
    if method == "session.events.since":
        return events_since(handler, params, rid)
    if method == "prompt.submit":
        return submit(handler, params, rid)
    if method == "approval.respond" and params.get("prompt_id") == APPROVAL["prompt_id"]:
        return respond(handler, params, rid)
    if method in ("session.steer", "session.redirect"):
        return steered(handler, params)  # into 引导两遍's turn; any other is the stop and retry module's
    if method == "session.transcript" and params.get("cursor") is None:
        page_asked(params.get("session_id"))  # 又说一遍 waits for it; the stand-in answers it as ever
    return False


def refuse(handler, rid, reason, **data):
    log(f"    refused: {reason} {data}")
    handler.send_json({"jsonrpc": "2.0", "id": rid, "error": {
        "code": 4001, "message": reason, "data": {"reason": reason, **data}}})
    return True


# ---- turns -------------------------------------------------------------------------------------

def scripted(handler, what, session_id, submission, text, profile, rid):
    if what == "没收到":
        dropped.add(submission)
        drop(handler, f"before {text!r} was admitted")
        return True
    if what == "又说一遍" and session_id in repeats:
        return said_again(handler, session_id, submission, text)
    admission = admit(session_id, submission, text, profile)
    # meanwhile: set once what the turn does while Shion is away is done (the tunnel waits for it)
    turn = {"what": what, "session_id": session_id, "text": text, "admission": admission, "handler": handler,
            "said": "", "answered": threading.Event(), "choice": None, "meanwhile": threading.Event()}
    with bus:
        running[session_id] = turn
    if what == "还没回执":
        # admitted, and the socket gone before the receipt: what comes now is kept for the replay
        drop(handler, f"after admitting {text!r}, before its receipt", turn["meanwhile"])
        publish_pending(session_id)
    else:
        publish_pending(session_id)
        handler.send_json({"jsonrpc": "2.0", "id": rid, "result": receipt_of(admission)})
    threading.Thread(target=SCRIPTS[what], args=(turn,), daemon=True).start()
    return True


def keep(session_id, role, text, at=None, **more):
    """A row of the session's transcript, dated now unless `at` says when."""
    row_id = next(row_ids)
    with state["lock"]:
        state["transcripts"].setdefault(session_id, []).append(
            {"row_id": row_id, "row_kind": "message", "role": role, "text": text,
             "timestamp": time.time() if at is None else at, **more})
    return row_id


def begin(turn):
    """The turn starts: its run is the session's next one, its prompt goes into the transcript."""
    session_id, admission = turn["session_id"], turn["admission"]
    with bus:
        current = fence(session_id)
        current["generation"] += 1
        admission.update(status="started", generation=current["generation"])
        turn["generation"] = current["generation"]
    # the row keeps whose submission it was, as Hermes stores a prompt (display_metadata, captured
    # from Hermes itself): a client reading the transcript can tell the row is its own message
    owned = {"gateway_input_owner": "ci", **({"submission_id": admission["input_id"]} if admission.get("input_id") else {})}
    turn["user_row"] = keep(session_id, "user", turn["text"], display_metadata=owned)
    publish_pending(session_id, turn["generation"])
    publish(session_id, "message.start", {}, turn["generation"], admission["admission_id"])


def say(turn, part):
    turn["said"] += part
    publish(turn["session_id"], "message.delta", {"text": part}, turn["generation"], turn["admission"]["admission_id"])


def end(turn):
    """The turn settles: its reply into the transcript, message.complete with the rows it stored and
    whose submission it was, the pending list again; then the next sentence waiting, if any."""
    session_id, admission, text = turn["session_id"], turn["admission"], turn["said"]
    answer_row = keep(session_id, "assistant", text)
    with bus:
        admission.update(status="terminal", outcome="completed")
        running.pop(session_id, None)
        fence(session_id)["revision"] += 1
        after = waiting[session_id].pop(0) if waiting[session_id] else None
        if after is not None:
            running[session_id] = {"what": "plain", "session_id": session_id, "text": after["text"],
                                   "admission": after, "said": ""}
    publish(session_id, "message.complete", {
        "text": text, "content": text, "status": "complete", "outcome": "completed",
        "admission_id": admission["admission_id"],
        "persisted_turn": {"row_ids": [turn["user_row"], answer_row], "complete": True,
                           "user_row_id": turn["user_row"], "user_row_ids": [turn["user_row"]],
                           "final_assistant_row_id": answer_row, "submission_id": admission["input_id"]},
    }, turn["generation"], admission["admission_id"])
    publish_pending(session_id)
    log(f"  -> {turn['what']} turn on {session_id} done: {len(text)} characters")
    if after is not None:
        threading.Thread(target=plain, args=(running[session_id],), daemon=True).start()


def plain(turn):
    """A sentence that waited behind a turn: answered 「收到：…」, as the stand-in answers any other."""
    time.sleep(0.2)
    begin(turn)
    # the answer echoes the words as read; the user's row keeps them as sent
    reply = "收到：" + fake_words.read(turn["text"])
    for start in range(0, len(reply), CHUNK):
        time.sleep(0.2)
        say(turn, reply[start:start + CHUNK])
    end(turn)


def halfway(turn):
    begin(turn)
    for n in range(1, 81):
        time.sleep(0.3)
        say(turn, f"第{n}段。")
        if n == 5:
            back = back_for(turn["session_id"])
            drop(turn["handler"], "half way through a reply", turn["meanwhile"])
        elif n == 20:
            # as long a reply as the outage: the 6th to the 20th are Shion's replay, and the rest
            # goes on once Shion is back and asks what it missed, so it streams in live
            turn["meanwhile"].set()
            if not back.wait(NOBODY + MEANWHILE):
                log("  -> Shion did not come back to 讲到一半: the rest goes on anyway")
    end(turn)


def finished(turn):
    begin(turn)
    for n in range(1, 11):
        time.sleep(0.2)
        say(turn, f"第{n}句。")
        if n == 3:
            drop(turn["handler"], "three parts into a short reply", turn["meanwhile"])
    end(turn)
    turn["meanwhile"].set()  # the reply ended while Shion was away: only now may the tunnel come back


def unacked(turn):
    time.sleep(0.5)
    begin(turn)
    # the answer echoes the words as read; the user's row keeps them as sent
    reply = "收到：" + fake_words.read(turn["text"])
    for start in range(0, len(reply), CHUNK):
        time.sleep(0.3)
        say(turn, reply[start:start + CHUNK])
    end(turn)
    turn["meanwhile"].set()  # answered while Shion was away: its replay has all of it


def approval(turn):
    begin(turn)
    time.sleep(0.3)
    say(turn, "要先在服务器上跑一条命令。")
    time.sleep(0.5)
    session_id, generation = turn["session_id"], turn["generation"]
    prompt = {**APPROVAL, "execution_generation": generation}
    log(f"  -> approval.request {prompt['prompt_id']} on {session_id}")
    publish(session_id, "approval.request", prompt, generation, turn["admission"]["admission_id"])
    time.sleep(1.5)
    drop(turn["handler"], "while an approval waits")
    if not turn["answered"].wait(300):
        with bus:
            prompts.get(session_id, {}).pop(prompt["prompt_id"], None)
        log("  -> the approval was never answered")
        say(turn, "（没等到批准）")
        return end(turn)
    publish(session_id, "approval.settled", {"prompt_id": prompt["prompt_id"], "execution_generation": generation},
            generation)
    for part in (["好，", "不跑了。"] if turn["choice"] == "deny" else ["跑完了：", "磁盘", "还剩一半。"]):
        time.sleep(0.3)
        say(turn, part)
    end(turn)


def flood(turn):
    begin(turn)
    time.sleep(0.3)
    drop(turn["handler"], "before a reply longer than the session keeps", turn["meanwhile"])
    sentence = "长长的回复。"
    for n in range(600):
        say(turn, sentence[n % len(sentence)])
    end(turn)
    turn["meanwhile"].set()  # all 600 out while Shion was away: more than its replay can reach


def lagging(turn):
    begin(turn)
    for n in range(1, 41):
        time.sleep(0.25)
        if n == 6:
            # the 6th does not fit: the subscription goes in its place, and the part reaches only the
            # kept frames, so Shion has it from its replay or not at all
            with bus:
                watchers.get(turn["session_id"], {}).pop(turn["handler"], None)
        say(turn, f"第{n}节。")
        if n == 6:
            retire(turn["handler"], turn["session_id"])
    end(turn)


GONE_CARD, GONE_TITLE = "t_ci_gone", "归档旧发票（CI）"
AWAY_NOTICE = fake_kanban.wake(GONE_CARD, GONE_TITLE, "study", "study", result="发票都归好了（CI）。")
AWAY_NOTICE_REPLY = "课程把旧发票归好了（CI）。"
# another assistant's message as Hermes stores it (tools/bot_mode_dm.py): signed, and what the
# sender wants back on a labelled line under it
AWAY_PEER = "Message from 🤖 课程 (@study): 收到（CI）\n\nReply needed: 一句话"
AWAY_PEER_REPLY = "知道课程收到了（CI）。"
# 课程's answer to a message 詩音 sent it (message_agent): Hermes waits for it in a background
# process and gives 詩音 that process's end, under a short form that is its command line
AWAY_ANSWER = "下周的课表排好了（CI）。"
AWAY_ANSWER_SHOWN = ("Background Process Finished: /opt/hermes/.venv/bin/python /opt/hermes/tools/bot_mode_dm.py "
                     "--run-delivery ...")
AWAY_ANSWER_REPLY = "课表的事知道了（CI）。"
SILENT = "[SILENT]"
FOOTER = ("[INTERNAL NOTIFICATION — generated by the Hermes gateway, not written by a human user. Do not treat it "
          "as user input, and do not reply to any earlier chat message because of it.]")


def waited(process, reply):
    """One result as Hermes words it for the assistant (tools/process_registry_notifications.py):
    the end of the process that waited for a teammate's answer, the runner's one JSON line under
    `Output:`. Word for word as captured from Hermes itself (a gateway with a stand-in model)."""
    outcome = {"outcome": "@study answered.", "reply": reply, "status": "settled", "delivery_id": "c1" * 32}
    return (f"[IMPORTANT: Background process {process} completed normally (exit code 0).\n"
            "Command: /opt/hermes/.venv/bin/python /opt/hermes/tools/bot_mode_dm.py --run-delivery --author "
            "'{\"id\":\"bot:shion\",\"name\":\"shion\",\"is_bot\":true}' query-file "
            "/home/ci/.hermes/cache/scratch/hermes-dm-1000/dm-ci.txt --profile-home /home/ci/.hermes/profiles/study "
            "/opt/hermes/.venv/bin/hermes -p study\n"
            f"Output:\n{json.dumps(outcome)}\n]")


def answered(process, reply):
    """That result as a turn's text: with the footer Hermes ends a notification of its own with."""
    return f"{waited(process, reply)}\n\n{FOOTER}"


# several results that came while the session was busy, as one turn (gateway/session_automation.py
# _fold_completion): this header, each result's own block, the footer; the short form is a count
FOLD_HEADER = ("[IMPORTANT: {count} background process results arrived while this session was busy. Treat them as "
               "one batch and give one consolidated response; preserve failures and actionable results.]")


def folded(results):
    return "\n\n".join([FOLD_HEADER.format(count=len(results)), *results, FOOTER])


# a command of the assistant's own that failed, as Hermes words it
BACKUP_FAILED = ("[IMPORTANT: Background process proc_ci0009 exited (exit code 1).\nCommand: ./backup.sh\n"
                 "Output:\ncopying…\n\nNo space left on device（CI）\n]")
MANY = 8
MANY_WORDS = "带话（CI）第{n}条"
MANY_REPLY = "第{n}条知道了（CI）。"
MANY_ANSWER = "周五有空（CI）。"
MANY_LAST = "两件事都知道了（CI）。"


def many(turn):
    """More turns while Shion is away than the newest rows it first reads can show: eight messages
    from 课程, each a turn whose start says nothing (only its row says what it was), then two
    results folded into one turn, a teammate's answer and a command that failed."""
    begin(turn)
    time.sleep(0.2)
    say(turn, "好的（CI）。")
    end(turn)
    time.sleep(0.5)
    drop(turn["handler"], "after a short reply, before many turns Hermes starts by itself", turn["meanwhile"])
    session_id, now = turn["session_id"], time.time()
    for n in range(1, MANY + 1):
        unasked(session_id, f"Message from 🤖 课程 (@study): {MANY_WORDS.format(n=n)}", MANY_REPLY.format(n=n),
                now - 10 * (MANY - n + 1))
    unasked(session_id, folded([waited("proc_ci0008", MANY_ANSWER), BACKUP_FAILED]), MANY_LAST, now, "process_complete",
            "2 Background Processes Finished")
    turn["meanwhile"].set()


def notices(turn):
    begin(turn)
    time.sleep(0.2)
    say(turn, "好（CI）。")
    end(turn)
    time.sleep(0.5)
    drop(turn["handler"], "after a short reply, before what Hermes starts by itself", turn["meanwhile"])
    session_id, now = turn["session_id"], time.time()
    # the board's word and 课程's message: only their rows say what started the turn. Then 课程's
    # answer to a message of 詩音's, twice in the same words (an hour apart, the first with nothing
    # said after it): the turn's start says it and so does its row
    unasked(session_id, AWAY_NOTICE, AWAY_NOTICE_REPLY, now)
    unasked(session_id, AWAY_PEER, AWAY_PEER_REPLY, now - 130)
    unasked(session_id, answered("proc_ci0001", AWAY_ANSWER), SILENT, now - 3600, "process_complete", AWAY_ANSWER_SHOWN)
    unasked(session_id, answered("proc_ci0002", AWAY_ANSWER), AWAY_ANSWER_REPLY, now - 5, "process_complete",
            AWAY_ANSWER_SHOWN)
    turn["meanwhile"].set()  # all four over while Shion was away: its replay has them


def unasked(session_id, text, reply, at, kind="internal_notification", shown=None):
    """A turn Hermes starts by itself, with what it gives the assistant in the user's name: the row
    it is stored with, dated `at`, of the kind Hermes gives such turns; the turn's start; the
    reply and its row; the end, which names the rows and no submission.

    As captured from Hermes itself. The board's word (fake_kanban.wake) and another assistant's
    message start a turn whose `message.start` is empty: only the row says what it was. The end of
    a background process comes with a short form to show (`shown`): the start carries it with the
    turn's text (display_kind, display_text, text; no row, no time), and the row keeps it in its
    display_metadata."""
    with bus:
        current = fence(session_id)
        current["generation"] += 1
        generation = current["generation"]
    metadata = {"gateway_input_owner": "ci", **({"display_text": shown} if shown else {})}
    user_row = keep(session_id, "user", text, at, display_kind=kind, display_metadata=metadata)
    publish(session_id, "message.start",
            {"display_kind": kind, "display_text": shown, "text": text} if shown else {}, generation)
    for start in range(0, len(reply), CHUNK):
        publish(session_id, "message.delta", {"text": reply[start:start + CHUNK]}, generation)
    answer_row = keep(session_id, "assistant", reply, at + 5)
    with bus:
        fence(session_id)["revision"] += 1
    # an assistant with nothing to say streams the marker and ends with no text; its row keeps the marker
    final = "" if reply == SILENT else reply
    publish(session_id, "message.complete", {
        "text": final, "content": final, "status": "complete", "outcome": "completed",
        "persisted_turn": {"row_ids": [user_row, answer_row], "complete": True, "user_row_id": user_row,
                           "user_row_ids": [user_row], "final_assistant_row_id": answer_row},
    }, generation)
    publish_pending(session_id)
    log(f"  -> a turn Hermes started itself on {session_id}: {text.splitlines()[0]!r}, its row dated {time.time() - at:.0f} s ago")


def retire(handler, session_id):
    """The owner gives up on a viewer that cannot keep up: its subscription goes, its socket stays,
    and it gets one session.replay_gap in place of the frame that did not fit, naming the newest
    (gateway/session_events.py publish's overflow)."""
    with bus:
        watchers.get(session_id, {}).pop(handler, None)
        found = stream(session_id)
        gap = {"type": "session.replay_gap", "session_id": session_id,
               "payload": {"replay_epoch": found["epoch"], "latest_seq": found["seq"]}}
    log(f"  -> {session_id}'s subscription on this socket retired, the socket kept: session.replay_gap at {gap['payload']['latest_seq']}")
    try:
        handler.send_json({"jsonrpc": "2.0", "method": "event", "params": gap})
    except (OSError, ValueError):
        pass


def said(text):
    """A message's words: what follows the `@file:` lines its files' references are."""
    lines = text.split("\n")
    while lines and (lines[0].startswith("@file:") or lines[0].startswith("@folder:")):
        lines.pop(0)
    return "\n".join(lines).strip()


def expire(attachments):
    """Clears a message's staged pictures, as Hermes's cache does after a while (fake_media.py)."""
    try:
        import fake_media
    except ImportError:
        return
    for item in attachments if isinstance(attachments, list) else []:
        target = fake_media.real(item.get("path", "")) if isinstance(item, dict) else None
        if target and os.path.isfile(target):
            os.remove(target)
            log(f"    cleared the staged picture {item['path']}")


SCRIPTS = {"讲到一半": halfway, "讲完了": finished, "还没回执": unacked, "没收到": None, "等你批准": approval,
           "说很多": flood, "跟不上": lagging, "回传": notices, "很多": many}


def respond(handler, params, rid):
    args = {key: value for key, value in params.items() if key != "profile"}
    if set(args) != RESPOND_KEYS:
        return refuse(handler, rid, "invalid_params", fields=sorted(set(args) ^ RESPOND_KEYS))
    session_id, prompt_id = args["session_id"], args["prompt_id"]
    with bus:
        attached = handler in watchers.get(session_id, {})
        prompt = prompts.get(session_id, {}).get(prompt_id)
        turn = running.get(session_id)
    if not attached:
        return refuse(handler, rid, "permission_denied")
    if prompt is None or turn is None:
        handler.send_json({"jsonrpc": "2.0", "id": rid, "result": {"status": "already_resolved", "prompt_id": prompt_id}})
        return True
    if type(args["execution_generation"]) is not int or args["execution_generation"] != prompt["execution_generation"]:
        return refuse(handler, rid, "stale_generation")
    if args["choice"] not in prompt["choices"]:
        return refuse(handler, rid, "invalid_params", fields=["choice"])
    with bus:
        prompts[session_id].pop(prompt_id, None)
    log(f"    answered {prompt_id}: {args['choice']!r}")
    handler.send_json({"jsonrpc": "2.0", "id": rid, "result": {"status": "resolved", "prompt_id": prompt_id}})
    turn["choice"] = args["choice"]
    turn["answered"].set()
    return True


# ---- the same words twice ----------------------------------------------------------------------
# Two messages in the same words, where only the transcript can say what became of each: put into a
# running turn as the connection goes (引导两遍), and said again while the chat is being attached
# again, the second one lost (又说一遍). What the test types for them has no character XCUI's typing
# can give as a compatibility ideograph (fake_words.py): the two sayings must be the same words.

STEERING_FIRST, STEERING_REST = "听着呢（CI）。", ["好，", "按新的时间来（CI）。"]
STEERING_WAITS = 30.0  # seconds 引导两遍's reply waits for the two messages before it ends without them
AGAIN_REPLY = "头一遍听到了（CI）。"
LOSES_AFTER = 0.5  # seconds between the newest page's answer and the drop that loses 又说一遍


def steering(turn):
    """引导两遍: a reply that waits for the two messages put into it (`steered`), and ends while Shion
    is away."""
    with bus:
        heard = turn.setdefault("heard", threading.Event())
    begin(turn)
    time.sleep(0.3)
    say(turn, STEERING_FIRST)
    if not heard.wait(STEERING_WAITS):
        log(f"  -> nothing was put into the 引导两遍 turn twice in {STEERING_WAITS:.0f} s: it ends as it is")
    for part in STEERING_REST:
        time.sleep(0.3)
        say(turn, part)
    end(turn)
    turn["meanwhile"].set()  # ended while Shion was away: its replay has the end


def steered(handler, params):
    """session.steer (or session.redirect) into 引导两遍's turn, named by its run. The first is
    stored, as Hermes keeps what is put into a turn (a user row of display_kind steer, in the words
    as sent), and gets no answer; at the second the socket drops, nothing stored. So neither message
    has an answer, and the transcript has one row for the two. False for any other turn's: the
    stop and retry module answers those."""
    session_id, text = params.get("session_id"), params.get("text")
    with bus:
        turn = running.get(session_id)
        if (turn is None or turn.get("what") != "引导两遍" or not isinstance(text, str)
                or params.get("execution_generation") != turn.get("generation")):
            return False
        heard = turn.setdefault("heard", threading.Event())
        turn["steers"] = count = turn.get("steers", 0) + 1
    if count == 1:
        row = keep(session_id, "user", text, display_kind="steer")
        log(f"    into the 引导两遍 turn: {text!r} stored as row {row}, and no answer yet")
    elif count == 2:
        log(f"    into the 引导两遍 turn again: {text!r}, not stored")
        drop(handler, "as a second message was put into the turn, neither answered", turn["meanwhile"])
        heard.set()
    else:
        log(f"    into the 引导两遍 turn a {count}th time: not answered")
    return True


def again(turn):
    """又说一遍, the first time: a short reply, the socket drops, and the session's frames start over
    under another epoch, as after a restart of the server: the replay Shion asks for once back
    cannot be had (snapshot_required), so it reads the newest page. The session.resume before that
    page waits for the test's word (`hold`)."""
    session_id = turn["session_id"]
    begin(turn)
    time.sleep(0.2)
    say(turn, AGAIN_REPLY)
    end(turn)
    time.sleep(0.5)
    drop(turn["handler"], "after a short reply; its frames start over under another epoch", turn["meanwhile"])
    with bus:
        streams[session_id] = {"epoch": uuid.uuid4().hex, "seq": 0, "kept": collections.deque(), "evicted": 0}
        repeats[session_id] = {"go": threading.Event(), "paged": False, "lost": None}
    turn["meanwhile"].set()  # only now may the tunnel come back: the next session.resume is held


def hold(session_id):
    """A session.resume for a session whose 又说一遍 was said once: answered when the test says so
    (POST /ci/attach/go, `let_attach`), so what the test says before that is said on a socket that
    has not attached the chat yet. After HOLD seconds it is answered anyway, and the test's word
    then finds nothing held."""
    with bus:
        gate = repeats.get(session_id)
    if gate is None or gate["go"].is_set():
        return
    log(f"    {session_id}: this answer waits for the test's word (POST {ATTACH})")
    if not gate["go"].wait(HOLD):
        log(f"  -> nobody said so: {session_id} is attached after {HOLD:.0f} s")
        gate["go"].set()


def let_attach(handler):
    """POST /ci/attach/go: the session.resume held back is answered now; 409 when none is."""
    with bus:
        held = [gate for gate in repeats.values() if not gate["go"].is_set()]
        for gate in held:
            gate["go"].set()
    log(f"POST {ATTACH} -> " + ("the chat is attached now" if held else "409 (no session.resume is held back)"))
    word(handler, 200 if held else 409, {"held": bool(held)})


def page_asked(session_id):
    """The newest page of a session is asked for, after its held session.resume was answered: Shion
    is reading it in the chat's place. 又说一遍 said again is lost only after that."""
    with bus:
        gate = repeats.get(session_id)
        if gate is None or not gate["go"].is_set() or gate["paged"]:
            return
        gate["paged"] = True
        lost = gate["lost"]
    if lost is not None:
        lose(session_id, *lost)


def said_again(handler, session_id, submission, text):
    """又说一遍 said again, another submission: lost. The socket drops before it is admitted, once
    the newest page has been asked for and answered (a moment after, so that Shion has read it):
    the page has the first saying's row, in the same words, and not this message. Sent again under
    its id, it is admitted like any other sentence (`dropped`)."""
    dropped.add(submission)
    with bus:
        gate = repeats[session_id]
        gate["lost"] = (handler, text)
        paged = gate["paged"]
    if paged:
        lose(session_id, handler, text)
    else:
        log(f"    {text!r}, said again, waits to be lost until the newest page is asked for")
    return True


def lose(session_id, handler, text):
    """The drop that loses 又说一遍 said again, a moment after the page's answer."""
    def later():
        time.sleep(LOSES_AFTER)
        with bus:
            repeats.pop(session_id, None)
        drop(handler, f"before {text!r}, said again, was admitted; the newest page was read first")
    threading.Thread(target=later, daemon=True).start()


SCRIPTS.update({"引导两遍": steering, "又说一遍": again})
