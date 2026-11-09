#!/usr/bin/env python3
"""A stand-in for what Shion talks to, for the browser sign-in test on CI (SignInTests).

Plays Cloudflare Access in front, with strict service token authentication (an organization
setting, on for every new organization): a request with the service token headers is judged by
them alone, gets no cookie back, and a bad token is a 403, never a login redirect. A request
without them is a browser: Access's CF_Authorization cookie lets it through; without one it is
sent to the Access login page on another origin (localhost here, <team>.cloudflareaccess.com for
real), which signs itself in and sends the browser back through /cdn-cgi/access/authorized.
Behind it, the parts of a Hermes gateway's Webapp that Shion uses, shaped like
hermes_cli/dashboard_auth and the Canonical Gateway Protocol:

  GET  /api/status             public; says a password provider and native_pkce are on
  GET  /auth/native/authorize  checks PKCE S256 and the loopback redirect, then 302 to /login
  GET  /login                  a login page that fills itself in and submits
  POST /auth/password-login    returns the loopback redirect with a one-time code
  POST /auth/native/token      code + verifier -> bearer tokens
  POST /auth/native/refresh    refresh token -> the next pair
  GET  /api/auth/me            the bearer's identity, or 401
  GET  /api/ws?token=…         JSON-RPC 2.0 over WebSocket: gateway.ready, runtime.describe,
                               profiles, Bot Chats (詩音's is long and paged with
                               session.transcript; 课程's is created on first open)
  /api/plugins/kanban/…        the kanban plugin: boards, cards, moves, comments and the
                               /events socket (fake_kanban.py)

Like Hermes's contracts (extra="forbid"), session.resume and session.transcript refuse keys
they do not know, so a client's wrong parameter fails here as it would on a real server.

Every request is logged (path, which credentials came, the answer), so a failing run shows
where the flow stopped. Stdlib only.
"""
import argparse
import base64
import re
import os
import hashlib
import json
import secrets
import socketserver
import struct
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fake_control  # noqa: E402  stop, retry and the server check (ChatControlTests)
import fake_kanban  # noqa: E402  the kanban plugin's routes (BoardTests)
import fake_shion  # noqa: E402  the shion plugin's RPCs

ACCESS_ID, ACCESS_SECRET = "ci-client", "ci-secret"
USER, PASSWORD = "ci-user", "ci-pass"

lock = threading.Lock()
access_logins = {}  # one-time token from the Access login page -> where the browser was going
access_cookies = set()  # CF_Authorization values of browsers signed in to Access
pending = {}  # broker -> {challenge, redirect_uri, state}
codes = {}  # code -> challenge
access_tokens = {}  # token -> expiry
refresh_tokens = set()
# profile -> its Bot Chat. 詩音's is long; 课程's exists and raises an approval once Shion attaches
# to it, without its chat being opened; 通勤 has none until its chat is opened (created then).
sessions = {"shion": "sess-shion", "study": "sess-study"}
transcripts = {}  # session id -> rows, oldest first, shaped like session.transcript rows
approvals_raised = set()  # session ids that already asked
APPROVAL = {"prompt_id": "ap-moodle", "execution_generation": 1, "command": "open https://moodle.example/login",
            "description": "要在课程的云桌面上登录 Moodle 吗？", "choices": ["once", "session", "always", "deny"]}
RESPOND_KEYS = {"profile", "session_id", "execution_generation", "prompt_id", "choice", "answer"}


