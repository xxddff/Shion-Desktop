"""What ExtrasTests needs from the stand-in (fake_hermes.py): notifications to click, and the
Shortcuts actions' sentences. Shaped like Hermes and the shion plugin:

  prompt.submit "通知：讲长一点"   a few seconds later, 詩音 replies at length (thirty paragraphs, so
                                  the reply is taller than the window), and message.complete
                                  carries `persisted_turn` as Hermes's does
                                  (agent/persisted_turn_receipt.py): the rows the turn was stored
                                  as, `final_assistant_row_id` among them. The transcript keeps the
                                  rows under those ids, so a fresh read finds the reply again.
  prompt.submit "通知：问我"       詩音 asks a question (clarify.request); "通知：要批准", she asks
                                  for an approval (approval.request). Each stays pending until it
                                  is answered, and session.resume's `prompts` brings it back to a
                                  client that attaches again, as Hermes's snapshot does
                                  (gateway/session_pending_controls.py).
  prompt.submit "通知：写日报"     课程 writes today's life report through the plugin: yesterday's
                                  moves to the archive (reports.get still finds it, as the plugin
                                  keeps every day), and the revision bumps and is pushed. The Mac's
                                  usage of yesterday arrives with it (as an upload stores it), for
                                  the screen time under yesterday's report: Notion, Safari twice
                                  over itself, LINE, Spotify, and Steam across Tokyo's midnight.
  prompt.submit "捷径慢：…"        the reply comes after eight seconds, longer than a Shortcuts
                                  action waits for it in the test run.

Everything else is fake_hermes.py's. Stdlib only.
"""
import threading
import time

import fake_shion

PARAGRAPHS = 30
LONG_FIRST = "（CI 长回复）第 1 段：这是一条很长的回复，点通知时要从这里开始看。"
QUESTION = {"prompt_id": "cl-ci-dinner", "execution_generation": 1, "kind": "clarify",
            "question": "晚饭想在家吃还是出去吃？（CI）", "choices": [], "multi_select": False}
APPROVAL = {"prompt_id": "ap-ci-print", "execution_generation": 1, "kind": "approval",
            "command": "lpr 作业4.pdf", "description": "要打印作业4吗？（CI）", "choices": ["once", "deny"]}
SLOW = "捷径慢："
SLOW_DELAY = 8.0

lock = threading.Lock()
pending = {}  # session id -> prompts raised and not answered yet
archive = {}  # (date, kind) -> a report no longer the newest of its kind
state = {"row": 5000}


def handles(text):
    return text.startswith("通知：") or text.startswith(SLOW)


def next_row():
    with lock:
        state["row"] += 1
        return state["row"]


def answer(handler, log, transcripts_lock, transcripts, session_id, text, submission_id):
    """prompt.submit has been accepted: one of the turns above."""
    if text.startswith(SLOW):
        return threading.Thread(target=slow, args=(handler, log, transcripts_lock, transcripts, session_id, text),
                                daemon=True).start()
    if "讲长一点" in text:
        return threading.Thread(target=long_reply, daemon=True,
                                args=(handler, log, transcripts_lock, transcripts, session_id, text, submission_id)).start()
    if "问我" in text:
        return ask(handler, log, transcripts_lock, transcripts, session_id, text, QUESTION, "clarify.request")
    if "要批准" in text:
        return ask(handler, log, transcripts_lock, transcripts, session_id, text, APPROVAL, "approval.request")
    if "写日报" in text:
        return write_report(handler, log, transcripts_lock, transcripts, session_id, text)
    reply(handler, transcripts_lock, transcripts, session_id, text, "（CI）不认识这句：" + text)


def keep(transcripts_lock, transcripts, session_id, text, reply_text):
    """Both rows of the turn in the transcript; returns their row ids."""
    user, assistant = next_row(), next_row()
    now = time.time()
    with transcripts_lock:
        rows = transcripts.setdefault(session_id, [])
        rows.append({"row_id": user, "row_kind": "message", "role": "user", "text": text, "timestamp": now})
        rows.append({"row_id": assistant, "row_kind": "message", "role": "assistant", "text": reply_text,
                     "timestamp": now})
    return user, assistant


def reply(handler, transcripts_lock, transcripts, session_id, text, reply_text, submission_id=None):
    user, assistant = keep(transcripts_lock, transcripts, session_id, text, reply_text)
    receipt = {"row_ids": [user, assistant], "complete": True, "user_row_id": user,
               "final_assistant_row_id": assistant, "user_row_ids": [user]}
    if submission_id:
        receipt["submission_id"] = submission_id
    handler.event("message.start", session_id, {})
    handler.event("message.delta", session_id, {"text": reply_text})
    handler.event("message.complete", session_id, {"text": reply_text, "status": "complete",
                                                   "persisted_turn": receipt})
    return assistant


