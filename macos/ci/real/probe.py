"""The turns only a model can start, against Hermes itself with a stand-in model (mock_model.py).
Runs inside the container (inside.sh), beside a gateway that serves three Bot Mode profiles.

  python probe.py plain <capture.json>        one ordinary turn in a Bot Chat
  python probe.py peer <capture.json>         詩音 messages 课程 (message_agent): 课程's Bot Chat gets a turn
                                              Hermes starts, 詩音's gets the answer as a background result;
                                              then once more with 课程's viewer away
  python probe.py peer2 <capture.json>        a message that wants no answer, one nobody answers, one to two
  python probe.py background <capture.json>   a command left running in the background, told to notify
  python probe.py gap <capture.json>          a viewer that stops reading while a very long reply streams,
                                              until Hermes ends its subscription (session.replay_gap)
  python probe.py behind <capture.json>       a session read again (session.resume) while a turn runs, its
                                              answer held after Hermes took the snapshot (hold_gateway.py)
                                              until the turn has ended: the end reaches the viewer first
  python probe.py compact <capture.json>      「继续」 put into a turn while its command runs (stored as a
                                              row of its own), then the session compacted (session.mutate
                                              compress), twice: in place, and into a new session (通勤's
                                              config says compression.in_place false). The newest page and
                                              the store's rows before and after each; the pages also go to
                                              compaction.json beside the capture, for ../logic/send

Each prints what a viewer gets, frame by frame, and writes it as JSON for the Mac's own code to be
run over (read_notices.sh, read_behind.sh, ../logic/send)."""
import json
import os
import socket
import sqlite3
import subprocess
import sys
import time
import uuid
from urllib.parse import urlparse

from websockets.sync.client import connect

T0 = time.monotonic()
STAGE, OUT = sys.argv[1], sys.argv[2]
HERMES = [sys.executable, "-m", "hermes_cli.main"]


def say(*words):
    print(f"[{time.monotonic() - T0:6.1f}s]", *words, flush=True)


def short(value, limit=320):
    text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return text if len(text) <= limit else text[:limit] + f"… (+{len(text) - limit})"


class Socket:
    """One connection, as a viewer's: every session frame is kept in the order it came."""

    def __init__(self, name, quiet=False, small_buffer=False, profile=None):
        # a ticket is for one profile: another profile's sessions are refused on it (profile_mismatch)
        found = json.loads(subprocess.run(HERMES + (["-p", profile] if profile else []) + ["gateway", "attach", "--json"],
                                          capture_output=True, text=True, cwd="/opt/hermes").stdout.strip().splitlines()[-1])
        more = {}
        if small_buffer:
            # a viewer that cannot keep up: the kernel holds little for it, so what it does not read backs up in Hermes
            url = urlparse(found["url"])
            raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            raw.connect((url.hostname, url.port))
            more["sock"] = raw
        self.ws = connect(found["url"], subprotocols=found["protocols"], open_timeout=15, max_size=None, **more)
        self.name, self.frames, self.n, self.quiet = name, [], 0, quiet
        # a request's answer, and how many session frames had come when it did
        self.answers, self.answered_at = {}, {}
        self.call("client.capabilities", {"server_requests": True}, quiet=True)

    def read(self, timeout):
        try:
            frame = json.loads(self.ws.recv(timeout=timeout))
        except TimeoutError:
            return None
        if "id" in frame and "method" not in frame:
            self.answers[frame["id"]] = frame
            self.answered_at[frame["id"]] = len(self.frames)
        if frame.get("method") == "event":
            params = frame.get("params") or {}
            if params.get("session_id"):
                self.frames.append(params)
                kind = params.get("type")
                if not self.quiet and kind != "message.delta":
                    say(f"  {self.name} event", kind, "seq", params.get("seq"), short(params.get("payload"), 420))
        return frame

    def begin(self, method, params):
        """Sends a request and does not wait: its answer is in `answers` once it was read."""
        self.n += 1
        rid = f"{self.name}{self.n}"
        self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
        return rid

    def call(self, method, params, quiet=False, timeout=30.0):
        rid = self.begin(method, params)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            frame = self.read(max(0.05, deadline - time.monotonic()))
            if frame is not None and frame.get("id") == rid and "method" not in frame:
                if not quiet:
                    say(f"{self.name} {method} ->", "ERROR " + short(frame["error"]) if "error" in frame
                        else "ok " + short(frame.get("result"), 420))
                return frame.get("result") if "result" in frame else {"error": frame.get("error")}
        say(f"{self.name} {method} -> no answer")
        return {}

    def listen(self, seconds, until=None, after=0, count=1):
        """Reads for `seconds`, or until `count` frames of type `until` came among those after index `after`."""
        def enough():
            return until and sum(1 for f in self.frames[after:] if f.get("type") == until) >= count
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if enough():
                return True
            self.read(max(0.05, min(1.0, deadline - time.monotonic())))
        return bool(enough())

    def close(self):
        self.ws.close()


