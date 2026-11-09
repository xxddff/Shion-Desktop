#!/usr/bin/env python3
"""Loopback relay between the cloud-desktop page and Hermes' display bridge (option A), for the
Linux tests. The macOS shell has the same thing in Swift (macos/Sources/WebVNCShell/Relay.swift),
and the two behave the same:

- listens on 127.0.0.1, an ephemeral port, and nowhere else;
- accepts ONE WebSocket: its offered subprotocols must include ``shion.<token>`` (a 128-bit
  random token the app made for this page, compared in constant time) and its Origin must be the
  page's. Anything else gets HTTP 403. After that one connection the listener closes; if no page
  comes within RELAY_ACCEPT_TIMEOUT seconds it gives up;
- dials the real bridge with the Access headers, forwards the bytes both ways and passes the
  bridge's close code back to the page (4000 control taken, 4401 ticket, 4001 desktop gone, 1003,
  1000). Upgrade refused upstream (Access or the bridge: HTTP 403) -> the page gets 4403; gateway
  not reachable -> 4502;
- a clean close from the page (1000 / 1001) is passed on, so the bridge hands the lease back. The
  page going away without one (no status, or the WebView died) drops the upstream link without a
  close frame, so the bridge keeps a held lease, exactly as for a browser that lost its network.

Environment (never the command line, which other processes can read):
  RELAY_UPSTREAM        ws:// or wss:// URL of the bridge, with ?display_ticket=
  RELAY_TOKEN           hex token; the page offers subprotocol "shion.<token>"
  RELAY_ORIGINS         allowed Origin values, space separated ("" = any; the tests always set it)
  RELAY_HEADER_1..9     "Name: value" headers for the upstream upgrade (the Access service token)
  RELAY_ACCEPT_TIMEOUT  seconds to wait for the page (default 30)
  RELAY_RECORD          tests only: write what the bridge sent to this file, message by message
                        (zlib of u32 length + bytes, repeated), for linux/replay_messages.py

Prints ``port N`` on stdout once listening, then one JSON line with what happened. Never prints
the upstream query, the token or header values.
"""

from __future__ import annotations

import asyncio
import hmac
import json
import os
import sys
import time
import urllib.parse
import zlib

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.exceptions import ConnectionClosed, InvalidStatus
from websockets.http11 import Response

CLEAN = {1000, 1001}
UPSTREAM_REFUSED = 4403
UPSTREAM_UNREACHABLE = 4502


def forbidden() -> Response:
    return Response(403, "Forbidden", Headers([("Content-Length", "0"), ("Connection", "close")]), b"")


def redacted(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))


