#!/usr/bin/env python3
"""Plays Shion's side of four of the stand-in's scripts (fake_reconnect.py: 很多, the two
same-words ones, 引导两遍 and 又说一遍, and 接不上) against the stand-in itself, and says what it
expects of every answer.

ReconnectTests needs the scripts to do exactly this, in this order, whatever the test's typing
takes; a Mac is not needed to see that they do. The stand-in runs here as it does in CI
(fake_hermes.py's own server and handler), on a port of its own; this file is the client: a
WebSocket of its own making, the requests Shion sends, and the test's words over plain HTTP.

  很多       nine turns Hermes starts by itself while away, each end in the replay naming the row
             its turn began with; read as Shion reads for them (the newest 12 rows, then 50 at a
             time), the page after the newest rows is tool calls alone, with no row_id and a
             cursor, and the first four messages are on the page above it
  引导两遍   the first message put into the turn is stored and not answered; at the second the
             socket goes, nothing stored; the reply ends while away and is replayed; the
             transcript has one row for the two messages
  又说一遍   the reply, the drop, and frames of another epoch once back (snapshot_required); the
             session.resume not answered until POST /ci/attach/go; the second saying lost only
             after the newest page was answered, whichever of the two requests comes first; the
             next replay whole; the same submission sent again admitted; the resume answered by
             itself when nobody says the word
  接不上     the drop half way through a reply; once back, the replay up to where the reply
             waited, and every session.resume refused (5001 storage_unavailable) with the socket
             kept and nothing of the session coming, until POST /ci/attach/go; then attached, the
             rest of the reply caught up and its end

Run it after changing those scripts; no CI step runs it. Exits 1 when something is not as expected.

    python3 macos/ci/check_fake_reconnect.py

Stdlib only.
"""
import base64
import http.client
import json
import os
import shutil
import socket
import struct
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fake_control  # noqa: E402
import fake_hermes  # noqa: E402
import fake_kanban  # noqa: E402
import fake_media  # noqa: E402
import fake_profiles  # noqa: E402
import fake_reconnect  # noqa: E402

SESSION, PROFILE = "sess-shion", "shion"
MANY_SCRIPT = "断线：很多"
STEER_SCRIPT, STEERED_WORDS = "断线：引导两遍", "改到五点（CI）"
AGAIN = "断线：又说一遍"
REFUSED = "断线：接不上"

failed = []
lines = []  # the stand-in's log, shown when something fails


def expect(what, ok, detail=""):
    print(("ok    " if ok else "FAIL  ") + what + (f": {detail}" if detail and not ok else ""))
    if not ok:
        failed.append(what)


class Client:
    """One socket, as Shion's: requests out, and every frame that comes kept with when it came."""

    def __init__(self, port, token):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            f"GET /api/ws?token={token} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
            "CF-Access-Client-Id: ci-client\r\nCF-Access-Client-Secret: ci-secret\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.sock.recv(1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise RuntimeError(f"no upgrade: {head[:60]!r}")
        self.sock.settimeout(None)
        self.frames = []  # (when, the frame)
        self.gone_at = None
        self.changed = threading.Condition()
        self.ids = 0
        threading.Thread(target=self.read, daemon=True).start()

    def exactly(self, count):
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise ConnectionError("eof")
            data += chunk
        return data

    def read(self):
        try:
            while True:
                head = self.exactly(2)
                length = head[1] & 0x7F
                if length == 126:
                    length = struct.unpack(">H", self.exactly(2))[0]
                elif length == 127:
                    length = struct.unpack(">Q", self.exactly(8))[0]
                data = self.exactly(length)
                if head[0] & 0x0F != 1:
                    continue
                with self.changed:
                    self.frames.append((time.time(), json.loads(data)))
                    self.changed.notify_all()
        except (OSError, ValueError):
            pass
        with self.changed:
            self.gone_at = time.time()
            self.changed.notify_all()

    def send(self, method, params):
        """A request out; its id."""
        self.ids += 1
        data = json.dumps({"jsonrpc": "2.0", "id": self.ids, "method": method, "params": params}).encode()
        mask = os.urandom(4)
        head = bytearray([0x81])
        if len(data) < 126:
            head.append(0x80 | len(data))
        else:
            head.append(0x80 | 126)
            head += struct.pack(">H", len(data))
        self.sock.sendall(bytes(head) + mask + bytes(byte ^ mask[i % 4] for i, byte in enumerate(data)))
        return self.ids

    def wait(self, wanted, seconds):
        """The first frame `wanted` is true of, with when it came; None when none comes in time or
        the socket goes first."""
        deadline = time.time() + seconds
        seen = 0
        with self.changed:
            while True:
                for when, frame in self.frames[seen:]:
                    if wanted(frame):
                        return when, frame
                seen = len(self.frames)
                left = deadline - time.time()
                if left <= 0 or self.gone_at is not None:
                    return None
                self.changed.wait(left)

    def answer(self, rid, seconds=5):
        """A request's answer (its result, or its error), or None."""
        found = self.wait(lambda frame: frame.get("id") == rid, seconds)
        return None if found is None else found[1].get("result", found[1].get("error"))

    def call(self, method, params, seconds=5):
        return self.answer(self.send(method, params), seconds)

    def event(self, kind, seconds=10, where=lambda payload: True):
        found = self.wait(lambda frame: frame.get("method") == "event" and frame["params"].get("type") == kind
                          and where(frame["params"].get("payload") or {}), seconds)
        return None if found is None else found[1]["params"]

    def gone(self, seconds):
        """When the socket went, or None if it has not in time."""
        deadline = time.time() + seconds
        with self.changed:
            while self.gone_at is None and time.time() < deadline:
                self.changed.wait(deadline - time.time())
            return self.gone_at

    def cursor(self):
        """The newest numbered frame of the session: where a replay goes on from."""
        with self.changed:
            numbered = [frame["params"] for _, frame in self.frames
                        if frame.get("method") == "event" and frame["params"].get("session_id") == SESSION
                        and "seq" in frame["params"]]
        return (numbered[-1]["replay_epoch"], numbered[-1]["seq"]) if numbered else None