def bot_chat(viewer, profile):
    """A profile's Bot Chat as Shion makes and attaches it."""
    made = viewer.call("session.create", {"profile": profile, "title": "Bot Chat", "hidden": True,
                                          "follow_profile_config": True, "request_id": str(uuid.uuid4()).upper(),
                                          "source": "gui"}, quiet=True)
    session = made.get("session_id")
    if not session:
        say("no session for", profile, short(made))
        raise SystemExit(1)
    viewer.call("session.resume", {"profile": profile, "session_id": session, "omit_messages": True}, quiet=True)
    say(f"{viewer.name}: Bot Chat of {profile}: {session}")
    return session


def rows_of(viewer, profile, session, limit=14, quiet=False):
    page = viewer.call("session.transcript", {"profile": profile, "session_id": session, "order": "latest", "limit": limit},
                       quiet=True)
    for row in [] if quiet else page.get("rows") or []:
        say("   row", short({k: row.get(k) for k in ("row_id", "row_kind", "role", "display_kind", "display_metadata",
                                                      "timestamp", "tool_name")}, 400),
            "text", short((row.get("text") or row.get("content") or "")[:700], 760))
    return page


def ask(viewer, profile, session, text):
    return viewer.call("prompt.submit", {"profile": profile, "session_id": session, "text": text,
                                         "submission_id": str(uuid.uuid4()).upper()})


def cursor_of(viewer, session):
    mine = [f for f in viewer.frames if f.get("session_id") == session and f.get("seq")]
    return (mine[-1].get("seq"), mine[-1].get("replay_epoch")) if mine else (0, None)


capture = {"stage": STAGE}

if STAGE == "plain":
    a = Socket("a")
    chat = bot_chat(a, "default")
    start = len(a.frames)
    ask(a, "default", chat, "你好（探测）")
    say("the turn", "ended" if a.listen(60, until="message.complete", after=start) else "DID NOT END in 60 s")
    a.listen(2)
    capture.update(session=chat, frames=a.frames[start:], page=rows_of(a, "default", chat))

