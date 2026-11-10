"""Passwords and keys an assistant asks for, for SecretsTests: Hermes's `sudo` and `secret`
server→client requests, as hermes-agent b3746e35 sends them (tui_gateway/contracts/
server_requests.py, gateway/session_server_requests.py, gateway/session_sudo_prompt.py,
gateway/session_secret_prompt.py).

A prompt with 「装 ffmpeg（CI）」 plays a turn whose two tool calls run at once, as Hermes runs
parallel tools: the terminal tool needs the sudo password for `sudo apt-get install -y ffmpeg`, and
the notion skill asks for NOTION_API_KEY. A prompt with 「会过期（CI）」 asks for a sudo password that
nobody gives in time. With 「断线（CI）」 the socket goes down right after the request goes out, as
a network drop does (no close frame), and the tunnel stays down a few seconds (fake_reconnect.py's
drop, DROP_OUTAGE): the card is seen waiting for the connection; then the window reconnects, finds
the request in session.resume's open_requests, and answers it on the new socket.

On the wire, as on Hermes:
  request   {"jsonrpc": "2.0", "id": "srq-<12 hex>", "method": "sudo", "params": {"session_id",
            "command"}}; a secret's params are {"session_id", "env_var", "prompt", "metadata":
            {"skill_name", "help"}}
  answer    a JSON-RPC response from the window: {"id", "result": {"value": …}}; "" (or an error
            response) declines. It gets no reply.
  withdrawn every window attached to the chat gets the event request.cancel {id, method, reason}:
            reason "resolved" once one answered, "timeout" once the wait is over (120 s on Hermes;
            LATE_WAIT here, so the test does not wait two minutes)
  resume    the requests still waiting come back as session.resume's open_requests

The sudo password is compared with PASSWORD, and a key would be "saved" (it is kept nowhere): the
log says that a value came and whether it was the one expected, never the value or its length.
Stdlib only.
"""
import json
import socket
import struct
import threading
import time

try:  # how the stand-in drops a socket and keeps the tunnel down (ReconnectTests' module)
    import fake_reconnect
except ImportError:
    fake_reconnect = None

INSTALL = "装 ffmpeg（CI）"
LATE = "会过期（CI）"
DROP = "断线（CI）"
# what SecretsTests types into the sudo card: checked here, never logged
PASSWORD = "ci-sudo-Pa55"
COMMAND = "sudo apt-get install -y ffmpeg"
LATE_COMMAND = "sudo systemctl restart hermes-ci"
DROP_COMMAND = "sudo apt-get install -y sox"
WAIT = 120.0  # Hermes's REQUEST_TIMEOUT_S
DROP_OUTAGE = 6.0  # seconds the tunnel stays down after 「断线（CI）」 drops the socket
LATE_WAIT = 8.0  # the one that expires: shorter than Hermes's, to keep the test short
# fixed ids, so the test can find each card (Hermes's are random: srq- and 12 hex digits)
SUDO_ID, KEY_ID, LATE_ID, DROP_ID = "srq-00000000c101", "srq-00000000c102", "srq-00000000c103", "srq-00000000c104"

lock = threading.Lock()
waiting = {}  # request id -> its entry while it waits for an answer
viewers = {}  # session id -> the socket that last attached the chat: where its frames go
answered = set()  # ids already answered once, to catch a second answer


def handles(text):
    return INSTALL in text or LATE in text or DROP in text


def note_viewer(session_id, handler):
    """session.resume / session.create attached `handler` to the chat: its frames go there now."""
    with lock:
        viewers[session_id] = handler


def open_for(session_id):
    """session.resume's open_requests: what still waits in this chat, as its frames carried it."""
    with lock:
        return [{"id": rid, "method": entry["method"], "params": dict(entry["params"])}
                for rid, entry in waiting.items() if entry["session_id"] == session_id]


def settles(frame):
    """A window's answer to one of our requests: a string srq- id, a result or an error, no method."""
    return (isinstance(frame, dict) and "method" not in frame and isinstance(frame.get("id"), str)
            and frame["id"].startswith("srq-") and ("result" in frame or "error" in frame))


