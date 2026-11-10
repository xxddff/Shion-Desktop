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
one moment, as a network does (no close frame); then for a few seconds (OUTAGE, unless said) the
tunnel is down and every request gets Cloudflare's 502:

  讲到一半   80 parts 0.3 s apart; the socket drops after the 5th and the tunnel stays down 8 s (time
             to say something meanwhile); the reply is still going when Shion is back, so the rest
             streams into the same bubble
  讲完了     10 parts 0.2 s apart, dropped after the 3rd: the reply ends while the tunnel is down
  还没回执   admitted, then dropped before its receipt went out; the frames that follow are kept
  没收到     dropped before it was admitted, the first time its submission id comes; sent again with
             that id, it is admitted like any other sentence
  等你批准   asks for an approval, then drops while it waits; answered once Shion is back, the turn
             finishes
  说很多     600 one-character parts while the tunnel is down, more than the session keeps: the
             replay cannot reach back, so Shion reads the newest page instead
  图和文件   said with a picture and a file (the words after the file's reference): dropped before it
             was admitted, the first time; the picture is cleared from the staging folder meanwhile,
             as Hermes's cache does, so the same submission comes back refused (fake_media.py) and
             the picture goes up again, under a new id
  跟不上     40 parts 0.25 s apart; the 6th does not fit: the socket's subscription is retired and
             it gets a session.replay_gap instead, the socket kept. Nothing drops; the 6th part is
             only in the kept frames, so Shion has it from its replay on the same socket

Stdlib only.
"""
import collections
import itertools
import os
import socket
import threading
import time
import uuid

import fake_words

try:  # the run and revision a turn bumps, kept with the stop and retry module's where it is there
    import fake_control
except ImportError:
    fake_control = None

PREFIX = "断线："
OUTAGE = 4.0  # seconds the tunnel stays down after a drop
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
down = {"until": 0.0}
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
    """While the tunnel is down every request gets Cloudflare's 502. True when answered so."""
    if time.time() >= down["until"]:
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


def drop(handler, why, outage=OUTAGE):
    """Shion's socket goes as it does when the network goes, without a close frame; the tunnel
    then stays down a while. The sessions it had attached lose it, as Hermes detaches an orphan."""
    down["until"] = time.time() + outage
    with bus:
        forget(handler)
    log(f"  -> dropped the socket {why}; the tunnel is down for {outage:.0f} s")
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
    with bus:
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
    admission = admit(session_id, submission, text, profile)
    turn = {"what": what, "session_id": session_id, "text": text, "admission": admission, "handler": handler,
            "said": "", "answered": threading.Event(), "choice": None}
    with bus:
        running[session_id] = turn
    if what == "还没回执":
        # admitted, and the socket gone before the receipt: what comes now is kept for the replay
        drop(handler, f"after admitting {text!r}, before its receipt")
        publish_pending(session_id)
    else:
        publish_pending(session_id)
        handler.send_json({"jsonrpc": "2.0", "id": rid, "result": receipt_of(admission)})
    threading.Thread(target=SCRIPTS[what], args=(turn,), daemon=True).start()
    return True


def keep(session_id, role, text):
    row_id = next(row_ids)
    with state["lock"]:
        state["transcripts"].setdefault(session_id, []).append(
            {"row_id": row_id, "row_kind": "message", "role": role, "text": text, "timestamp": time.time()})
    return row_id


def begin(turn):
    """The turn starts: its run is the session's next one, its prompt goes into the transcript."""
    session_id, admission = turn["session_id"], turn["admission"]
    with bus:
        current = fence(session_id)
        current["generation"] += 1
        admission.update(status="started", generation=current["generation"])
        turn["generation"] = current["generation"]
    turn["user_row"] = keep(session_id, "user", turn["text"])
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
            drop(turn["handler"], "half way through a reply", outage=8.0)
    end(turn)


def finished(turn):
    begin(turn)
    for n in range(1, 11):
        time.sleep(0.2)
        say(turn, f"第{n}句。")
        if n == 3:
            drop(turn["handler"], "three parts into a short reply")
    end(turn)


def unacked(turn):
    time.sleep(0.5)
    begin(turn)
    # the answer echoes the words as read; the user's row keeps them as sent
    reply = "收到：" + fake_words.read(turn["text"])
    for start in range(0, len(reply), CHUNK):
        time.sleep(0.3)
        say(turn, reply[start:start + CHUNK])
    end(turn)


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
    drop(turn["handler"], "before a reply longer than the session keeps")
    sentence = "长长的回复。"
    for n in range(600):
        say(turn, sentence[n % len(sentence)])
    end(turn)


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
           "说很多": flood, "跟不上": lagging}


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