async def main() -> int:
    upstream = os.environ["RELAY_UPSTREAM"]
    token = os.environ["RELAY_TOKEN"]
    origins = set(os.environ.get("RELAY_ORIGINS", "").split())
    accept_timeout = float(os.environ.get("RELAY_ACCEPT_TIMEOUT", "30"))
    headers = []
    for i in range(1, 10):
        line = os.environ.get(f"RELAY_HEADER_{i}")
        if line:
            name, _, value = line.partition(":")
            headers.append((name.strip(), value.strip()))
    want = "shion." + token
    record = os.environ.get("RELAY_RECORD")
    recorded = bytearray()
    report = {"upstream": redacted(upstream), "rejected": 0, "reject_reasons": [], "origin": None,
              "down_bytes": 0, "down_msgs": 0, "up_bytes": 0, "up_msgs": 0,
              "page_close": None, "upstream_close": None, "sent_page": None, "sent_upstream": None}
    taken = asyncio.Event()
    finished = asyncio.Event()

    def process_request(connection, request):
        offered = [p.strip() for v in request.headers.get_all("Sec-WebSocket-Protocol") for p in v.split(",")]
        origin = request.headers.get("Origin")
        reason = None
        if taken.is_set():
            reason = "second connection"
        elif not any(hmac.compare_digest(p.encode(), want.encode()) for p in offered):
            reason = "no token"
        elif origins and origin not in origins:
            reason = "origin"
        if reason:
            report["rejected"] += 1
            report["reject_reasons"].append(reason)
            return forbidden()
        taken.set()
        report["origin"] = origin
        return None

    def select_subprotocol(connection, subprotocols):
        return want if want in subprotocols else None

    async def handler(page) -> None:
        try:
            await relay(page)
        except Exception as exc:  # report, never hang the caller
            report["error"] = f"{type(exc).__name__}: {exc}"[:200]
        finally:
            finished.set()

    async def relay(page) -> None:
        server.close(close_connections=False)   # one page only: stop listening
        started = time.monotonic()
        try:
            up = await connect(upstream, additional_headers=headers, max_size=None, compression=None,
                               open_timeout=10, user_agent_header=None, ping_interval=None)
        except InvalidStatus as exc:
            report["upstream_refused"] = exc.response.status_code
            report["sent_page"] = UPSTREAM_REFUSED
            await page.close(UPSTREAM_REFUSED, "upstream refused the upgrade")
            return
        except (OSError, asyncio.TimeoutError) as exc:
            report["upstream_error"] = type(exc).__name__
            report["sent_page"] = UPSTREAM_UNREACHABLE
            await page.close(UPSTREAM_UNREACHABLE, "gateway not reachable")
            return

        ended = {}   # which side went first: "bridge" or "page"

        async def down() -> None:
            try:
                async for message in up:
                    report["down_bytes"] += len(message)
                    report["down_msgs"] += 1
                    if record:
                        recorded.extend(len(message).to_bytes(4, "big"))
                        recorded.extend(message)
                    try:
                        await page.send(message)
                    except ConnectionClosed:
                        ended.setdefault("by", "page")
                        return
            except ConnectionClosed:
                pass
            ended.setdefault("by", "bridge")

        async def upward() -> None:
            try:
                async for message in page:
                    report["up_bytes"] += len(message)
                    report["up_msgs"] += 1
                    try:
                        await up.send(message)
                    except ConnectionClosed:
                        ended.setdefault("by", "bridge")
                        return
            except ConnectionClosed:
                pass
            ended.setdefault("by", "page")

        tasks = {asyncio.create_task(down()), asyncio.create_task(upward())}
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

        # close_code: what the other side's close frame said; 1005 = a frame without a code,
        # 1006 = no frame at all (the link dropped)
        if ended.get("by") == "bridge":
            # The bridge ended it: hand its code to the page, or drop the page if it had none.
            code = up.close_code
            report["upstream_close"] = code
            if code is None or code in (1005, 1006):
                page.transport.abort()
                report["sent_page"] = "abort"
            else:
                report["sent_page"] = code
                await page.close(code, up.close_reason or "")
        else:
            code = page.close_code
            report["page_close"] = code
            if code in CLEAN:
                report["sent_upstream"] = code
                await up.close(code, page.close_reason or "")
            else:
                # no status, or the page vanished: a dropped link, the bridge keeps the lease
                up.transport.abort()
                report["sent_upstream"] = "abort"
        report["duration_s"] = round(time.monotonic() - started, 3)

    async with serve(handler, "127.0.0.1", 0, process_request=process_request,
                     select_subprotocol=select_subprotocol, max_size=None, compression=None,
                     ping_interval=None, server_header=None) as server:
        port = next(iter(server.sockets)).getsockname()[1]
        print(f"port {port}", flush=True)
        try:
            await asyncio.wait_for(taken.wait(), accept_timeout)
        except asyncio.TimeoutError:
            report["error"] = "no page connected"
        else:
            await finished.wait()
    if record and recorded:
        with open(record, "wb") as f:
            f.write(zlib.compress(bytes(recorded), 9))
        report["recorded"] = len(recorded)
    report["cpu_s"] = round(time.process_time(), 3)
    print(json.dumps(report), flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        sys.exit(130)
