"""Stop, retry and the server check, for the CI stand-in (fake_hermes.py): what ChatControlTests needs.

Shaped like Hermes main (2026-11-09):

- A turn's frames carry its `execution_generation` beside the payload (gateway/session_events.py:
  the claim's execution stamp), and a snapshot names the session's current generation and revision
  (CanonicalSnapshot). Each turn bumps the generation when it starts and the revision when it
  settles (hermes_state_runtime.claim / settle_session_input).
- When a turn ends, `session.info` says running, execution_generation and revision
  (session_authority._publish_pending: the only place a viewer learns the revision).
- `session.interrupt {session_id, execution_generation}` (CanonicalControlParams, a closed key set;
  `profile` only routes) refuses any other generation with stale_generation, and stops the turn:
  its `message.complete` has status "interrupted" (outcome "cancelled") and the partial text, and the
  partial is stored with display_metadata.interrupted (gateway/session_settlement_recovery.py
  completion_payload, agent/turn_api_call.py).
- `session.mutate` rewind {session_id, request_id, expected_revision, expected_generation,
  operation: "rewind", payload: {target_message_id}} (gateway/session_mutations.py,
  hermes_state_mutations.py): fenced by revision and generation (the refusal names the fresh ones),
  refused while a turn runs (session_busy), the target must be a user row still in the history; it
  takes that row and every later one back and answers the typed text in target_message.
- `message.complete.persisted_turn`: the rows the turn stored, `user_row_id` the prompt's, and
  `submission_id` the submitter's own id for it (agent/persisted_turn_receipt.py,
  gateway/session_settlement_recovery.py).
- A failed turn, as the session gateway ends one (completion_payload): status "error", outcome
  "failed", `text` Hermes's own copy of the failure (agent/turn_failure_copy.py exhausted_copy), and
  `error_surface` {layer, code, retryable, provider, model, provider_label} (agent/error_surface.py
  _surface); no `error` key (only the TUI gateway's frames have one). The transcript closes it with
  an assistant row: display_kind "failed_turn", the notice as its text, display_metadata {error,
  error_surface} (agent/conversation_loop.py _close_durable_failed_turn).

The scripted turns: 「讲一个长故事」 streams a sentence every 0.3 s for half a minute, so there is time
to stop it; 「出个错看看」 fails as a provider's rate limit does after its retries (its `text` ends with
Hermes's notice after a blank line, as gateway/run_turn.py adds it); 「查一下明天的天气」 calls one
tool (web_search) before it answers, so its retry has something that would run again. Once a
turn's row has been rewound, the same words get a different reply (the retry). Which profiles have the shion
plugin is fake_profiles.py's (詩音's only), so the server check has a failure to show.

For ComposeTests, as Hermes main (2026-11-12) has them:

- 「带个话再出错（CI）」 writes to another assistant (a `message_agent` call: tools/bot_mode_dm.py) and
  then fails as 「出个错看看」 does: the message went out, so its 重试 has something that would go
  out again.
- `session.steer` / `session.redirect` {session_id, text, execution_generation} (a closed key set;
  gateway/session_busy_controls.py correct): a message put into the turn that is running. Another
  generation is refused (stale_generation); with no turn running the answer is `rejected` with
  `delivered: false`, which a client may send as a prompt instead; taken, it is `queued`
  (`redirected` for a redirect), the words are stored as a user row of kind `steer`
  (tui_gateway/session_history.py shows such a row as your own words), and the story being told
  says it heard them and ends there.
"""
import itertools
import threading
import time

import fake_words

STORY = "讲一个长故事"
STORY_PARTS = ["从前有一座山，", "山里有座庙，", "庙里有个老和尚，", "在给小和尚讲故事。"] * 25
RETRIED = "（重试）故事讲完了：山里有座庙。"
FAIL = "出个错看看"
FAIL_RETRIED = "（重试）这次没出错。"
PROVIDER_SAID = "429 Too Many Requests: rate limit exceeded"
# exhausted_copy("rate_limit", label="OpenRouter", attempts=3, summary=PROVIDER_SAID)
FAIL_COPY = ("OpenRouter rate-limited every one of 3 attempts — it looks temporarily unavailable. Wait a minute "
             "and send /retry, or switch models with /model. To avoid this in future, add a backup provider "
             f"with `hermes fallback add`.\n\nProvider said: {PROVIDER_SAID}")