def long_reply(handler, log, transcripts_lock, transcripts, session_id, text, submission_id):
    time.sleep(4.0)
    parts = [LONG_FIRST] + [f"（CI 长回复）第 {n} 段：一段接一段，撑得比窗口还高。" for n in range(2, PARAGRAPHS + 1)]
    try:
        row = reply(handler, transcripts_lock, transcripts, session_id, text, "\n\n".join(parts), submission_id)
        log(f"  -> long reply on {session_id}: {PARAGRAPHS} paragraphs, final_assistant_row_id {row}")
    except OSError:
        pass


def slow(handler, log, transcripts_lock, transcripts, session_id, text):
    time.sleep(SLOW_DELAY)
    try:
        reply(handler, transcripts_lock, transcripts, session_id, text, "（CI）慢慢回：" + text[len(SLOW):])
        log(f"  -> slow reply on {session_id} after {SLOW_DELAY:.0f}s")
    except OSError:
        pass


def ask(handler, log, transcripts_lock, transcripts, session_id, text, prompt, kind):
    with transcripts_lock:
        transcripts.setdefault(session_id, []).append(
            {"row_id": next_row(), "row_kind": "message", "role": "user", "text": text, "timestamp": time.time()})
    with lock:
        pending.setdefault(session_id, []).append(prompt)
    log(f"  -> {kind} {prompt['prompt_id']} on {session_id}")
    handler.event("message.start", session_id, {})
    handler.event("session.info", session_id, {"running": True})
    handler.event(kind, session_id, prompt)


def answered(session_id, prompt_id):
    """clarify.respond / approval.respond: it is no longer pending."""
    with lock:
        if session_id in pending:
            pending[session_id] = [p for p in pending[session_id] if p["prompt_id"] != prompt_id]


def on_resume(session_id, result):
    """session.resume's snapshot: the prompts still waiting, as Hermes sends them, once each
    (fake_reconnect.py lists the ones it saw published too)."""
    with lock:
        waiting = list(pending.get(session_id, []))
    if waiting:
        listed = list(result.get("prompts") or [])
        seen = {prompt.get("prompt_id") for prompt in listed}
        result["prompts"] = listed + [prompt for prompt in waiting if prompt["prompt_id"] not in seen]
        result["running"] = True


# yesterday in Tokyo: (bundle id, app name, start, end) as hours and minutes from that midnight
YESTERDAY_USAGE = [
    ("notion.id", "Notion", (9, 0), (10, 30)),
    ("jp.naver.line.mac", "LINE", (12, 0), (12, 20)),
    ("com.apple.Safari", "Safari", (20, 0), (21, 0)),
    ("com.apple.Safari", "Safari", (20, 30), (20, 45)),
    ("com.spotify.client", "Spotify", (21, 0), (21, 15)),
    ("com.valvesoftware.steam", "Steam", (23, 50), (24, 20)),
]


def seed_usage():
    """Yesterday's segments, stored as usage.upload stores them (UTC, by device, app and start)."""
    day = fake_shion.today() - fake_shion.timedelta(days=1)
    midnight = fake_shion.datetime(day.year, day.month, day.day, tzinfo=fake_shion.TOKYO)

    def moment(hm):
        return (midnight + fake_shion.timedelta(hours=hm[0], minutes=hm[1])).astimezone(fake_shion.timezone.utc)

    for bundle, name, start, end in YESTERDAY_USAGE:
        fake_shion.usage[("mac", bundle, moment(start))] = {
            "bundle_id": bundle, "app_name": name, "start": moment(start), "end": moment(end)}


def write_report(handler, log, transcripts_lock, transcripts, session_id, text):
    reply(handler, transcripts_lock, transcripts, session_id, text, "（CI）让课程写好了。")
    today = str(fake_shion.today())
    with fake_shion.lock:
        seed_usage()
        old = fake_shion.reports.get("life")
        if old and old["date"] != today:
            archive[(old["date"], old["kind"])] = old
        fake_shion.reports["life"] = {
            "id": f"{today}-life", "date": today, "kind": "life", "headline": "CI 今天的日报：早睡了一小时",
            "author": "study", "created_at": fake_shion.iso(fake_shion.datetime.now(fake_shion.TOKYO)),
            "updated_at": fake_shion.iso(fake_shion.datetime.now(fake_shion.TOKYO)),
            "blocks": [{"heading": "睡眠", "items": ["比昨天早睡一小时（CI）"]}]}
        fake_shion.bump()
    log(f"  课程 wrote today's life report; archived {sorted(archive)}; yesterday's usage is in")
    fake_shion.push(handler, log, ["reports", "usage"])


def handles_rpc(method, params):
    """A report of the archive: the plugin still has every day's."""
    return method == "plugin.shion.reports.get" and (params.get("date"), params.get("kind")) in archive


def rpc(handler, log, method, params, rid):
    report = archive[(params.get("date"), params.get("kind"))]
    log(f"    plugin reports.get {params.get('date')} {params.get('kind')} (archive)")
    handler.send_json({"jsonrpc": "2.0", "id": rid, "result": {"report": report}})