elif STAGE == "peer":
    a, b = Socket("a"), Socket("b", profile="study")
    chief, study = bot_chat(a, "default"), bot_chat(b, "study")
    capture.update(chief=chief, study=study)

    def round_trip(name, viewer_b):
        """詩音 is asked to message 课程; returns what each side's viewer got."""
        a0, b0 = len(a.frames), len(viewer_b.frames) if viewer_b else 0
        ask(a, "default", chief, "给课程带个话（探测）")
        say(f"=== {name}: 詩音's own turn (the message_agent call)")
        say("詩音's turn", "ended" if a.listen(90, until="message.complete", after=a0) else "DID NOT END in 90 s")
        if viewer_b:
            say(f"=== {name}: 课程's Bot Chat, the turn Hermes starts with the message")
            say("课程's turn", "ended" if viewer_b.listen(90, until="message.complete", after=b0) else "DID NOT COME in 90 s")
            viewer_b.listen(2)
        say(f"=== {name}: back in 詩音's Bot Chat, the answer as a background result")
        say("詩音's second turn", "ended" if a.listen(120, until="message.complete", after=a0, count=2)
            else "DID NOT COME in 120 s")
        a.listen(3)
        return a0, b0

    a0, b0 = round_trip("both watching", b)
    capture["watching"] = {"chief_frames": a.frames[a0:], "study_frames": b.frames[b0:]}
    say("--- 课程's rows"); capture["watching"]["study_page"] = rows_of(b, "study", study)
    say("--- 詩音's rows"); capture["watching"]["chief_page"] = rows_of(a, "default", chief)

    seq, epoch = cursor_of(b, study)
    b.close()
    say(f"=== 课程's viewer goes away at seq {seq}")
    a0, _ = round_trip("课程's viewer away", None)
    back = Socket("c", profile="study")
    replay = back.call("session.events.since", {"profile": "study", "session_id": study, "last_sequence": seq,
                                                "replay_epoch": epoch}, quiet=True)
    say("课程's viewer back: session.events.since ->", "snapshot_required", replay.get("snapshot_required"),
        "events", len(replay.get("events") or []))
    for frame in replay.get("events") or []:
        if frame.get("type") != "message.delta":
            say("   replayed", frame.get("type"), "seq", frame.get("seq"), short(frame.get("payload"), 420))
    back.call("session.resume", {"profile": "study", "session_id": study, "omit_messages": True}, quiet=True)
    say("--- 课程's rows"); page = rows_of(back, "study", study)
    capture["away"] = {"chief_frames": a.frames[a0:], "study_replay": replay, "study_page": page,
                       "chief_page": rows_of(a, "default", chief, quiet=True)}

elif STAGE == "peer2":
    # the other shapes of a message between assistants: one that wants no answer, one nobody answers,
    # one sent to two at once
    a, b = Socket("a"), Socket("b", profile="study")
    chief, study = bot_chat(a, "default"), bot_chat(b, "study")
    Socket("c", profile="commute", quiet=True).call("session.create", {
        "profile": "commute", "title": "Bot Chat", "hidden": True, "follow_profile_config": True,
        "request_id": str(uuid.uuid4()).upper(), "source": "gui"}, quiet=True)
    for name, words, turns in (("notify only", "只通知课程（探测）", 1), ("nobody answers", "让课程别回（探测）", 2),
                               ("two at once", "问课程和通勤（探测）", 2)):
        a0, b0 = len(a.frames), len(b.frames)
        say(f"=== {name}")
        ask(a, "default", chief, words)
        came = a.listen(150, until="message.complete", after=a0, count=turns)
        say(f"詩音's {turns} turn(s)", "ended" if came else "DID NOT ALL COME in 150 s")
        a.listen(6)
        b.listen(3)
        capture[name] = {"chief_frames": a.frames[a0:], "study_frames": b.frames[b0:]}
    say("--- 课程's rows"); capture["study_page"] = rows_of(b, "study", study, limit=10)
    say("--- 詩音's rows"); capture["chief_page"] = rows_of(a, "default", chief, limit=14)

elif STAGE == "background":
    a = Socket("a")
    chat = bot_chat(a, "default")
    start = len(a.frames)
    ask(a, "default", chat, "后台跑一下（探测）")
    say("the turn that starts it", "ended" if a.listen(90, until="message.complete", after=start) else "DID NOT END in 90 s")
    say("=== the command ends by itself: the turn Hermes starts with its result")
    say("that turn", "ended" if a.listen(120, until="message.complete", after=start, count=2) else "DID NOT COME in 120 s")
    a.listen(3)
    capture.update(session=chat, frames=a.frames[start:], page=rows_of(a, "default", chat))

