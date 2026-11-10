"""詩音 answering the ⌥Space window, for QuickAskTests.

A sentence that starts with 「小窗：」 gets 「收到：」 and the sentence back, streamed the way Hermes
streams a reply (message.start, message.delta chunks, message.complete with the whole text) but
a few characters at a time, slowly enough that the window can be seen filling in. The one about
「明天几点出门」 stops after its first part until the test has seen it arrive and says so (POST
/ci/quick/finish, StandIn.swift), a minute at most. The transcript keeps both rows, as Hermes's
does, so a fresh read of the chat finds the exchange.

One with 「实验报告」 in it asks first, as a turn of Hermes's does when a tool needs you: an approval
(approval.request, shaped like gateway/session_pending_controls.py's), and once that is answered a
question with no choices, to be answered in words (clarify.request); the reply says what the
answer was. Stdlib only.
"""
import threading
import time

import fake_words

PREFIX = "小窗："
ASKS = "实验报告"
CHUNK = 3  # characters per message.delta
STEP = 0.6  # seconds between them
HOLDS = "明天几点出门"  # this reply waits after its first part for the test's word
HOLD_AT_MOST = 60  # seconds, should the word not come (a test that failed before saying it)
finished = threading.Event()  # the test's word: the reply that waits goes on
APPROVAL = {"kind": "approval", "prompt_id": "ap-quick", "execution_generation": 1,
            "command": "scp ~/Documents/实验报告.pdf course:uploads/",
            "description": "要把实验报告传到课程网站吗？", "choices": ["once", "deny", "session", "always"]}
QUESTION = {"kind": "clarify", "prompt_id": "cl-quick", "execution_generation": 1,
            "question": "交给哪位老师？", "choices": [], "multi_select": False}


def handles(text):
    return text.startswith(PREFIX)


def answer(handler, log, lock, transcripts, session_id, text):
    """prompt.submit has been accepted: keep the turn, then stream it on a thread of its own."""
    with lock:
        keep(transcripts, session_id, "user", fake_words.sent(text))
    if ASKS in text:
        threading.Thread(target=ask, args=(handler, log, session_id), daemon=True).start()
        return
    reply = "收到：" + text
    with lock:
        keep(transcripts, session_id, "assistant", reply)
    threading.Thread(target=stream, args=(handler, log, session_id, reply), kwargs={"hold": HOLDS in text},
                     daemon=True).start()


def responded(handler, log, lock, transcripts, params):
    """An approval or a question of the window's turn was answered and has settled: the turn goes
    on. False for every other prompt."""
    session_id, prompt_id = params.get("session_id"), params.get("prompt_id")
    if prompt_id == APPROVAL["prompt_id"]:
        if params.get("choice") == "deny":
            finish(handler, log, lock, transcripts, session_id, "好，先不交。")
        else:
            threading.Timer(0.8, raise_prompt, args=(handler, log, session_id, "clarify.request", QUESTION)).start()
        return True
    if prompt_id == QUESTION["prompt_id"]:
        words = str(params.get("answer", "")).strip()
        finish(handler, log, lock, transcripts, session_id, f"交给{words}了。" if words else "那我先放着，你定了再交。")
        return True
    return False


def keep(transcripts, session_id, role, text):
    rows = transcripts.setdefault(session_id, [])
    rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": role, "text": text,
                 "timestamp": time.time()})


def ask(handler, log, session_id):
    try:
        handler.event("message.start", session_id, {})
    except OSError:
        return
    time.sleep(1.0)
    raise_prompt(handler, log, session_id, "approval.request", APPROVAL)


def raise_prompt(handler, log, session_id, kind, prompt):
    log(f"  -> {kind} {prompt['prompt_id']} on {session_id}")
    try:
        handler.event(kind, session_id, prompt)
    except OSError:
        pass


def finish(handler, log, lock, transcripts, session_id, reply):
    """The rest of a turn that asked: its message.start went out before the asks."""
    with lock:
        keep(transcripts, session_id, "assistant", reply)
    threading.Thread(target=stream, args=(handler, log, session_id, reply, False), daemon=True).start()


def chunks(reply):
    return [reply[i:i + CHUNK] for i in range(0, len(reply), CHUNK)]


def finish_held(log):
    """POST /ci/quick/finish: the reply that waits goes on (or does not wait, if it has not got
    there yet). Whether one was waiting."""
    waiting = held_now.is_set()
    finished.set()
    log(f"POST /ci/quick/finish -> {'the reply goes on' if waiting else 'the reply will not wait'}")
    return waiting


held_now = threading.Event()  # a reply is waiting for the word


def stream(handler, log, session_id, reply, start=True, hold=False):
    parts = chunks(reply)
    try:
        if start:
            handler.event("message.start", session_id, {})
        for index, part in enumerate(parts):
            time.sleep(STEP)
            if hold and index == 1:
                log(f"  -> quick reply on {session_id} waits after its first part for the test's word")
                held_now.set()
                said = finished.wait(HOLD_AT_MOST)
                held_now.clear()
                finished.clear()
                if not said:
                    log(f"  -> no word in {HOLD_AT_MOST} s: the quick reply goes on")
            handler.event("message.delta", session_id, {"text": part})
        handler.event("message.complete", session_id, {"text": reply, "status": "complete"})
        log(f"  -> quick reply on {session_id}: {len(parts)} chunks over {len(parts) * STEP:.1f}s")
    except OSError:
        pass
