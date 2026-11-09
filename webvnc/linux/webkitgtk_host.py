#!/usr/bin/env python3
"""The web viewer in WebKitGTK: the nearest thing to WKWebView on Linux (the same WebKit engine,
JavaScriptCore, the same ``window.webkit.messageHandlers`` bridge, a custom URL scheme serving the
page from disk). Not the same as WKWebView: different graphics stack, process model and sandbox.

One run, one JSON line on stdout:

    webkitgtk_host.py --check                         page loads? secure context? CSP?
    webkitgtk_host.py --relay URL --protocol P        through the loopback relay (option A)
    webkitgtk_host.py --channel                       through this process (option C); upstream from
                                                      WEBVNC_UPSTREAM, Access headers from WEBVNC_HEADER_1..9
      [--hold] [--seconds N] [--type TEXT] [--keys TEXT] [--insecure-scheme]
      [--until-updates N]                             measure: time until N updates are decoded

``--keys`` types with real key events (xdotool on this process's own X display) after clicking the
picture; ``--type`` uses the page's clipboard + Ctrl+V path. Needs python3-gi, gir1.2-webkit-6.0 and,
for --channel, websockets (a venv made with --system-site-packages).
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import mimetypes
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("WebKit", "6.0")
gi.require_version("Soup", "3.0")
from gi.repository import Gio, GLib, Gtk, Soup, WebKit  # noqa: E402

WEB = Path(__file__).resolve().parents[1] / "web"
SCHEME = "shion-webvnc"
CSP_HEADER = {
    # what the app would send on top of the page's own meta policy
    "relay": "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; connect-src ws://127.0.0.1:*",
    "channel": "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; connect-src 'none'",
}

p = argparse.ArgumentParser()
p.add_argument("--check", action="store_true")
p.add_argument("--relay")
p.add_argument("--protocol")
p.add_argument("--channel", action="store_true")
p.add_argument("--hold", action="store_true", help="connect as the lease holder (input allowed)")
p.add_argument("--seconds", type=float, default=3)
p.add_argument("--type", dest="type_text")
p.add_argument("--keys")
p.add_argument("--insecure-scheme", action="store_true", help="do not register the scheme as secure")
p.add_argument("--until-updates", type=int, default=0)
p.add_argument("--timeout", type=float, default=40)
args = p.parse_args()
mode = "channel" if args.channel else "relay"

result: dict = {"engine": f"WebKitGTK {WebKit.get_major_version()}.{WebKit.get_minor_version()}.{WebKit.get_micro_version()}"}
messages: list[dict] = []
started = time.monotonic()


def tree_cpu() -> float:
    """CPU seconds of this process and its descendants (WebKit's web and network processes)."""
    parents = {}
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                with open(f"/proc/{entry}/stat") as f:
                    fields = f.read().rsplit(")", 1)[1].split()
                parents[int(entry)] = (int(fields[1]), (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK"))
            except OSError:
                pass
    mine, total = {os.getpid()}, 0.0
    changed = True
    while changed:
        changed = False
        for pid, (ppid, _) in parents.items():
            if ppid in mine and pid not in mine:
                mine.add(pid)
                changed = True
    for pid in mine:
        total += parents.get(pid, (0, 0.0))[1]
    return total


def emit_and_quit(code=0):
    result["messages"] = [m.get("type") + (f":{m['state']}" if "state" in m else "") for m in messages][:40]
    print(json.dumps(result, ensure_ascii=False), flush=True)
    os._exit(code)


# ---------------------------------------------------------------- the page from disk

def serve(request: WebKit.URISchemeRequest) -> None:
    path = request.get_path() or "/"
    file = (WEB / path.lstrip("/")).resolve()
    if WEB.resolve() not in file.parents or not file.is_file():
        request.finish_error(GLib.Error.new_literal(Gio.io_error_quark(), "not found", Gio.IOErrorEnum.NOT_FOUND))
        return
    data = file.read_bytes()
    stream = Gio.MemoryInputStream.new_from_bytes(GLib.Bytes.new(data))
    response = WebKit.URISchemeResponse.new(stream, len(data))
    mime = {".js": "text/javascript", ".html": "text/html", ".css": "text/css"}.get(file.suffix) or mimetypes.guess_type(file.name)[0] or "application/octet-stream"
    response.set_content_type(mime)
    if file.suffix == ".html":
        headers = Soup.MessageHeaders.new(Soup.MessageHeadersType.RESPONSE)
        headers.append("Content-Security-Policy", CSP_HEADER[mode])
        response.set_http_headers(headers)
    request.finish_with_response(response)


# ---------------------------------------------------------------- option C: the upstream socket here

class Channel:
    def __init__(self, view: WebKit.WebView):
        self.view = view
        self.loop = asyncio.new_event_loop()
        self.ws = None
        self.queue: list[bytes] = []
        self.flushing = False
        self.stats = {"batches": 0, "bytes_down": 0, "bytes_up": 0, "close": None}
        threading.Thread(target=self.loop.run_forever, daemon=True).start()

    def start(self) -> None:
        asyncio.run_coroutine_threadsafe(self.run(), self.loop)

    async def run(self) -> None:
        from websockets.asyncio.client import connect
        headers = []
        for i in range(1, 10):
            line = os.environ.get(f"WEBVNC_HEADER_{i}")
            if line:
                k, _, v = line.partition(":")
                headers.append((k.strip(), v.strip()))
        try:
            self.ws = await connect(os.environ["WEBVNC_UPSTREAM"], additional_headers=headers, max_size=None,
                                    compression=None, ping_interval=None, user_agent_header=None)
        except Exception as exc:  # refused / unreachable
            code = 4403 if "403" in str(exc) else 4502
            GLib.idle_add(self.js, "shionVNC.channelClosed(c, '')", {"c": GLib.Variant("i", code)})
            return
        GLib.idle_add(self.js, "shionVNC.channelOpened()", {})
        try:
            async for message in self.ws:
                self.stats["bytes_down"] += len(message)
                GLib.idle_add(self.push, bytes(message))
        except Exception:
            pass
        code = self.ws.close_code or 1006
        self.stats["close"] = code
        GLib.idle_add(self.closed, code, self.ws.close_reason or "")

    def push(self, data: bytes) -> bool:
        self.queue.append(data)
        self.flush()
        return False

    def flush(self) -> None:
        if self.flushing or not self.queue:
            return
        batch = [base64.b64encode(m).decode() for m in self.queue]   # one string per bridge message
        self.queue = []
        self.flushing = True
        self.stats["batches"] += 1
        # WebKitGTK passes numbers, strings and dictionaries as arguments, not arrays: the batch goes
        # as one comma-separated string (base64 has no commas)
        self.view.call_async_javascript_function(
            "shionVNC.channelReceived(b.split(','))", -1,
            GLib.Variant("a{sv}", {"b": GLib.Variant("s", ",".join(batch))}),
            None, None, None, self.flushed)

    def flushed(self, view, res) -> None:
        try:
            view.call_async_javascript_function_finish(res)
        except GLib.Error:
            pass
        self.flushing = False
        self.flush()

    def closed(self, code: int, reason: str) -> bool:
        if self.queue or self.flushing:
            GLib.timeout_add(5, self.closed, code, reason)
            return False
        self.js("shionVNC.channelClosed(c, r)", {"c": GLib.Variant("i", code), "r": GLib.Variant("s", reason)})
        return False

    def js(self, body: str, arguments: dict) -> bool:
        self.view.call_async_javascript_function(body, -1, GLib.Variant("a{sv}", arguments), None, None, None, None)
        return False

    def page_message(self, m: dict) -> None:
        if m.get("type") == "send" and self.ws is not None:
            data = base64.b64decode(m["data"])
            self.stats["bytes_up"] += len(data)
            asyncio.run_coroutine_threadsafe(self.ws.send(data), self.loop)
        elif m.get("type") == "close" and self.ws is not None:
            code = m.get("code")
            if code in (1000, 1001):
                asyncio.run_coroutine_threadsafe(self.ws.close(code), self.loop)
            else:
                self.loop.call_soon_threadsafe(self.ws.transport.abort)


# ---------------------------------------------------------------- the window

def on_activate(app: Gtk.Application) -> None:
    window = Gtk.ApplicationWindow(application=app, default_width=1440, default_height=900, title="webvnc")
    manager = WebKit.UserContentManager()
    manager.register_script_message_handler("shion", None)
    context = WebKit.WebContext.get_default()
    context.register_uri_scheme(SCHEME, serve)
    if not args.insecure_scheme:
        context.get_security_manager().register_uri_scheme_as_secure(SCHEME)
    view = WebKit.WebView(user_content_manager=manager, web_context=context)
    settings = view.get_settings()
    settings.set_enable_developer_extras(False)
    window.set_child(view)
    window.present()
    channel = Channel(view) if args.channel else None
    state = {"connected_at": None}

    def call(body: str, done=None) -> None:
        """Runs `body` as an async function body in the page (awaits a returned promise)."""
        def finished(v, res):
            try:
                value = v.call_async_javascript_function_finish(res)
                out = json.loads(value.to_json(0)) if value is not None and not value.is_undefined() else None
            except GLib.Error as exc:
                out = {"error": exc.message}
            if done:
                done(out)
        view.call_async_javascript_function(body, -1, None, None, None, None, finished)

    def on_message(_manager, value) -> None:
        m = json.loads(value.to_json(0))
        m["t"] = round((time.monotonic() - started) * 1000)
        messages.append(m)
        if channel:
            channel.page_message(m)
        kind = m.get("type")
        if kind == "ready":
            result["ready"] = {k: m[k] for k in ("secureContext", "subtleCrypto", "nativeBase64", "origin")}
            if args.check:
                call("""
                    let fetchBlocked = false
                    try { await fetch('https://example.com/') } catch { fetchBlocked = true }
                    const s = document.createElement('script'); s.textContent = 'window.__inline = 1'; document.head.append(s)
                    await new Promise(r => setTimeout(r, 200))
                    return { fetchBlocked, inlineRan: !!window.__inline, ua: navigator.userAgent.slice(0, 120) }
                """, lambda out: (result.update(csp=out), emit_and_quit(0)))
                return
            options = {"viewOnly": not args.hold, "debugKeys": bool(args.keys)}
            if channel:
                options["transport"] = "channel"
            else:
                options.update(transport="relay", url=args.relay, protocols=[args.protocol])
            # the channel opens only once the page has made its HostChannel (connect() returned)
            call(f"return window.shionVNC.connect({json.dumps(options)})",
                 lambda _: channel.start() if channel else None)
        elif kind == "firstFrame":
            result["firstFrameMs"] = m["ms"]
            if args.until_updates:
                state["t0"], state["cpu0"], state["last"], state["since"] = time.monotonic(), tree_cpu(), -1, time.monotonic()
                GLib.timeout_add(50, poll_updates)
            else:
                GLib.timeout_add(int(args.seconds * 1000), finish)
            if args.type_text:
                GLib.timeout_add(500, lambda: (call(f"return window.shionVNC.typeText({json.dumps(args.type_text)})",
                                                    lambda out: result.update(typed=out)), False)[1])
            if args.keys:
                GLib.timeout_add(500, real_keys)
        elif kind == "state" and m.get("state") == "disconnected" and "report" not in result:
            result["closed"] = {"code": m.get("code"), "reason": m.get("reason")}
            finish()

    def real_keys() -> bool:
        # Real X key events into this window (a window manager must give it the focus): click the
        # picture (the page focuses its IME textarea and noVNC clicks the remote), then type.
        found = subprocess.run(["xdotool", "search", "--name", "^webvnc$"], capture_output=True, text=True)
        wid = (found.stdout.split() or [""])[0]
        if wid:
            subprocess.run(["xdotool", "windowactivate", "--sync", wid], capture_output=True)
            subprocess.run(["xdotool", "mousemove", "--window", wid, "300", "200", "click", "1"], capture_output=True)
        time.sleep(0.4)
        r = subprocess.run(["xdotool", "type", "--delay", "40", args.keys], capture_output=True)
        result["keys"] = {"window": bool(wid), "xdotool": r.returncode}
        return False

    def poll_updates() -> bool:
        def got(report):
            n = (report or {}).get("updates", 0)
            now = time.monotonic()
            if n != state["last"]:
                state["last"], state["since"] = n, now
            if n >= args.until_updates or now - state["since"] > 3:
                result["decode"] = {"updates": n, "seconds": round(now - state["t0"], 2),
                                    "cpu": round(tree_cpu() - state["cpu0"], 2), "bytesIn": (report or {}).get("bytesIn")}
                finish()
            else:
                GLib.timeout_add(50, poll_updates)
        call("return window.shionVNC.report()", got)
        return False

    def finish() -> bool:
        def got(report):
            result["report"] = report
            if channel:
                result["channel"] = channel.stats
            call("return window.shionVNC.disconnect(true)", lambda _: GLib.timeout_add(500, lambda: emit_and_quit(0)))
        call("return window.shionVNC.report()", got)
        return False

    manager.connect("script-message-received::shion", on_message)
    view.load_uri(f"{SCHEME}://app/viewer.html")
    GLib.timeout_add(int(args.timeout * 1000), lambda: (result.update(error="timeout"), emit_and_quit(2)))


app = Gtk.Application(application_id=None, flags=Gio.ApplicationFlags.NON_UNIQUE)
app.connect("activate", on_activate)
app.run([])