def seed_transcripts():
    """詩音's Bot Chat: 130 numbered messages and a greeting last, shaped as Hermes projects them
    (gateway/session_transcript_rows.py, tui_gateway/session_history.py): a compaction row has the
    row_id of the message it was stored on and comes just before it, and that message still shows
    when it holds real content too; tool rows have no row_id, only their call's id. The first
    compaction is on 第 1 条, with two tool rows after it; the second is on 第 32 条, which leads the
    second page, so the compaction is the last row of the third."""
    start = time.time() - 86400
    rows = []

    def compaction(row_id, folded, at):
        rows.append({"row_id": row_id, "row_kind": "compaction", "role": "system", "text": f"（之前 {folded} 条的摘要）",
                     "compacted_messages": folded, "timestamp": at})

    for n in range(1, 131):
        who = "user" if n % 2 else "assistant"
        at = start + n * 60
        if n == 1:
            compaction(n + 1, 40, at)
        if n == 32:
            compaction(n + 1, 70, at)
        rows.append({"row_id": n + 1, "row_kind": "message", "role": who,
                     "text": f"第 {n} 条（{'你' if who == 'user' else '詩音'}）", "timestamp": at})
        if n == 1:
            for call, context in (("call-ci-1", "第 1 条问的"), ("call-ci-2", "再查一次")):
                rows.append({"row_kind": "message", "role": "tool", "name": "web_search", "context": context,
                             "tool_call_id": call, "timestamp": at + 10})
    rows.append({"row_id": 200, "row_kind": "message", "role": "assistant", "text": "CI 替身服务器连上了。",
                 "timestamp": time.time()})
    transcripts["sess-shion"] = rows
    transcripts["sess-study"] = [{"row_id": 1, "row_kind": "message", "role": "assistant",
                                  "text": "课程的 Bot Chat。", "timestamp": start}]


seed_transcripts()

# what Hermes's canonical contracts accept (tui_gateway/contracts/canonical_sessions.py and
# canonical_stored_reads.py)
RESUME_KEYS = {"profile", "session_id", "title", "latest", "workspace", "source", "editor", "api_key",
               "defer_history", "omit_messages", "cols", "display_projection"}
TRANSCRIPT_KEYS = {"session_id", "profile", "subagent_id", "cursor", "limit", "order", "inline_images"}
# gateway/session_policy.py: CREATE_FIELDS (+ title, and hidden/profile, which it takes off first),
# and SURFACES: the source names a session can be created with, and the interface each one means
SURFACES = {"cli": "cli", "tui": "tui", "gui": "desktop", "acp": "acp", "tool": "cli", "oneshot": "cli"}
CREATE_KEYS = {"request_id", "source", "cwd", "model", "toolsets", "provider", "base_url", "reasoning", "max_turns",
               "ignore_rules", "api_key", "editor", "yolo", "safe_mode", "ignore_user_config", "skills",
               "checkpoints", "accept_hooks", "pass_session_id", "follow_profile_config", "service_tier",
               "cwd_explicit", "run_budget", "verbose", "row_cwd", "client_env", "client", "title", "hidden",
               "profile"}
CLIENT_NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
CLIENT_VERSION = re.compile(r"[!-~]{1,64}")


print_lock = threading.Lock()


def log(*parts):
    with print_lock:
        print(time.strftime("%H:%M:%S"), *parts, flush=True)