FAILED_TURN_NOTICE = "Your request was not processed. Send it again if you still want me to carry it out."
FAIL_SURFACE = {"layer": "provider", "code": "rate_limit", "retryable": True, "provider": "openrouter",
                "model": "anthropic/claude-sonnet-4.5", "provider_label": "OpenRouter"}
TOOLED = "查一下明天的天气"
TOOLED_CALL = ("web_search", "明天 吉祥寺 天气")
TOOLED_REPLY = "明天晴，最高 18 度。"
TOOLED_RETRIED = "（重试）明天晴，最高 18 度，傍晚起风。"
PEER_FAIL = "带个话再出错（CI）"
PEER_CALL = {"target": "study", "message": "把第 8 回的课件发我一份（CI）。"}
CORRECTIONS = {"session.steer": "queued", "session.redirect": "redirected"}
MUTATE_KEYS = {"session_id", "request_id", "expected_revision", "operation", "payload"}

state = {"log": print, "transcripts": None, "lock": threading.Lock()}
fences = {}  # session id -> {"generation", "revision"}
running = {}  # session id -> the turn under way: {"generation", "stop", "user_row"}
receipts = {}  # request id -> the mutation's answer (an exact retry gets it again)
rewound = set()  # the words of prompts whose turn was rewound: their next run is the short one
row_ids = itertools.count(5000)


def setup(log, transcripts, lock):
    state.update(log=log, transcripts=transcripts, lock=lock)


def fence(session_id):
    return fences.setdefault(session_id, {"generation": 1, "revision": 1})


def snapshot_fences(session_id):
    """What session.resume and session.create add to their snapshot."""
    current = fence(session_id)
    return {"execution_generation": current["generation"], "revision": current["revision"]}


def handles(method, params):
    if method in ("session.interrupt", "session.mutate") or method in CORRECTIONS:
        return True
    text = str(params.get("text", ""))
    return method == "prompt.submit" and any(words in text for words in (STORY, FAIL, TOOLED, PEER_FAIL))


def handle(conn, method, params, rid):
    if method == "session.interrupt":
        return interrupt(conn, params, rid)
    if method == "session.mutate":
        return mutate(conn, params, rid)
    if method in CORRECTIONS:
        return correct(conn, method, params, rid)
    if FAIL in str(params.get("text", "")) or PEER_FAIL in str(params.get("text", "")):
        return fail(conn, params, rid)
    if TOOLED in str(params.get("text", "")):
        return tooled(conn, params, rid)
    return story(conn, params, rid)


def refuse(conn, rid, reason, **data):
    state["log"](f"    refused: {reason} {data}")
    conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {
        "code": 4001, "message": reason, "data": {"reason": reason, **data}}})


def event(conn, kind, session_id, payload, generation=None):
    params = {"type": kind, "session_id": session_id, "payload": payload}
    if generation is not None:
        params["execution_generation"] = generation
    conn.send_json({"jsonrpc": "2.0", "method": "event", "params": params})


def idle_info(conn, session_id):
    current = fence(session_id)
    event(conn, "session.info", session_id, {
        "running": False, "execution_generation": current["generation"], "revision": current["revision"],
        "pending": [], "stored_session_id": session_id})


# ---- session.interrupt ------------------------------------------------------------------------

def interrupt(conn, params, rid):
    args = {k: v for k, v in params.items() if k != "profile"}
    missing = sorted({"session_id", "execution_generation"} - set(args))
    unknown = sorted(set(args) - {"session_id", "execution_generation"})
    if missing or unknown:
        return refuse(conn, rid, "invalid_params", fields=missing + unknown)
    session_id, generation = args["session_id"], args["execution_generation"]
    current = fence(session_id)
    if type(generation) is not int or generation != current["generation"]:
        return refuse(conn, rid, "stale_generation")
    turn = running.get(session_id)
    state["log"](f"    interrupt generation {generation}: {'stopping the turn' if turn else 'nothing running'}")
    if turn is not None:
        turn["stop"].set()
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": {
        "ref": {"profile_id": params.get("profile", "shion"), "session_id": session_id},
        "instance_id": "ci", "authority_epoch": 1, "revision": current["revision"],
        "execution_generation": current["generation"], "execution_state": "running" if turn else "idle"}})


# ---- session.steer, session.redirect ---------------------------------------------------------