elif STAGE == "gap":
    slow, watch = Socket("slow", quiet=True, small_buffer=True), Socket("w", quiet=True)
    chat = bot_chat(slow, "default")
    start = len(slow.frames)
    ask(slow, "default", chat, "说很多（探测）")
    slow.listen(3, until="message.start", after=start)
    seq, epoch = cursor_of(slow, chat)
    say(f"the slow viewer stops reading at seq {seq}; the reply goes on")
    # nobody reads `slow` now; `watch`, attached to nothing, asks the session how far it is
    deadline, running = time.monotonic() + 600, True
    while time.monotonic() < deadline and running:
        time.sleep(5)
        state = watch.call("session.events.since", {"profile": "default", "session_id": chat, "last_sequence": seq,
                                                    "replay_epoch": epoch}, quiet=True, timeout=60)
        latest = max((e.get("seq") or 0 for e in state.get("events") or []), default=None)
        ended = any(e.get("type") == "message.complete" for e in state.get("events") or [])
        say("  the session meanwhile: snapshot_required", state.get("snapshot_required"), "truncated", state.get("truncated"),
            "events", len(state.get("events") or []), "latest", latest, "| turn over:", ended)
        running = not ended and not state.get("snapshot_required")
        if state.get("snapshot_required"):
            # what it kept is gone: ask the transcript instead whether the reply is stored
            for _ in range(100):
                page = watch.call("session.transcript", {"profile": "default", "session_id": chat, "order": "latest",
                                                         "limit": 2}, quiet=True, timeout=60)
                last = (page.get("rows") or [{}])[-1]
                if last.get("role") == "assistant":
                    say("  the reply is stored:", len(last.get("text") or last.get("content") or ""), "characters")
                    break
                time.sleep(5)
    say("=== the slow viewer reads again")
    before = len(slow.frames)
    slow.listen(20)
    got = slow.frames[before:]
    kinds = {}
    for frame in got:
        kinds[frame.get("type")] = kinds.get(frame.get("type"), 0) + 1
    say("what it then got:", kinds, "| seq from", next((f.get("seq") for f in got if f.get("seq")), None), "to",
        next((f.get("seq") for f in reversed(got) if f.get("seq")), None))
    gaps = [f for f in got if f.get("type") == "session.replay_gap"]
    for gap in gaps:
        say("   session.replay_gap as it came:", short(gap, 600))
    last_seq, last_epoch = cursor_of(slow, chat)
    rejoin = slow.call("session.events.since", {"profile": "default", "session_id": chat, "last_sequence": last_seq,
                                                "replay_epoch": last_epoch}, quiet=True, timeout=60)
    say("rejoin: session.events.since", last_seq, "->", "snapshot_required", rejoin.get("snapshot_required"), "truncated",
        rejoin.get("truncated"), "events", len(rejoin.get("events") or []), short(rejoin.get("error")))
    resumed = slow.call("session.resume", {"profile": "default", "session_id": chat, "omit_messages": True}, quiet=True)
    say("rejoin: session.resume -> running", resumed.get("running"), "keys", sorted(resumed)[:30])
    # is it subscribed again? a short turn's frames should come on this socket
    mark = len(slow.frames)
    slow.quiet = False
    ask(slow, "default", chat, "你好（探测）")
    say("after rejoining, the next turn's frames", "came" if slow.listen(60, until="message.complete", after=mark)
        else "DID NOT COME in 60 s")
    capture.update(session=chat, stopped_at=seq, gaps=gaps, kinds=kinds,
                   rejoin={k: (v if k != "events" else [{kk: vv for kk, vv in e.items() if kk != "payload"} for e in v][:40])
                           for k, v in rejoin.items()},
                   after=[f for f in slow.frames[mark:] if f.get("type") != "message.delta"])