def post(port, path):
    """One of the test's words; the status and the answer."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=40)
    connection.request("POST", path, headers={"Content-Length": "0"})
    reply = connection.getresponse()
    body = reply.read()
    connection.close()
    try:
        return reply.status, json.loads(body)
    except ValueError:
        return reply.status, {}


def status(port):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request("GET", "/api/status")
    code = connection.getresponse().status
    connection.close()
    return code


def attached(port, token, since=None):
    """A new socket with the session attached: the replay first when there is a cursor, as Shion
    asks. The client, what the replay answered (None without a cursor) and the snapshot."""
    client = Client(port, token)
    replay = None
    if since is not None:
        replay = client.call("session.events.since", {"profile": PROFILE, "session_id": SESSION,
                                                      "last_sequence": since[1], "replay_epoch": since[0]})
    snapshot = client.call("session.resume", {"profile": PROFILE, "session_id": SESSION, "omit_messages": True})
    return client, replay, snapshot


def newest_page(client):
    page = client.call("session.transcript", {"profile": PROFILE, "session_id": SESSION, "order": "latest", "limit": 50})
    return (page or {}).get("rows", [])


def mine(rows, words):
    return [row for row in rows if row.get("role") == "user" and row.get("text") == words]


def submit(client, words, submission):
    return client.send("prompt.submit", {"profile": PROFILE, "session_id": SESSION, "text": words,
                                         "submission_id": submission})


def many(port, token):
    print("\n很多: nine turns Hermes starts by itself while away, the fourth with many tool calls")
    client, _, snapshot = attached(port, token)
    expect("the chat is attached", bool(snapshot and snapshot.get("subscription_id")), str(snapshot))
    receipt = client.answer(submit(client, MANY_SCRIPT, str(uuid.uuid4())))
    expect("the sentence has its receipt", bool(receipt and receipt.get("admission_id")), str(receipt))
    expect("after its short reply the socket goes", client.gone(5) is not None)
    cursor = client.cursor()
    code, word = post(port, fake_reconnect.CONTROL)
    expect("the tunnel comes back once the nine turns are over", code == 200 and word.get("meanwhile") == "done",
           f"{code} {word}")
    back, replay, _ = attached(port, token, cursor)
    ends = [event["payload"].get("persisted_turn") or {} for event in (replay or {}).get("events", [])
            if event.get("type") == "message.complete"]
    named = [end.get("user_row_id") for end in ends if not end.get("submission_id")]
    expect("the replay has the nine turns' ends, each naming the row it began with",
           len(named) == 9 and None not in named, str(named))
    # as Shion reads for them (AppStore.followNotices): the newest 12 rows, then 50 at a time further up
    pages = [back.call("session.transcript", {"profile": PROFILE, "session_id": SESSION, "order": "latest", "limit": 12})]
    for _ in range(2):
        pages.append(back.call("session.transcript", {"profile": PROFILE, "session_id": SESSION, "order": "latest",
                                                      "limit": 50, "cursor": (pages[-1] or {}).get("next_cursor")}))
    rows = [(page or {}).get("rows", []) for page in pages]
    numbers = [{row["row_id"] for row in page if "row_id" in row} for page in rows]
    expect("the newest rows have the last four messages and the folded results, not the first four",
           set(named[4:]) <= numbers[0] and not set(named[:4]) & numbers[0], f"{named} {sorted(numbers[0])}")
    expect("the next page up is tool calls alone: each with its call's id and no row_id, and a cursor",
           len(rows[1]) == 50 and all(row.get("role") == "tool" and row.get("tool_call_id") and "row_id" not in row
                                      for row in rows[1]) and bool((pages[1] or {}).get("next_cursor")),
           str(rows[1][:2]))
    expect("the first four messages are on the page above it", set(named[:4]) <= numbers[2],
           f"{named} {sorted(numbers[2])}")


def steered_twice(port, token):
    print("\n引导两遍: the same words put into a running turn twice as the connection goes")
    client, _, snapshot = attached(port, token)
    expect("the chat is attached", bool(snapshot and snapshot.get("subscription_id")), str(snapshot))
    receipt = client.answer(submit(client, STEER_SCRIPT, str(uuid.uuid4())))
    expect("the sentence that starts the turn has its receipt", bool(receipt and receipt.get("admission_id")), str(receipt))
    start = client.event("message.start")
    first_part = client.event("message.delta", where=lambda payload: payload.get("text") == fake_reconnect.STEERING_FIRST)
    expect("the reply starts and waits", start is not None and first_part is not None)
    generation = (start or {}).get("execution_generation")
    steer = {"profile": PROFILE, "session_id": SESSION, "text": STEERED_WORDS, "execution_generation": generation}

    first = client.send("session.steer", steer)
    expect("the first message put into the turn gets no answer", client.answer(first, 1.0) is None)
    with fake_hermes.lock:
        stored = mine(fake_hermes.transcripts.get(SESSION, []), STEERED_WORDS)
    expect("and is stored, once, as a row of the turn",
           len(stored) == 1 and stored[0].get("display_kind") == "steer", str(stored))
    expect("the socket is still up", client.gone(0.1) is None)

    second = client.send("session.steer", steer)
    expect("at the second the socket goes", client.gone(3) is not None)
    expect("neither was answered", client.answer(first, 0) is None and client.answer(second, 0) is None)
    expect("the tunnel is down", status(port) == 502)
    cursor = client.cursor()
    code, word = post(port, fake_reconnect.CONTROL)
    expect("the tunnel comes back once the reply has ended", code == 200 and word.get("meanwhile") == "done", f"{code} {word}")

    back, replay, snapshot = attached(port, token, cursor)
    ended = [event for event in (replay or {}).get("events", []) if event.get("type") == "message.complete"]
    expect("the replay has the reply's end", bool(replay) and replay.get("snapshot_required") is False and len(ended) == 1,
           str(replay)[:200])
    expect("no turn runs any more", bool(snapshot) and snapshot.get("running") is not True)
    rows = newest_page(back)
    expect("the transcript has one row in those words for the two messages", len(mine(rows, STEERED_WORDS)) == 1,
           str(mine(rows, STEERED_WORDS)))

    # a message put into no turn is the stop and retry module's to answer, as before
    other = back.call("session.steer", {**steer, "execution_generation": fake_control.fence(SESSION)["generation"]})
    expect("a message put into no turn is still answered: rejected, not delivered",
           bool(other) and other.get("status") == "rejected" and other.get("delivered") is False, str(other))
    return back


def said_again(port, token, client, page_first):
    order = "the newest page asked for first" if page_first else "the message sent before the newest page is asked for"
    print(f"\n又说一遍: said again while the chat is being attached again, and lost ({order})")
    first = str(uuid.uuid4())
    receipt = client.answer(submit(client, AGAIN, first))
    expect("the first saying has its receipt", bool(receipt and receipt.get("admission_id")), str(receipt))
    end = client.event("message.complete", where=lambda payload: (payload.get("persisted_turn") or {}).get("submission_id") == first)
    row = ((end or {}).get("payload", {}).get("persisted_turn") or {}).get("user_row_id")
    expect("its turn ends and names its row", row is not None)
    expect("then the socket goes", client.gone(3) is not None)
    old = client.cursor()
    code, word = post(port, fake_reconnect.CONTROL)
    expect("the tunnel comes back", code == 200, f"{code} {word}")

    back = Client(port, token)
    replay = back.call("session.events.since", {"profile": PROFILE, "session_id": SESSION,
                                                "last_sequence": old[1], "replay_epoch": old[0]})
    expect("the replay cannot be had: the frames are of another epoch",
           bool(replay) and replay.get("snapshot_required") is True and replay.get("events") == [], str(replay)[:200])
    resume = back.send("session.resume", {"profile": PROFILE, "session_id": SESSION, "omit_messages": True})
    expect("session.resume is not answered yet", back.answer(resume, 1.5) is None)
    code, word = post(port, fake_reconnect.ATTACH)
    expect("the test's word lets it be", code == 200 and word.get("held") is True, f"{code} {word}")
    snapshot = back.answer(resume, 3)
    expect("it is answered then, where the new frames start",
           bool(snapshot) and snapshot.get("replay_epoch") not in (None, old[0]) and snapshot.get("last_sequence") == 0,
           str(snapshot)[:200])
    code, word = post(port, fake_reconnect.ATTACH)
    expect("the word a second time finds nothing held back", code == 409, f"{code} {word}")

    second = str(uuid.uuid4())
    if page_first:
        rows = newest_page(back)
        paged = time.time()
        lost = submit(back, AGAIN, second)
    else:
        lost = submit(back, AGAIN, second)
        expect("the message waits: no answer, and the socket up", back.answer(lost, 1.0) is None and back.gone(0.1) is None)
        rows = newest_page(back)
        paged = time.time()
    there = mine(rows, AGAIN)
    expect("the newest page is answered, with the first saying's row among those in its words",
           any(found.get("row_id") == row and (found.get("display_metadata") or {}).get("submission_id") == first
               for found in there), str(there))
    before = len(there)
    went = back.gone(4)
    expect("the socket goes a moment after the page, the second saying not answered",
           went is not None and went - paged >= fake_reconnect.LOSES_AFTER - 0.1 and back.answer(lost, 0) is None,
           f"{None if went is None else round(went - paged, 2)} s after the page")
    code, word = post(port, fake_reconnect.CONTROL)
    expect("the tunnel comes back", code == 200, f"{code} {word}")

    again, replay, snapshot = attached(port, token, (snapshot or {}).get("replay_epoch") and (snapshot["replay_epoch"], 0))
    expect("this time the replay is whole, and has nothing",
           bool(replay) and replay.get("snapshot_required") is False and replay.get("events") == [], str(replay)[:200])
    expect("session.resume is answered at once", bool(snapshot) and snapshot.get("subscription_id") is not None)
    expect("nothing is pending", bool(snapshot) and snapshot.get("pending") == [], str((snapshot or {}).get("pending")))
    expect("the lost message is on no row", len(mine(newest_page(again), AGAIN)) == before)
    receipt = again.answer(submit(again, AGAIN, second))
    expect("sent again under its id, it is admitted", bool(receipt and receipt.get("admission_id")), str(receipt))
    answered = again.event("message.complete", where=lambda payload: payload.get("text") == "收到：" + AGAIN)
    expect("and answered like any other sentence", answered is not None)
    expect("now it has a row", len(mine(newest_page(again), AGAIN)) == before + 1)
    return again


def nobody_says(port, token, client):
    print("\n又说一遍: nobody says the word")
    receipt = client.answer(submit(client, AGAIN, str(uuid.uuid4())))
    expect("the first saying has its receipt", bool(receipt and receipt.get("admission_id")), str(receipt))
    expect("then the socket goes", client.gone(5) is not None)
    old = client.cursor()
    post(port, fake_reconnect.CONTROL)
    back = Client(port, token)
    back.call("session.events.since", {"profile": PROFILE, "session_id": SESSION, "last_sequence": old[1], "replay_epoch": old[0]})
    asked = time.time()
    snapshot = back.call("session.resume", {"profile": PROFILE, "session_id": SESSION, "omit_messages": True},
                         fake_reconnect.HOLD + 3)
    took = time.time() - asked
    expect("session.resume is answered by itself after the wait",
           bool(snapshot) and fake_reconnect.HOLD - 0.2 <= took <= fake_reconnect.HOLD + 2, f"{took:.1f} s")
    code, word = post(port, fake_reconnect.ATTACH)
    expect("and the word then finds nothing held back", code == 409, f"{code} {word}")


def not_attached_again(port, token):
    print("\n接不上: back after the drop, and the chat not attached again until the test says so")
    client, _, snapshot = attached(port, token)
    expect("the chat is attached", bool(snapshot and snapshot.get("subscription_id")), str(snapshot))
    receipt = client.answer(submit(client, REFUSED, str(uuid.uuid4())))
    expect("the sentence that starts the turn has its receipt", bool(receipt and receipt.get("admission_id")), str(receipt))
    expect("the reply starts", client.event("message.delta", where=lambda payload: payload.get("text") == "第1拍。") is not None)
    expect("then the socket goes", client.gone(5) is not None)
    cursor = client.cursor()
    code, word = post(port, fake_reconnect.CONTROL)
    expect("the tunnel comes back once the reply waits for Shion", code == 200 and word.get("meanwhile") == "done",
           f"{code} {word}")

    back = Client(port, token)
    replay = back.call("session.events.since", {"profile": PROFILE, "session_id": SESSION,
                                                "last_sequence": cursor[1], "replay_epoch": cursor[0]})
    parts = [event["payload"].get("text") for event in (replay or {}).get("events", []) if event.get("type") == "message.delta"]
    expect("the replay has what came while away, up to where the reply waited",
           bool(replay) and replay.get("snapshot_required") is False and parts[-1:] == ["第15拍。"], str(parts))
    for n in (1, 2):
        refused = back.call("session.resume", {"profile": PROFILE, "session_id": SESSION, "omit_messages": True})
        expect(f"session.resume {n} is refused as a busy store refuses it: 5001 storage_unavailable",
               bool(refused) and refused.get("code") == 5001
               and (refused.get("data") or {}).get("reason") == "storage_unavailable", str(refused))
    expect("the socket stays up", back.gone(0.1) is None)
    expect("nothing of the session comes while it is not attached, though the reply goes on",
           back.event("message.delta", seconds=1.5) is None)
    code, word = post(port, fake_reconnect.ATTACH)
    expect("the test's word lets it be attached", code == 200 and word.get("refused") is True, f"{code} {word}")
    snapshot = back.call("session.resume", {"profile": PROFILE, "session_id": SESSION, "omit_messages": True})
    expect("the next session.resume attaches it", bool(snapshot) and snapshot.get("subscription_id") is not None,
           str(snapshot)[:200])
    caught = back.event("message.delta", where=lambda payload: payload.get("text") == "第16拍。")
    end = back.event("message.complete", seconds=15)
    expect("the rest of the reply comes, from where the replay stopped, and its end", caught is not None and end is not None)
    with fake_hermes.lock:
        rows = [row for row in fake_hermes.transcripts.get(SESSION, []) if row.get("role") == "assistant"]
    expect("the reply is stored whole", bool(rows) and rows[-1].get("text", "").startswith("第1拍。")
           and rows[-1].get("text", "").endswith("第30拍。"), str(rows[-1:])[:200])
    code, word = post(port, fake_reconnect.ATTACH)
    expect("the word a second time finds nothing to let be", code == 409, f"{code} {word}")


def main():
    def log(*parts):
        lines.append(" ".join(str(part) for part in parts))

    pasted = tempfile.mkdtemp(prefix="shion-media-check-")
    fake_media.PASTED = pasted  # the stand-in's own folder is CI's; this run's is thrown away
    fake_hermes.log = log
    fake_kanban.setup(log, fake_hermes.valid_access)
    fake_profiles.setup(log, fake_hermes.valid_access)
    fake_media.setup(log, fake_hermes.valid_access, fake_hermes.transcripts, fake_hermes.lock)
    fake_control.setup(log, fake_hermes.transcripts, fake_hermes.lock)
    fake_reconnect.setup(log, fake_hermes.transcripts, fake_hermes.lock)
    server = fake_hermes.Server(("127.0.0.1", 0), fake_hermes.Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    token = fake_hermes.mint_pair()["access_token"]
    try:
        many(port, token)
        client = steered_twice(port, token)
        client = said_again(port, token, client, page_first=True)
        client = said_again(port, token, client, page_first=False)
        fake_reconnect.HOLD = 2.0  # not the half minute a test has
        nobody_says(port, token, client)
        not_attached_again(port, token)
    except Exception as error:  # a step that could not go on: the log says where the stand-in was
        expect("the run went through", False, repr(error))
    finally:
        server.shutdown()
        shutil.rmtree(pasted, ignore_errors=True)
    if failed:
        print("\nthe stand-in's log:\n" + "\n".join(lines[-80:]))
        print(f"\n{len(failed)} not as expected")
        sys.exit(1)
    print("\nall as expected")


if __name__ == "__main__":
    main()