def correct(conn, method, params, rid):
    args = {k: v for k, v in params.items() if k != "profile"}
    wanted = {"session_id", "text", "execution_generation"}
    if set(args) != wanted or not isinstance(args.get("text"), str) or not args["text"].strip():
        return refuse(conn, rid, "invalid_params", fields=sorted(set(args) ^ wanted))
    session_id, text, generation = args["session_id"], args["text"], args["execution_generation"]
    current = fence(session_id)
    if type(generation) is not int or generation != current["generation"]:
        return refuse(conn, rid, "stale_generation")
    answer = {"text": text, "execution_generation": generation, "authority_epoch": 1}
    with state["lock"]:
        turn = running.get(session_id)
        if turn is not None:
            state["transcripts"].setdefault(session_id, []).append(
                {"row_id": next(row_ids), "row_kind": "message", "role": "user", "text": text,
                 "display_kind": "steer", "timestamp": time.time()})
            turn["heard"] = text
    if turn is None:
        state["log"](f"    {method}: nothing running, not delivered")
        answer.update(status="rejected", delivered=False)
    else:
        state["log"](f"    {method} into generation {generation}: {text!r}")
        answer["status"] = CORRECTIONS[method]
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": answer})


# ---- the scripted turn ------------------------------------------------------------------------

def story(conn, params, rid):
    session_id, text = params.get("session_id"), params.get("text", "")
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": {"status": "queued", "admission_id": f"adm-{rid}"}})
    with state["lock"]:
        current = fence(session_id)
        current["generation"] += 1
        user_row = next(row_ids)
        state["transcripts"].setdefault(session_id, []).append(
            {"row_id": user_row, "row_kind": "message", "role": "user", "text": fake_words.sent(text),
             "timestamp": time.time()})
        turn = {"generation": current["generation"], "stop": threading.Event(), "user_row": user_row,
                "submission": params.get("submission_id")}
        running[session_id] = turn
        short = text in rewound
    threading.Thread(target=run_story, args=(conn, session_id, turn, short), daemon=True).start()


def run_story(conn, session_id, turn, short):
    log, generation = state["log"], turn["generation"]
    said = ""
    try:
        event(conn, "session.info", session_id, {"running": True, "execution_generation": generation}, generation)
        event(conn, "message.start", session_id, {}, generation)
        for part in ([RETRIED] if short else STORY_PARTS):
            if turn["stop"].wait(0.3):
                break
            if turn.get("heard"):
                # a message came into the turn (session.steer): the story says so and ends here
                part = f"（听到了：{turn['heard']}）故事先讲到这里。"
            said += part
            event(conn, "message.delta", session_id, {"text": part}, generation)
            if turn.get("heard"):
                break
        stopped = turn["stop"].is_set()
        assistant_row = next(row_ids)
        with state["lock"]:
            row = {"row_id": assistant_row, "row_kind": "message", "role": "assistant", "text": said,
                   "timestamp": time.time()}
            if stopped:
                row["display_metadata"] = {"interrupted": True}
            state["transcripts"].setdefault(session_id, []).append(row)
            running.pop(session_id, None)
            fence(session_id)["revision"] += 1
        log(f"  -> story turn on {session_id}: {'stopped after ' + str(len(said)) + ' characters' if stopped else 'done'}")
        complete = {"text": said, "content": said, "admission_id": f"adm-{generation}",
                    "outcome": "cancelled" if stopped else "completed",
                    "status": "interrupted" if stopped else "complete",
                    "persisted_turn": {"row_ids": [turn["user_row"], assistant_row], "complete": not stopped,
                                       "user_row_id": turn["user_row"], "user_row_ids": [turn["user_row"]],
                                       "submission_id": turn["submission"]}}
        if not stopped:
            complete["persisted_turn"]["final_assistant_row_id"] = assistant_row
        event(conn, "message.complete", session_id, complete, generation)
        idle_info(conn, session_id)
    except OSError:
        running.pop(session_id, None)


def fail(conn, params, rid):
    session_id, text = params.get("session_id"), params.get("text", "")
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": {"status": "queued", "admission_id": f"adm-{rid}"}})
    with state["lock"]:
        current = fence(session_id)
        current["generation"] += 1
        user_row = next(row_ids)
        state["transcripts"].setdefault(session_id, []).append(
            {"row_id": user_row, "row_kind": "message", "role": "user", "text": fake_words.sent(text),
             "timestamp": time.time()})
        turn = {"generation": current["generation"], "stop": threading.Event(), "user_row": user_row,
                "submission": params.get("submission_id"), "peer": PEER_FAIL in text}
        running[session_id] = turn
        retried = text in rewound
    threading.Thread(target=run_fail, args=(conn, session_id, turn, retried), daemon=True).start()