elif STAGE == "behind":
    # hold_gateway.py holds an attach's answer while HOLD exists; mock_model.py ends 「慢慢说」 once GO does
    HOLD, GO = "/out/hold-attach", "/out/model-go"
    for path in (HOLD, HOLD + ".reached", GO):
        if os.path.exists(path):
            os.remove(path)
    a = Socket("a")
    # a session as Shion makes one to talk a skill's review over (SkillReviewTalk.open), read as it reads it
    made = a.call("session.create", {"profile": "default", "request_id": "shion-review-probe-" + uuid.uuid4().hex[:8],
                                     "source": "gui", "hidden": True, "toolsets": [], "ignore_rules": True}, quiet=True)
    session = made.get("session_id")
    if not session:
        say("no session", short(made))
        raise SystemExit(1)
    resume = {"profile": "default", "session_id": session, "display_projection": True}
    a.call("session.resume", resume, quiet=True)
    start = len(a.frames)
    ask(a, "default", session, "请和我一起审核（探测）")
    say("the first turn", "ended" if a.listen(60, until="message.complete", after=start) else "DID NOT END in 60 s")
    a.listen(2)
    opened = a.call("session.resume", resume, quiet=True)
    say("the session as a sheet opening now reads it: last_sequence", opened.get("last_sequence"), "running",
        opened.get("running"), "rows", len(opened.get("display_messages") or []))

    say("=== a message whose reply the model holds half way")
    mark = len(a.frames)
    submission = str(uuid.uuid4()).upper()
    receipt = a.call("prompt.submit", {"profile": "default", "session_id": session, "text": "慢慢说（探测）",
                                       "submission_id": submission})
    say("its first part", "came" if a.listen(60, until="message.delta", after=mark) else "DID NOT COME in 60 s")
    a.listen(1)

    say("=== the session is read again while the turn runs; Hermes's answer is held after it took the snapshot")
    open(HOLD, "w").close()
    at_call = len(a.frames)
    rid = a.begin("session.resume", resume)
    deadline = time.monotonic() + 20
    while not os.path.exists(HOLD + ".reached") and time.monotonic() < deadline:
        a.read(0.05)
    say("the attach", "took its snapshot and waits" if os.path.exists(HOLD + ".reached") else "DID NOT REACH the wait in 20 s",
        "| answered already:", rid in a.answers)
    open(GO, "w").close()
    say("the model goes on; the turn", "ended" if a.listen(60, until="message.complete", after=at_call)
        else "DID NOT END in 60 s")
    deadline, idle = time.monotonic() + 10, False
    while time.monotonic() < deadline and not idle:
        ends = [n for n, f in enumerate(a.frames) if n >= at_call and f.get("type") == "message.complete"]
        idle = bool(ends) and any(f.get("type") == "session.info" and (f.get("payload") or {}).get("running") is False
                                  for f in a.frames[ends[0]:])
        if not idle:
            a.read(0.2)
    say("session.info saying nothing runs", "came" if idle else "DID NOT COME in 10 s",
        "| the answer to session.resume before these frames:", rid in a.answers)
    overtaken = rid not in a.answers
    os.remove(HOLD)
    deadline = time.monotonic() + 30
    while rid not in a.answers and time.monotonic() < deadline:
        a.read(0.2)
    held = (a.answers.get(rid) or {}).get("result") or {}
    at_answer = a.answered_at.get(rid, len(a.frames))
    between = a.frames[at_call:at_answer]
    say("=== the answer, after", len(between), "frames that came while it was held:",
        [(f.get("type"), f.get("seq")) for f in between if f.get("type") != "message.delta"])
    say("the snapshot: replay_epoch", held.get("replay_epoch"), "last_sequence", held.get("last_sequence"), "running",
        held.get("running"), "pending", len(held.get("pending") or []), "rows",
        [(m.get("row_id"), m.get("role"), (m.get("text") or "")[:24]) for m in held.get("display_messages") or []])
    newest = max((f.get("seq") or 0 for f in between), default=0)
    say("older than the frames already on the socket:", (held.get("last_sequence") or 0) < newest,
        f"(the newest frame is seq {newest}, of epoch {next((f.get('replay_epoch') for f in between), None)})")
    end = next((f for f in between if f.get("type") == "message.complete"), {})
    say("the turn's end names its rows:", short((end.get("payload") or {}).get("persisted_turn")))
    a.listen(2)
    again = a.call("session.resume", resume, quiet=True)
    say("read once more, nothing held: last_sequence", again.get("last_sequence"), "running", again.get("running"), "rows",
        [(m.get("row_id"), m.get("role"), (m.get("text") or "")[:24]) for m in again.get("display_messages") or []])
    capture.update(session=session, submission=submission, receipt=receipt, opened=opened, overtaken=overtaken,
                   frames_before=a.frames[mark:at_call], frames_between=between, frames_after=a.frames[at_answer:],
                   held=held, again=again, page=rows_of(a, "default", session, quiet=True))

