"""詩音 answering the ⌥Space window, for QuickAskTests.

A sentence that starts with 「小窗：」 gets 「收到：」 and the sentence back, streamed the way Hermes
streams a reply (message.start, message.delta chunks, message.complete with the whole text) but
a few characters at a time, slowly enough that the window can be seen filling in. The transcript
keeps both rows, as Hermes's does, so a fresh read of the chat finds the exchange. Stdlib only.
"""
import threading
import time

PREFIX = "小窗："
CHUNK = 3  # characters per message.delta
STEP = 0.6  # seconds between them


def handles(text):
    return text.startswith(PREFIX)


def answer(handler, log, lock, transcripts, session_id, text):
    """prompt.submit has been accepted: keep the turn, then stream it on a thread of its own."""
    reply = "收到：" + text
    with lock:
        rows = transcripts.setdefault(session_id, [])
        rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "user", "text": text,
                     "timestamp": time.time()})
        rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "assistant", "text": reply,
                     "timestamp": time.time()})
    threading.Thread(target=stream, args=(handler, log, session_id, reply), daemon=True).start()


def chunks(reply):
    return [reply[i:i + CHUNK] for i in range(0, len(reply), CHUNK)]


def stream(handler, log, session_id, reply):
    parts = chunks(reply)
    try:
        handler.event("message.start", session_id, {})
        for part in parts:
            time.sleep(STEP)
            handler.event("message.delta", session_id, {"text": part})
        handler.event("message.complete", session_id, {"text": reply, "status": "complete"})
        log(f"  -> quick reply on {session_id}: {len(parts)} chunks over {len(parts) * STEP:.1f}s")
    except OSError:
        pass