def s256(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode()


def mint_pair():
    access, refresh = "at-" + secrets.token_urlsafe(24), "rt-" + secrets.token_urlsafe(24)
    expires = int(time.time()) + 3600
    with lock:
        access_tokens[access] = expires
        refresh_tokens.add(refresh)
    return {"access_token": access, "refresh_token": refresh, "token_type": "Bearer",
            "expires_at": expires, "provider": "basic", "user_id": USER}


def valid_access(token):
    with lock:
        return access_tokens.get(token, 0) > time.time()


ACCESS_PAGE = """<!doctype html><meta charset="utf-8"><title>Cloudflare Access (CI)</title>
<body style="font:15px -apple-system,system-ui;margin:3rem">
<h3>Cloudflare Access（CI 替身）</h3><p>假装你已经输好了邮箱验证码，正在回到原来的页面…</p>
<script>setTimeout(function () { window.location.replace(%s); }, 600);</script>"""

LOGIN_PAGE = """<!doctype html><meta charset="utf-8"><title>Hermes (CI)</title>
<body style="font:15px -apple-system,system-ui;margin:3rem">
<h3>Hermes 登录（CI 替身）</h3><p id="s">自动填用户名和密码，提交中…</p>
<script>
fetch('/auth/password-login', {method: 'POST', credentials: 'same-origin',
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({provider: 'basic', username: '%s', password: '%s', next: ''})})
  .then(function (r) { return r.json().then(function (d) { return [r.status, d]; }); })
  .then(function (x) {
    document.getElementById('s').textContent = 'HTTP ' + x[0] + ' → ' + (x[1].next || x[1].detail);
    if (x[0] === 200) { window.location.assign(x[1].next); }
  })
  .catch(function (e) { document.getElementById('s').textContent = '失败：' + e; });
</script>""" % (USER, PASSWORD)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def setup(self):
        super().setup()
        # a WebSocket's frames come from more than one thread (replies, timers, pushes): one at a time.
        # Every connection gets it, since /api/ws and the kanban /events socket both send frames.
        self.write_lock = threading.Lock()

    def handle(self):
        # a client that hangs up between requests is not news
        try:
            super().handle()
        except (ConnectionError, TimeoutError):
            pass

    # ---- plumbing -----------------------------------------------------------------------

    def cookies(self):
        jar = {}
        for part in self.headers.get("Cookie", "").split(";"):
            if "=" in part:
                name, value = part.strip().split("=", 1)
                jar[name] = value
        return jar

    def answer(self, status, body=b"", content_type="application/json", headers=()):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type + ("; charset=utf-8" if "html" in content_type else ""))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in list(headers) + self.extra_headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)
        log(f"  -> {status}")

    def origin(self, host):
        return f"http://{host}:{self.server.server_address[1]}"

    def access(self):
        """Cloudflare Access with strict service token authentication (see the top of this file)."""
        self.extra_headers = []
        client_id = self.headers.get("CF-Access-Client-Id")
        secret = self.headers.get("CF-Access-Client-Secret")
        cookie = self.cookies().get("CF_Authorization", "")
        with lock:
            has_cookie = cookie in access_cookies
        url = urllib.parse.urlsplit(self.path)
        via = ("headers" if client_id == ACCESS_ID and secret == ACCESS_SECRET else "BAD-TOKEN") \
            if (client_id or secret) else ("cookie" if has_cookie else "NONE")
        log(f"{self.command} {url.path} access={via}"
            f" bearer={'yes' if self.headers.get('Authorization') else 'no'}"
            f" query={sorted(urllib.parse.parse_qs(url.query))}")
        if via == "headers":
            return True
        if via == "BAD-TOKEN":
            self.answer(403, "<h1>Forbidden</h1><p>Cloudflare Access (CI stand-in): bad service token.</p>",
                        "text/html")
            return False
        if has_cookie:
            return True
        # a browser that has not signed in to Access: off to the login page, on another origin
        login = self.origin("localhost") + "/cdn-cgi/access/login?" + urllib.parse.urlencode(
            {"redirect_url": self.origin("127.0.0.1") + self.path})
        self.answer(302, b"", "text/plain", [("Location", login)])
        return False

    def access_login(self, query):
        """The Access login page (another origin): signs itself in, then back via /authorized."""
        self.extra_headers = []
        target = query.get("redirect_url", "")
        log(f"GET [Access login on localhost] for {urllib.parse.urlsplit(target).path}")
        if not target.startswith(self.origin("127.0.0.1") + "/"):
            return self.answer(400, "<p>bad redirect_url</p>", "text/html")
        token = secrets.token_urlsafe(18)
        with lock:
            access_logins[token] = target
        back = self.origin("127.0.0.1") + "/cdn-cgi/access/authorized?" + urllib.parse.urlencode({"token": token})
        self.answer(200, ACCESS_PAGE % json.dumps(back), "text/html")

    def access_authorized(self, query):
        """Access's callback on the application's origin: sets CF_Authorization, back to the page."""
        self.extra_headers = []
        with lock:
            target = access_logins.pop(query.get("token", ""), None)
        log(f"GET /cdn-cgi/access/authorized {'ok' if target else 'UNKNOWN TOKEN'}")
        if target is None:
            return self.answer(403, "<p>Access login expired</p>", "text/html")
        value = secrets.token_urlsafe(18)
        with lock:
            access_cookies.add(value)
        self.answer(302, b"", "text/plain", [
            ("Set-Cookie", f"CF_Authorization={value}; Path=/; HttpOnly; SameSite=Lax"), ("Location", target)])

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return {}

    # ---- routes -------------------------------------------------------------------------

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        if self.headers.get("Host", "").split(":")[0] == "localhost":
            return self.access_login(query)
        if url.path == "/cdn-cgi/access/authorized":
            return self.access_authorized(query)
        if not self.access():
            return
        if url.path == "/api/status":
            # memory as gateway/memory_status.py reports it: a 2 GB server, so the board's
            # default limit is 2048 // 512 = 4
            return self.answer(200, {"auth_required": True, "auth_providers": ["basic"],
                                     "auth_flows": ["cookie", "native_pkce"],
                                     "memory": {"pressure": "ok", "gateway_rss_mb": 310,
                                                "system_total_mb": 2048, "system_available_mb": 1200}})
        if url.path == "/api/config":
            bearer = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
            if not valid_access(bearer):
                return self.answer(401, {"detail": "Unauthorized"})
            # the overall limit unset (so it comes from memory), one task per assistant
            return self.answer(200, {"model": "ci-model", "kanban": {
                "max_in_progress": None, "max_in_progress_per_profile": 1, "dispatch_interval_seconds": 60}})
        if url.path == "/auth/native/authorize":
            return self.authorize(query)
        if url.path == "/login":
            return self.answer(200, LOGIN_PAGE, "text/html")
        if url.path == "/api/auth/me":
            bearer = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
            if valid_access(bearer):
                return self.answer(200, {"user_id": USER, "email": "", "display_name": USER, "org_id": "",
                                         "provider": "basic", "expires_at": access_tokens[bearer]})
            return self.answer(401, {"detail": "Unauthorized"})
        if url.path == "/api/ws":
            return self.socket(query)
        if url.path.startswith(fake_kanban.PREFIX):
            return fake_kanban.route(self, "GET", url, query, {})
        self.answer(404, {"detail": "Not Found"})

    def do_POST(self):
        if not self.access():
            return
        url = urllib.parse.urlsplit(self.path)
        body = self.body()
        if url.path == "/auth/password-login":
            return self.password_login(body)
        if url.path == "/auth/native/token":
            with lock:
                challenge = codes.pop(body.get("code", ""), None)
            if challenge is None or s256(body.get("code_verifier", "")) != challenge:
                log("  token: unknown code or PKCE mismatch")
                return self.answer(400, {"detail": "Invalid or expired authorization code."})
            return self.answer(200, mint_pair())
        if url.path == "/auth/native/refresh":
            with lock:
                known = body.get("refresh_token") in refresh_tokens
                refresh_tokens.discard(body.get("refresh_token"))
            if not known:
                return self.answer(401, {"error": "session_expired", "detail": "start a new sign-in"})
            return self.answer(200, mint_pair())
        if url.path.startswith(fake_kanban.PREFIX):
            return fake_kanban.route(self, self.command, url, dict(urllib.parse.parse_qsl(url.query)), body)
        self.answer(404, {"detail": "Not Found"})

    do_PATCH = do_DELETE = do_POST

    def authorize(self, query):
        problems = []
        if query.get("code_challenge_method", "").upper() != "S256":
            problems.append("code_challenge_method must be S256")
        if len(query.get("code_challenge", "")) != 43:
            problems.append("code_challenge must be base64url SHA-256 (43 chars)")
        redirect = urllib.parse.urlsplit(query.get("redirect_uri", ""))
        if redirect.scheme != "http" or redirect.hostname != "127.0.0.1" or not redirect.port:
            problems.append("redirect_uri must be http://127.0.0.1:<port>/...")
        if len(query.get("state", "")) < 16:
            problems.append("state must be random")
        if problems:
            log("  authorize refused:", "; ".join(problems))
            return self.answer(400, {"detail": "; ".join(problems)})
        broker = secrets.token_urlsafe(24)
        with lock:
            pending[broker] = {"challenge": query["code_challenge"], "redirect_uri": query["redirect_uri"],
                               "state": query["state"]}
        self.extra_headers.append(("Set-Cookie", f"hermes_pkce={broker}; Path=/; HttpOnly; SameSite=Lax"))
        self.answer(302, b"", "text/plain", [("Location", "/login")])

    def password_login(self, body):
        if body.get("username") != USER or body.get("password") != PASSWORD:
            return self.answer(401, {"detail": "Invalid credentials"})
        with lock:
            entry = pending.pop(self.cookies().get("hermes_pkce", ""), None)
        if entry is None:
            log("  password-login: no native sign-in pending for this browser (pkce cookie missing)")
            return self.answer(400, {"detail": "Native login expired or unknown; restart sign-in."})
        code = secrets.token_urlsafe(32)
        with lock:
            codes[code] = entry["challenge"]
        target = entry["redirect_uri"] + "?" + urllib.parse.urlencode({"code": code, "state": entry["state"]})
        self.answer(200, {"ok": True, "next": target})

    # ---- /api/ws ------------------------------------------------------------------------

    def socket(self, query):
        if self.headers.get("Upgrade", "").lower() != "websocket":
            return self.answer(400, {"detail": "expected a WebSocket upgrade"})
        if not valid_access(query.get("token", "")):
            log("  ws: token is not a live access token")
            self.close_connection = True
            return self.answer(403, b"", "text/plain")
        accept = base64.b64encode(hashlib.sha1(
            (self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        log("  ws: open")
        self.close_connection = True
        self.event("gateway.ready", None, {"session_authority": True, "heartbeat": True})
        try:
            while True:
                opcode, data = self.frame()
                if opcode == 8:
                    self.send_frame(8, data[:2])
                    break
                if opcode == 9:
                    self.send_frame(10, data)
                elif opcode == 1:
                    self.rpc(json.loads(data))
        except (ConnectionError, OSError, ValueError) as exc:
            log("  ws: closed", type(exc).__name__)
        log("  ws: done")

    def read_exact(self, count):
        data = b""
        while len(data) < count:
            chunk = self.rfile.read(count - len(data))
            if not chunk:
                raise ConnectionError("eof")
            data += chunk
        return data

    def frame(self):
        """One whole message; continuation frames are joined."""
        message, first = b"", None
        while True:
            head = self.read_exact(2)
            fin, opcode = head[0] & 0x80, head[0] & 0x0F
            length = head[1] & 0x7F
            if length == 126:
                length = struct.unpack(">H", self.read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self.read_exact(8))[0]
            mask = self.read_exact(4) if head[1] & 0x80 else b""
            data = self.read_exact(length)
            if mask:
                data = bytes(byte ^ mask[i % 4] for i, byte in enumerate(data))
            if opcode >= 8:
                return opcode, data
            first = opcode if first is None else first
            message += data
            if fin:
                return first, message

    def hand_over(self, session_id, text):
        """詩音 hands a card to 课程 with kanban_create, streamed as Hermes streams a tool call: its
        args at the start, its result (the card's id, as the tool's JSON text) at the end. The
        transcript keeps the call without its result, as Hermes's does. A few seconds later 课程's
        worker finishes the card, and the chat's subscription to it brings the board's notice: a
        status line, then a turn of its own in the user's name."""
        title, assignee, call = "整理第8回笔记（CI）", "study", "call-ci-kanban"
        args = {"title": title, "assignee": assignee, "body": "把第8回的录音和课件整理成笔记。"}
        tid = fake_kanban.assistant_creates("study", title, assignee, "shion", body=args["body"])
        reply = "交给课程了。"
        with lock:
            rows = transcripts.setdefault(session_id, [])
            rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "user", "text": text,
                         "timestamp": time.time()})
            rows.append({"row_kind": "message", "role": "tool", "name": "kanban_create", "context": title,
                         "args": args, "tool_call_id": call, "timestamp": time.time()})
            rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "assistant", "text": reply,
                         "timestamp": time.time()})
        self.event("message.start", session_id, {})
        self.event("tool.start", session_id, {"tool_id": call, "name": "kanban_create", "context": title, "args": args})
        self.event("tool.complete", session_id, {
            "tool_id": call, "name": "kanban_create",
            "result": json.dumps({"ok": True, "task_id": tid, "status": "ready", "gated": False})})
        self.event("message.delta", session_id, {"text": reply})
        self.event("message.complete", session_id, {"text": reply, "status": "complete"})
        threading.Timer(4.0, self.card_done, args=(session_id, tid, title)).start()

    def card_done(self, session_id, tid, title):
        fake_kanban.worker_completes("study", tid, "笔记整理好了。")
        notice = f"✔ [study] @study Kanban {tid} done — {title}"
        reply = "课程把笔记整理好了。"
        with lock:
            rows = transcripts.setdefault(session_id, [])
            rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "user", "text": notice,
                         "timestamp": time.time()})
            rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "assistant", "text": reply,
                         "timestamp": time.time()})
        log(f"  -> kanban notice on {session_id}: {notice}")
        try:
            self.event("status.update", session_id, {"kind": "process", "text": notice})
            self.event("message.start", session_id, {})
            self.event("message.delta", session_id, {"text": reply})
            self.event("message.complete", session_id, {"text": reply, "status": "complete"})
        except OSError:
            pass

    HOMEWORK_CALLS = (("call-ci-hw-1", "web_search", "这周的作业（CI）"),
                      ("call-ci-hw-2", "read_file", "syllabus（CI）"),
                      ("call-ci-hw-3", "web_extract", "moodle.example（CI）"))
    HOMEWORK_REPLY = ("这周要交的有两项：\n\n"
                      "| 作业 | 截止 | 进度 |\n"
                      "| :-- | :-: | --: |\n"
                      "| 实验报告（CI） | 周三 17:00（CI） | 50% |\n"
                      "| 作业5（CI） | 周五 23:59 | 0% |\n\n"
                      "先写**实验报告**，周三前交。")

    def homework(self, session_id, text):
        """詩音 looks the week's work up with three tool calls, then replies with a table: streamed
        as Hermes streams a turn, a moment between events so the calls can be seen while it runs
        (each call's args at its start, its result at its end; the reply a paragraph at a time).
        The transcript keeps the calls, without row ids or results, as Hermes's does."""
        with lock:
            rows = transcripts.setdefault(session_id, [])
            rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "user", "text": text,
                         "timestamp": time.time()})
            for call, name, context in self.HOMEWORK_CALLS:
                rows.append({"row_kind": "message", "role": "tool", "name": name, "context": context,
                             "tool_call_id": call, "timestamp": time.time()})
            rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "assistant",
                         "text": self.HOMEWORK_REPLY, "timestamp": time.time()})
        threading.Thread(target=self.homework_turn, args=(session_id,), daemon=True).start()

    def homework_turn(self, session_id):
        try:
            self.event("message.start", session_id, {})
            for call, name, context in self.HOMEWORK_CALLS:
                time.sleep(0.8)
                self.event("tool.start", session_id, {"tool_id": call, "name": name, "context": context,
                                                      "args": {"query": context}})
                time.sleep(0.4)
                self.event("tool.complete", session_id, {"tool_id": call, "name": name,
                                                         "result": json.dumps({"ok": True}, ensure_ascii=False)})
            parts = self.HOMEWORK_REPLY.split("\n\n")
            for index, part in enumerate(parts):
                time.sleep(0.5)
                self.event("message.delta", session_id, {"text": part + ("\n\n" if index < len(parts) - 1 else "")})
            self.event("message.complete", session_id, {"text": self.HOMEWORK_REPLY, "status": "complete"})
            log(f"  -> homework turn on {session_id}: {len(self.HOMEWORK_CALLS)} tool calls and a table")
        except OSError:
            pass

    def raise_approval(self, session_id):
        log(f"  -> approval.request on {session_id}")
        try:
            self.event("session.info", session_id, {"running": True})
            self.event("approval.request", session_id, APPROVAL)
        except OSError:
            pass

    def send_frame(self, opcode, data):
        head = bytearray([0x80 | opcode])
        if len(data) < 126:
            head.append(len(data))
        elif len(data) < 65536:
            head.append(126)
            head += struct.pack(">H", len(data))
        else:
            head.append(127)
            head += struct.pack(">Q", len(data))
        # replies come from the socket's thread, a timer's events from another
        with self.write_lock:
            self.wfile.write(bytes(head) + data)
            self.wfile.flush()

    def send_json(self, value):
        self.send_frame(1, json.dumps(value, ensure_ascii=False).encode())

    def event(self, kind, session_id, payload):
        params = {"type": kind, "payload": payload}
        if session_id:
            params["session_id"] = session_id
        self.send_json({"jsonrpc": "2.0", "method": "event", "params": params})

    def snapshot(self, session_id, params):
        """session.resume's reply: no rows with omit_messages, every row projected with
        display_projection, raw rows otherwise."""
        with lock:
            rows = list(transcripts.setdefault(session_id, []))
        reply = {"session_id": session_id, "running": False, "prompts": [], "message_count": len(rows),
                 **fake_control.snapshot_fences(session_id)}
        if params.get("omit_messages") is True:
            return {**reply, "messages": [], "messages_omitted": True}
        shown = [{k: v for k, v in row.items() if k != "row_kind"} for row in rows if row["row_kind"] == "message"]
        reply["messages"] = shown
        if params.get("display_projection"):
            reply["display_messages"] = shown
        return reply

    def transcript(self, params):
        """session.transcript in latest order: newest page first, then older ones by cursor."""
        session_id, limit = params.get("session_id", ""), params.get("limit", 100)
        order, cursor = params.get("order", "oldest"), params.get("cursor")
        # as gateway/session_stored_reads.py: `type(limit) is int`, so 50.0 (or true) is refused
        if type(limit) is not int or not 1 <= limit <= 500 or order not in ("oldest", "latest"):
            return None, ["limit" if type(limit) is not int or not 1 <= limit <= 500 else "order"]
        if order != "latest":
            return None, ["order"]  # the stand-in only pages newest first, as Shion does
        with lock:
            rows = list(transcripts.get(session_id, []))
        end = len(rows)
        if cursor is not None:
            prefix = f"c:{session_id}:latest:"
            if not isinstance(cursor, str) or not cursor.startswith(prefix):
                return None, ["cursor"]
            end = int(cursor[len(prefix):])
        begin = max(0, end - limit)
        page = rows[begin:end]
        log(f"    transcript rows {begin}..{end - 1} of {len(rows)}" + (" (first page)" if cursor is None else ""))
        return {"session_id": session_id, "rows": page, "reset": cursor is None,
                "next_cursor": f"c:{session_id}:latest:{begin}" if begin > 0 else None}, None

    def refuse(self, rid, fields):
        log(f"    invalid_params {fields}")
        self.send_json({"jsonrpc": "2.0", "id": rid, "error": {
            "code": 4001, "message": "invalid_params", "data": {"reason": "invalid_params", "fields": fields}}})

    def rpc(self, request):
        method, params, rid = request.get("method", ""), request.get("params") or {}, request.get("id")
        if method != "gateway.ping":
            log(f"  rpc {method} {json.dumps(params, ensure_ascii=False)[:160]}")
        if fake_control.handles(method, params):
            return fake_control.handle(self, method, params, rid)
        if method.startswith("plugin.shion."):
            return fake_shion.handle(self, log, method, params, rid)
        result = None
        if method == "client.capabilities":
            result = {"server_requests": True}
        elif method == "gateway.ping":
            result = {"pong": True}
        elif method == "profiles.list":
            result = {"profiles": [
                {"name": "shion", "display_name": "詩音", "description": "", "is_default": True, "ui_meta": {}},
                {"name": "study", "display_name": "study", "description": "课程", "is_default": False,
                 "ui_meta": {"hermes-bots": {"title": "课程（CI）"}}},
                {"name": "commute", "display_name": "通勤（CI）", "description": "通勤", "is_default": False,
                 "ui_meta": {}},
            ]}
        elif method == "runtime.describe":
            if params:
                return self.refuse(rid, sorted(params))
            result = {"instance_id": "ci", "profile_id": "/ci/.hermes", "authority_epoch": 1,
                      "capabilities": ["durable-admission-v1", "event-replay-v1", "plugin-rpc-v1",
                                       "session-client-v1", "session-transcript-v1"],
                      "session_create": {"sources": sorted(SURFACES),
                                         "parameters": sorted(CREATE_KEYS - {"hidden", "profile"})}}
        elif method == "session.list":
            if type(params.get("limit", 200)) is not int:
                return self.refuse(rid, ["limit"])
            with lock:
                known = sessions.get(params.get("profile"))
            result = {"sessions": [{"id": known, "title": "Bot Chat", "root_title": "Bot Chat"}] if known else []}
        elif method == "session.resume":
            unknown = sorted(set(params) - RESUME_KEYS)
            if unknown:
                return self.refuse(rid, unknown)
            result = self.snapshot(params.get("session_id", ""), params)
            if params.get("session_id") == "sess-study" and "sess-study" not in approvals_raised:
                # 课程 wants a login on its cloud desktop, a moment after Shion attaches
                approvals_raised.add("sess-study")
                threading.Timer(2.0, self.raise_approval, args=("sess-study",)).start()
        elif method == "session.create":
            unknown = sorted(set(params) - CREATE_KEYS)
            if unknown:
                return self.refuse(rid, unknown)
            source, client = params.get("source", "cli"), params.get("client")
            if source not in SURFACES:
                return self.refuse(rid, ["source"])
            if client is not None and not (
                    isinstance(client, dict) and set(client) <= {"name", "version"}
                    and CLIENT_NAME.fullmatch(str(client.get("name", "")))
                    and ("version" not in client or CLIENT_VERSION.fullmatch(str(client["version"])))):
                return self.refuse(rid, ["client"])
            log(f"    created as {source} -> the assistant is told: {SURFACES[source]}; client {client}")
            profile = params.get("profile", "shion")
            with lock:
                session_id = sessions.setdefault(profile, f"sess-{profile}")
                transcripts.setdefault(session_id, [{"row_id": 1, "row_kind": "message", "role": "assistant",
                                                     "text": "新的 Bot Chat。", "timestamp": time.time()}])
            result = self.snapshot(session_id, {})
        elif method == "session.transcript":
            unknown = sorted(set(params) - TRANSCRIPT_KEYS)
            if unknown:
                return self.refuse(rid, unknown)
            result, bad = self.transcript(params)
            if bad:
                return self.refuse(rid, bad)
        elif method in ("approval.respond", "clarify.respond"):
            unknown = sorted(set(params) - RESPOND_KEYS)
            if unknown:
                return self.refuse(rid, unknown)
            log(f"    answered {params.get('prompt_id')} for {params.get('profile')}: "
                f"{params.get('choice', params.get('answer'))!r}")
            self.send_json({"jsonrpc": "2.0", "id": rid, "result": {"accepted": True}})
            kind = "approval.settled" if method == "approval.respond" else "clarify.settled"
            self.event(kind, params.get("session_id"), {"prompt_id": params.get("prompt_id")})
            self.event("session.info", params.get("session_id"), {"running": False})
            return
        elif method == "prompt.submit":
            self.send_json({"jsonrpc": "2.0", "id": rid, "result": {"accepted": True}})
            session_id, text = params.get("session_id"), params.get("text", "")
            if "派一张卡" in text:
                return self.hand_over(session_id, text)
            if "这周的作业" in text:
                return self.homework(session_id, text)
            with lock:
                rows = transcripts.setdefault(session_id, [])
                rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "user", "text": text,
                             "timestamp": time.time()})
                rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "assistant",
                             "text": "收到：" + text, "timestamp": time.time()})
            self.event("message.start", session_id, {})
            self.event("message.delta", session_id, {"text": "收到："})
            self.event("message.delta", session_id, {"text": text})
            self.event("message.complete", session_id, {"text": "收到：" + text, "status": "complete"})
            return
        if result is None:
            self.send_json({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"no method {method}"}})
        else:
            self.send_json({"jsonrpc": "2.0", "id": rid, "result": result})


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # HTTPServer looks its own address up in DNS (socket.getfqdn), which took half a minute on a
        # runner; the name is only used in log lines
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    fake_kanban.setup(log, valid_access)
    fake_control.setup(log, transcripts, lock)
    server = Server(("127.0.0.1", args.port), Handler)
    log(f"stand-in Hermes on http://127.0.0.1:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