def settle(log, frame):
    rid = frame["id"]
    with lock:
        entry = waiting.pop(rid, None)
        twice = entry is None and rid in answered
        answered.add(rid)
    if entry is None:
        # Hermes drops it as well: the wait is already over
        log(f"  <- answer to {rid}: no request waits for it" + (" — !! answered twice" if twice else ""))
        return
    result = frame.get("result") if "error" not in frame else None
    value = result.get("value") if isinstance(result, dict) else ""
    entry["value"] = value if isinstance(value, str) else ""
    if not entry["value"]:
        said = "declined (empty value)" if "error" not in frame else "declined (error response)"
    elif entry["method"] == "sudo":
        said = "a password came: " + ("the one SecretsTests types" if entry["value"] == PASSWORD else "NOT the expected one")
    else:
        said = f"a value came for {entry['params'].get('env_var')}: saved to the profile's .env (kept nowhere here)"
    log(f"  <- answer to {rid} ({entry['method']}): {said}; the value is not logged")
    entry["event"].set()


def answer(handler, log, lock_, transcripts, session_id, text):
    """prompt.submit has been accepted: keep the turn in the transcript, then play it."""
    with lock_:
        rows = transcripts.setdefault(session_id, [])
        rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "user", "text": text,
                     "timestamp": time.time()})
    note_viewer(session_id, handler)
    turn = install_turn if INSTALL in text else late_turn if LATE in text else drop_turn
    threading.Thread(target=turn, args=(log, lock_, transcripts, session_id), daemon=True).start()


# ---- the turns ---------------------------------------------------------------------------------

def event(log, session_id, kind, payload):
    with lock:
        viewer = viewers.get(session_id)
    if viewer is None:
        return
    try:
        viewer.event(kind, session_id, payload)
    except OSError:
        log(f"  (the window on {session_id} is gone: {kind} not delivered)")


def ask(log, session_id, rid, method, params, wait, then=None):
    """One request, as gateway/session_server_requests.py `_ask` sends it: the frame to the windows
    on the chat, a wait for the first answer, then request.cancel to all of them. The value, or None
    when the wait ran out. `then` runs once the frame is out."""
    entry = {"session_id": session_id, "method": method, "params": {"session_id": session_id, **params},
             "event": threading.Event(), "value": ""}
    with lock:
        waiting[rid] = entry
        viewer = viewers.get(session_id)
    what = params.get("env_var") or params.get("command")
    log(f"  -> {method} request {rid} on {session_id}: {what} (waits {wait:.0f}s)")
    try:
        viewer.send_json({"jsonrpc": "2.0", "id": rid, "method": method, "params": entry["params"]})
    except (AttributeError, OSError):
        log(f"  (no window on {session_id} for {rid})")
    if then is not None:
        then(viewer)
    got = entry["event"].wait(wait)
    with lock:
        still = waiting.pop(rid, None) is entry
    reason = "timeout" if still else "resolved"
    log(f"  -> request.cancel {rid}: {reason}")
    event(log, session_id, "request.cancel", {"id": rid, "method": method, "reason": reason})
    return entry["value"] if got and not still else None


def tool(log, session_id, call, name, context, args):
    event(log, session_id, "tool.start", {"tool_id": call, "name": name, "context": context, "args": args})


def done(log, lock_, transcripts, session_id, call, name, context, result):
    event(log, session_id, "tool.complete", {"tool_id": call, "name": name,
                                             "result": json.dumps(result, ensure_ascii=False)})
    with lock_:
        transcripts.setdefault(session_id, []).append(
            {"row_kind": "message", "role": "tool", "name": name, "context": context, "tool_call_id": call,
             "timestamp": time.time()})


def reply(log, lock_, transcripts, session_id, text):
    with lock_:
        rows = transcripts.setdefault(session_id, [])
        rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "assistant", "text": text,
                     "timestamp": time.time()})
    event(log, session_id, "message.delta", {"text": text})
    event(log, session_id, "message.complete", {"text": text, "status": "complete"})
    event(log, session_id, "session.info", {"running": False})