elif STAGE == "compact":
    def stored(profile):
        """The profile's store as it is, every row of it (active, archived, the parent's of a rotation),
        unprojected: what a compaction did to the rows' numbers, and what it kept of them."""
        home = os.environ["HERMES_HOME"] if profile == "default" else os.path.join(os.environ["HERMES_HOME"], "profiles", profile)
        db = sqlite3.connect(f"file:{home}/state.db?mode=ro", uri=True)
        db.row_factory = sqlite3.Row
        rows = [dict(row) for row in db.execute(
            "SELECT id, session_id, role, active, compacted, timestamp, message_uid, display_kind, display_metadata,"
            " substr(content, 1, 120) AS content FROM messages ORDER BY id")]
        issued = db.execute("SELECT seq FROM sqlite_sequence WHERE name = 'messages'").fetchone()
        db.close()
        for row in rows:
            say("   stored", short(row, 360))
        say("   the highest row number ever issued:", issued[0] if issued else None)
        return {"rows": rows, "issued": issued[0] if issued else None}

    def moved(before, after):
        """Each row of yours on the page before, and the row on the page after with its time and words."""
        later = {(row.get("timestamp"), row.get("text")): row.get("row_id")
                 for row in after.get("rows") or [] if row.get("role") == "user"}
        for row in before.get("rows") or []:
            if row.get("role") == "user":
                say("   ", row.get("text"), row.get("display_kind") or "", (row.get("display_metadata") or {}).get("submission_id", ""),
                    "row", row.get("row_id"), "->", later.get((row.get("timestamp"), row.get("text")), "not on the page"))

    def turn(viewer, profile, chat, words):
        mark = len(viewer.frames)
        submission = str(uuid.uuid4()).upper()
        viewer.call("prompt.submit", {"profile": profile, "session_id": chat, "text": words, "submission_id": submission})
        say("the turn", "ended" if viewer.listen(90, until="message.complete", after=mark) else "DID NOT END in 90 s")
        viewer.listen(1)
        return submission

    def steered(viewer, profile, chat, words, steer):
        """A prompt whose turn runs a command for a few seconds (mock_model.py: 慢慢做), and `steer` put into
        that turn while it runs, named by the run its frames carry, as Shion sends it: Hermes delivers it
        after the command's result, as a row of its own (display_kind steer)."""
        mark = len(viewer.frames)
        submission = str(uuid.uuid4()).upper()
        viewer.call("prompt.submit", {"profile": profile, "session_id": chat, "text": words, "submission_id": submission})
        if not viewer.listen(60, until="tool.start", after=mark):
            say("the command did not start in 60 s")
            raise SystemExit(1)
        generation = next(f.get("execution_generation") for f in reversed(viewer.frames) if f.get("type") == "tool.start")
        answer = viewer.call("session.steer", {"profile": profile, "session_id": chat, "text": steer,
                                               "execution_generation": generation})
        say("the turn", "ended" if viewer.listen(90, until="message.complete", after=mark) else "DID NOT END in 90 s")
        viewer.listen(1)
        return submission, answer

    def compress(viewer, profile, chat):
        """session.mutate compress, fenced by the session's revision and run as a resume gives them; the
        frames it published."""
        snapshot = viewer.call("session.resume", {"profile": profile, "session_id": chat, "omit_messages": True}, quiet=True)
        revision, generation = snapshot.get("revision"), snapshot.get("execution_generation")
        mark = len(viewer.frames)
        answer = {}
        for _ in range(2):
            answer = viewer.call("session.mutate", {"profile": profile, "session_id": chat, "request_id": str(uuid.uuid4()),
                                                    "expected_revision": revision, "expected_generation": generation,
                                                    "operation": "compress", "payload": {}}, timeout=180)
            refused = ((answer.get("error") or {}).get("data") or {})
            if refused.get("reason") not in ("revision_conflict", "stale_generation"):
                break
            revision, generation = refused.get("revision", revision), refused.get("execution_generation", generation)
        viewer.listen(3)
        return answer, [f for f in viewer.frames[mark:] if f.get("type") != "message.delta"]

    pages = {}
    for profile, path in (("default", "in place"), ("commute", "rotation")):
        say(f"######## {path} ({profile})")
        v = Socket(profile[:2], profile=None if profile == "default" else profile)
        chat = bot_chat(v, profile)
        prompts = [turn(v, profile, chat, "你好（探测）"), turn(v, profile, chat, "第二句（探测）")]
        first, steer = steered(v, profile, chat, "慢慢做（探测）", "继续")
        say("--- the newest page, before the session is compacted")
        before = rows_of(v, profile, chat, limit=50)
        before_stored = stored(profile)
        say("--- compacted")
        compacted, frames = compress(v, profile, chat)
        say("--- the newest page after it")
        after = rows_of(v, profile, chat, limit=50)
        after_stored = stored(profile)
        moved(before, after)
        say("--- a prompt in the steer's words, the same words put into a turn again, and compacted once more")
        again = turn(v, profile, chat, "继续")
        second, steer2 = steered(v, profile, chat, "慢慢做（探测）", "继续")
        before2 = rows_of(v, profile, chat, limit=50)
        compacted2, frames2 = compress(v, profile, chat)
        after2 = rows_of(v, profile, chat, limit=50)
        after2_stored = stored(profile)
        moved(before2, after2)
        capture[path] = {"profile": profile, "session": chat, "prompts": [*prompts, first, again, second],
                         "steers": [steer, steer2], "before": before, "before_stored": before_stored,
                         "compacted": compacted, "frames": frames, "after": after, "after_stored": after_stored,
                         "before2": before2, "compacted2": compacted2, "frames2": frames2, "after2": after2,
                         "after2_stored": after2_stored}
        pages[path] = {"before": before, "after": after, "before2": before2, "after2": after2}
        v.close()

    def page_text(page):
        """A page as it came, a compaction's summary cut short, a row to a line."""
        rows = [{**row, "text": row["text"][:40] + "…"} if row.get("row_kind") == "compaction" else row
                for row in page.get("rows") or []]
        head = json.dumps({key: value for key, value in page.items() if key != "rows"}, ensure_ascii=False)
        return head[:-1] + ', "rows": [\n' + ",\n".join("   " + json.dumps(row, ensure_ascii=False) for row in rows) + "]}"
    # what ../logic/send reads
    paths = [f" {json.dumps(path)}: {{\n" + ",\n".join(f"  {json.dumps(name)}: {page_text(page)}" for name, page in named.items())
             + "}" for path, named in pages.items()]
    with open(os.path.join(os.path.dirname(OUT), "compaction.json"), "w", encoding="utf-8") as out:
        out.write("{\n" + ",\n".join(paths) + "\n}\n")

with open(OUT, "w", encoding="utf-8") as out:
    json.dump(capture, out, ensure_ascii=False, indent=1)
say("capture written to", OUT)