def run_fail(conn, session_id, turn, retried):
    """The provider's rate limit after its retries; asked again once rewound, a plain reply."""
    generation = turn["generation"]
    try:
        event(conn, "session.info", session_id, {"running": True, "execution_generation": generation}, generation)
        if retried:
            event(conn, "message.start", session_id, {}, generation)
            time.sleep(0.3)
            event(conn, "message.delta", session_id, {"text": FAIL_RETRIED}, generation)
        else:
            if turn.get("peer"):
                # the message to the other assistant goes out before the turn fails: a tool call in
                # the turn, and a tool row in the transcript, with what it was called with
                call = f"call-ci-peer-{generation}"
                event(conn, "message.start", session_id, {}, generation)
                event(conn, "tool.start", session_id, {"tool_id": call, "name": "message_agent", "args": PEER_CALL},
                      generation)
                event(conn, "tool.complete", session_id, {"tool_id": call, "name": "message_agent"}, generation)
                with state["lock"]:
                    state["transcripts"].setdefault(session_id, []).append(
                        {"row_kind": "message", "role": "tool", "name": "message_agent", "args": PEER_CALL,
                         "tool_call_id": call, "context": "study", "timestamp": time.time()})
            time.sleep(1)
        answer = next(row_ids)
        with state["lock"]:
            row = {"row_id": answer, "row_kind": "message", "role": "assistant", "timestamp": time.time()}
            if retried:
                row["text"] = FAIL_RETRIED
            else:
                row.update(text=FAILED_TURN_NOTICE, display_kind="failed_turn",
                           display_metadata={"error": PROVIDER_SAID, "error_surface": FAIL_SURFACE})
            state["transcripts"].setdefault(session_id, []).append(row)
            running.pop(session_id, None)
            fence(session_id)["revision"] += 1
        state["log"](f"  -> {'retried turn done' if retried else 'turn failed: rate limit'} on {session_id}")
        turned = {"row_ids": [turn["user_row"], answer], "complete": retried, "user_row_id": turn["user_row"],
                  "user_row_ids": [turn["user_row"]], "submission_id": turn["submission"]}
        if retried:
            complete = {"text": FAIL_RETRIED, "content": FAIL_RETRIED, "outcome": "completed", "status": "complete"}
            turned["final_assistant_row_id"] = answer
        else:
            said = f"{FAIL_COPY}\n\n{FAILED_TURN_NOTICE}"
            complete = {"text": said, "content": said, "outcome": "failed", "status": "error",
                        "error_surface": FAIL_SURFACE}
        complete.update(admission_id=f"adm-{generation}", persisted_turn=turned)
        event(conn, "message.complete", session_id, complete, generation)
        idle_info(conn, session_id)
    except OSError:
        running.pop(session_id, None)


def tooled(conn, params, rid):
    session_id, text = params.get("session_id"), params.get("text", "")
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": {"status": "queued", "admission_id": f"adm-{rid}"}})
    with state["lock"]:
        current = fence(session_id)
        current["generation"] += 1
        user_row = next(row_ids)
        state["transcripts"].setdefault(session_id, []).append(
            {"row_id": user_row, "row_kind": "message", "role": "user", "text": fake_words.sent(text),
             "timestamp": time.time()})
        turn = {"generation": current["generation"], "stop": threading.Event(), "user_row": user_row,
                "submission": params.get("submission_id")}
        running[session_id] = turn
        retried = text in rewound
    threading.Thread(target=run_tooled, args=(conn, session_id, turn, retried), daemon=True).start()