def install_turn(log, lock_, transcripts, session_id):
    """The terminal tool and the notion skill, at once; each blocks on its own request."""
    outcome = {}

    def sudo():
        call = "call-ci-sudo"
        tool(log, session_id, call, "terminal", COMMAND, {"command": COMMAND})
        value = ask(log, session_id, SUDO_ID, "sudo", {"command": COMMAND}, WAIT)
        ok = value == PASSWORD
        outcome["sudo"] = ok
        done(log, lock_, transcripts, session_id, call, "terminal", COMMAND,
             {"exit_code": 0, "output": "Setting up ffmpeg (CI) ..."} if ok else
             {"exit_code": 1, "output": "sudo: a password is required" if not value else "sudo: 1 incorrect password attempt"})

    def key():
        call = "call-ci-notion"
        tool(log, session_id, call, "skill_view", "notion", {"name": "notion"})
        value = ask(log, session_id, KEY_ID, "secret", {
            "env_var": "NOTION_API_KEY", "prompt": "Notion 的 internal integration token（CI）",
            "metadata": {"skill_name": "notion", "help": "https://www.notion.so/profile/integrations"}}, WAIT)
        outcome["key"] = bool(value)
        # what the model sees (tools/skills_tool_setup.py `_capture_result`): names, never the value
        done(log, lock_, transcripts, session_id, call, "skill_view", "notion",
             {"missing_names": [] if value else ["NOTION_API_KEY"], "setup_skipped": not value,
              "gateway_setup_hint": None})

    event(log, session_id, "session.info", {"running": True})
    event(log, session_id, "message.start", {})
    first = threading.Thread(target=sudo, daemon=True)
    first.start()
    # the second call starts a moment later, as parallel tool calls do
    time.sleep(0.4)
    second = threading.Thread(target=key, daemon=True)
    second.start()
    first.join()
    second.join()
    lines = ["ffmpeg 装好了（CI）。" if outcome.get("sudo") else "没拿到 sudo 密码，ffmpeg 没装上（CI）。",
             "Notion 接上了（CI）。" if outcome.get("key") else "没有 NOTION_API_KEY，先不存进 Notion（CI）。"]
    reply(log, lock_, transcripts, session_id, "\n\n".join(lines))
    log(f"  -> secrets turn on {session_id}: sudo {'ok' if outcome.get('sudo') else 'failed'}, "
        f"key {'given' if outcome.get('key') else 'declined'}")


def late_turn(log, lock_, transcripts, session_id):
    """A sudo password nobody gives: the request times out and the command fails."""
    call = "call-ci-late"
    event(log, session_id, "session.info", {"running": True})
    event(log, session_id, "message.start", {})
    tool(log, session_id, call, "terminal", LATE_COMMAND, {"command": LATE_COMMAND})
    value = ask(log, session_id, LATE_ID, "sudo", {"command": LATE_COMMAND}, LATE_WAIT)
    done(log, lock_, transcripts, session_id, call, "terminal", LATE_COMMAND,
         {"exit_code": 1, "output": "sudo: a password is required" if value is None else "(answered after all)"})
    reply(log, lock_, transcripts, session_id, "没等到 sudo 密码，没有重启（CI）。" if value is None else "重启好了（CI）。")


def hang_up(log, viewer):
    """The socket goes down as a network drop does: no close frame, and the tunnel down a few
    seconds (every request a 502), so the card is seen waiting before the window gets back."""
    if fake_reconnect is not None:
        return fake_reconnect.drop(viewer, "while a sudo password is asked for", outage=DROP_OUTAGE)
    log("  -> the socket goes down while the request waits")
    try:
        viewer.send_frame(8, struct.pack(">H", 1001))
        viewer.connection.shutdown(socket.SHUT_RDWR)
    except (AttributeError, OSError):
        pass


def drop_turn(log, lock_, transcripts, session_id):
    """A sudo password asked for just before the connection drops: the window comes back, finds the
    request in open_requests and answers it on its new socket."""
    call = "call-ci-drop"
    event(log, session_id, "session.info", {"running": True})
    event(log, session_id, "message.start", {})
    tool(log, session_id, call, "terminal", DROP_COMMAND, {"command": DROP_COMMAND})
    value = ask(log, session_id, DROP_ID, "sudo", {"command": DROP_COMMAND}, WAIT,
                then=lambda viewer: hang_up(log, viewer))
    ok = value == PASSWORD
    done(log, lock_, transcripts, session_id, call, "terminal", DROP_COMMAND,
         {"exit_code": 0, "output": "Setting up sox (CI) ..."} if ok else
         {"exit_code": 1, "output": "sudo: a password is required" if not value else "sudo: 1 incorrect password attempt"})
    reply(log, lock_, transcripts, session_id, "sox 装好了（CI）。" if ok else "没拿到 sudo 密码，sox 没装上（CI）。")