def run_tooled(conn, session_id, turn, retried):
    """詩音 looks the weather up (one web_search), then answers; once rewound, the same again."""
    generation = turn["generation"]
    name, context = TOOLED_CALL
    call = f"call-ci-weather-{generation}"
    reply = TOOLED_RETRIED if retried else TOOLED_REPLY
    try:
        event(conn, "session.info", session_id, {"running": True, "execution_generation": generation}, generation)
        event(conn, "message.start", session_id, {}, generation)
        time.sleep(0.3)
        event(conn, "tool.start", session_id, {"tool_id": call, "name": name, "context": context,
                                               "args": {"query": context}}, generation)
        time.sleep(0.3)
        event(conn, "tool.complete", session_id, {"tool_id": call, "name": name, "result": "{\"ok\": true}"},
              generation)
        time.sleep(0.3)
        event(conn, "message.delta", session_id, {"text": reply}, generation)
        answer = next(row_ids)
        with state["lock"]:
            rows = state["transcripts"].setdefault(session_id, [])
            rows.append({"row_kind": "message", "role": "tool", "name": name, "context": context,
                         "tool_call_id": call, "timestamp": time.time()})
            rows.append({"row_id": answer, "row_kind": "message", "role": "assistant", "text": reply,
                         "timestamp": time.time()})
            running.pop(session_id, None)
            fence(session_id)["revision"] += 1
        state["log"](f"  -> weather turn on {session_id}: a {name} call, {'again after a rewind' if retried else 'first time'}")
        event(conn, "message.complete", session_id, {
            "text": reply, "content": reply, "outcome": "completed", "status": "complete",
            "admission_id": f"adm-{generation}",
            "persisted_turn": {"row_ids": [turn["user_row"], answer], "complete": True,
                               "user_row_id": turn["user_row"], "user_row_ids": [turn["user_row"]],
                               "final_assistant_row_id": answer, "submission_id": turn["submission"]}}, generation)
        idle_info(conn, session_id)
    except OSError:
        running.pop(session_id, None)


# ---- session.mutate rewind --------------------------------------------------------------------

def mutate(conn, params, rid):
    args = {k: v for k, v in params.items() if k != "profile"}
    if set(args) - {"expected_generation"} != MUTATE_KEYS:
        fields = sorted((MUTATE_KEYS - set(args)) | (set(args) - MUTATE_KEYS - {"expected_generation"}))
        return refuse(conn, rid, "invalid_params", fields=fields)
    session_id, payload = args["session_id"], args["payload"]
    if args["request_id"] in receipts:
        state["log"]("    exact retry: the same receipt")
        return conn.send_json({"jsonrpc": "2.0", "id": rid, "result": receipts[args["request_id"]]})
    if (args["operation"] != "rewind" or not isinstance(payload, dict)
            or set(payload) - {"target_message_id", "preserve_compaction_handoff"}
            or type(payload.get("target_message_id")) is not int or payload["target_message_id"] <= 0):
        return refuse(conn, rid, "invalid_params")
    if args.get("expected_generation") is None:
        return refuse(conn, rid, "invalid_params", field="expected_generation")
    with state["lock"]:
        current = fence(session_id)
        fresh = {"revision": current["revision"], "execution_generation": current["generation"]}
        if args["expected_revision"] != current["revision"]:
            conflict = "revision_conflict"
        elif args["expected_generation"] != current["generation"]:
            conflict = "stale_generation"
        else:
            conflict = None
        if conflict:
            return refuse(conn, rid, conflict, **fresh)
        if session_id in running:
            return refuse(conn, rid, "session_busy")
        rows = state["transcripts"].setdefault(session_id, [])
        target = payload["target_message_id"]
        index = next((i for i, row in enumerate(rows) if row.get("row_id") == target), None)
        if index is None or rows[index].get("role") != "user":
            return refuse(conn, rid, "invalid_params", field="target_message_id",
                          detail="target user message is no longer in session history")
        taken = rows[index:]
        del rows[index:]
        rewound.add(taken[0]["text"])
        current["revision"] += 1
        current["generation"] += 1
        head = next((row.get("row_id") for row in reversed(rows) if row.get("row_id")), None)
        result = {"session_id": session_id, "operation": "rewind", "revision": current["revision"],
                  "execution_generation": current["generation"], "rewound_count": len(taken),
                  "target_message": {"id": target, "role": "user", "content": taken[0]["text"],
                                     "timestamp": taken[0].get("timestamp")},
                  "new_head_id": head, "replacement_message_id": None}
        receipts[args["request_id"]] = result
    state["log"](f"    rewound {len(taken)} rows from row {target}: {taken[0]['text']!r}")
    conn.send_json({"jsonrpc": "2.0", "id": rid, "result": result})
    event(conn, "session.updated", session_id, {"session_id": session_id, "operation": "rewind",
                                                "revision": current["revision"]})
