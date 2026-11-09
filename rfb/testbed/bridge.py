#!/usr/bin/env python3
"""A stand-in for Hermes' display bridge (hermes_cli/web_routers/display.py), for local testing.

It splices a WebSocket to Xvnc's RFB Unix socket and runs the client stream through Hermes' own
RfbClientFilter (vendored unchanged in ./hermes/rfb_filter.py), so message framing, the input gate
and the clipboard cap behave exactly as on the server. What it copies from display.py:

- the ticket rides in ``?display_ticket=``; it is single-use and expires after 30 s;
- bad ticket -> accept, then close 4401; Xvnc not reachable -> 4001; text frame or a client message
  the filter rejects -> 1003; another viewer taking the lease -> 4000 ("control-taken");
- a clean close (1000/1001) by the lease holder releases the lease, a dropped link keeps it.

What stands in for the gateway's JSON-RPC (display.observe, display.lease.*): a small HTTP API on the
same port, for scripts and tests (never put it on a public interface):

    GET  /observe[?viewer_id=…]        -> {"ticket", "path", "viewer_id"}   (like display.observe)
    GET  /lease/acquire?viewer_id=…    -> lease JSON                         (display.lease.acquire)
    GET  /lease/release[?viewer_id=…]  -> lease JSON                         (display.lease.release)
    GET  /lease                        -> lease JSON

``--require-header NAME`` (repeatable) refuses the upgrade with HTTP 403 unless the request carries
that header, the way Cloudflare Access refuses a request without the service-token headers. Header
values and tickets are never printed.

``--latency-ms N`` delays every chunk by N/2 ms in each direction (N ms round trip), to see how the
client behaves over a slow path like Cloudflare's.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import http
import json
import os
import secrets
import sys
import time
import urllib.parse
from pathlib import Path

import websockets
from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.http11 import Response

sys.path.insert(0, str(Path(__file__).resolve().parent / "hermes"))
from rfb_filter import RfbClientFilter  # noqa: E402

CLOSE_CONTROL_TAKEN = 4000
CLOSE_DESKTOP_GONE = 4001
CLOSE_BAD_TICKET = 4401
CLOSE_PROTOCOL = 1003
CLEAN_CLOSE = {1000, 1001}
TICKET_TTL_S = 30.0
READ_CHUNK = 64 * 1024


class Lease:
    def __init__(self) -> None:
        self.holder = "agent"
        self.viewer_id: str | None = None
        self.epoch = 0
        self.since = time.time()
        self.listeners: set = set()

    def as_json(self) -> dict:
        h = hashlib.sha256(self.viewer_id.encode()).hexdigest()[:12] if self.viewer_id else None
        return {"holder": self.holder, "viewer_id": None, "viewer_hash": h,
                "since": self.since, "epoch": self.epoch, "reason": ""}

    def set(self, holder: str, viewer_id: str | None) -> None:
        if (holder, viewer_id) == (self.holder, self.viewer_id):
            return
        self.holder, self.viewer_id = holder, viewer_id
        self.epoch += 1
        self.since = time.time()
        for cb in list(self.listeners):
            cb()


class State:
    def __init__(self, socket_path: str, required_headers: list[str], latency_ms: float = 0) -> None:
        self.socket_path = socket_path
        self.one_way_s = latency_ms / 2000.0
        self.required_headers = [h.lower() for h in required_headers]
        self.tickets: dict[str, tuple[float, str]] = {}
        self.lease = Lease()

    def mint(self, viewer_id: str | None) -> dict:
        viewer_id = viewer_id or secrets.token_urlsafe(16)
        ticket = secrets.token_urlsafe(24)
        self.tickets[ticket] = (time.monotonic() + TICKET_TTL_S, viewer_id)
        return {"ticket": ticket, "path": "/api/display/ws", "viewer_id": viewer_id,
                "lease": self.lease.as_json()}

    def consume(self, ticket: str) -> str | None:
        entry = self.tickets.pop(ticket, None)
        if entry is None or entry[0] < time.monotonic():
            return None
        return entry[1]


def json_response(status: int, body: dict) -> Response:
    data = json.dumps(body).encode()
    headers = Headers([("Content-Type", "application/json"), ("Content-Length", str(len(data)))])
    return Response(status, http.HTTPStatus(status).phrase, headers, data)


def make_process_request(state: State):
    def process_request(connection, request):
        url = urllib.parse.urlsplit(request.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        if url.path == "/api/display/ws":
            for name in state.required_headers:
                if not request.headers.get(name):
                    return json_response(403, {"error": f"missing header {name}"})
            return None  # proceed with the WebSocket upgrade
        # The control API is plain HTTP; websockets only hands us GETs, so the verb is in the path.
        if url.path == "/observe":
            return json_response(200, state.mint(query.get("viewer_id")))
        if url.path == "/lease":
            return json_response(200, state.lease.as_json())
        if url.path == "/lease/acquire":
            if not query.get("viewer_id"):
                return json_response(400, {"error": "viewer_id required"})
            state.lease.set("human", query["viewer_id"])
            return json_response(200, state.lease.as_json())
        if url.path == "/lease/release":
            vid = query.get("viewer_id")
            if vid and state.lease.viewer_id not in (None, vid):
                return json_response(409, {"error": "viewer_mismatch"})
            state.lease.set("agent", None)
            return json_response(200, state.lease.as_json())
        return json_response(404, {"error": "not found"})
    return process_request


async def handler(ws, state: State) -> None:
    url = urllib.parse.urlsplit(ws.request.path)
    ticket = dict(urllib.parse.parse_qsl(url.query)).get("display_ticket", "")
    viewer_id = state.consume(ticket) if ticket else None
    if viewer_id is None:
        await ws.close(CLOSE_BAD_TICKET, "display ticket missing, expired or used")
        return
    try:
        reader, writer = await asyncio.open_unix_connection(state.socket_path)
    except OSError:
        await ws.close(CLOSE_DESKTOP_GONE, "Bot Desktop is not running")
        return

    lease = state.lease
    held = {"ever": lease.holder == "human" and lease.viewer_id == viewer_id}
    evicted = asyncio.Event()

    def on_lease() -> None:
        if lease.holder != "human":
            held["ever"] = False
        elif lease.viewer_id == viewer_id:
            held["ever"] = True
        elif held["ever"]:
            evicted.set()
    lease.listeners.add(on_lease)

    def may_send_input() -> bool:
        return lease.holder == "human" and lease.viewer_id == viewer_id

    rfb_filter = RfbClientFilter(may_send_input)
    viewer_closed = asyncio.Event()
    stats = {"up": 0, "down": 0}
    loop = asyncio.get_running_loop()

    def delayed(send):
        """``send`` after the configured one-way delay, keeping order (a FIFO with deadlines)."""
        if not state.one_way_s:
            return send, None
        queue: asyncio.Queue = asyncio.Queue()

        async def pump() -> None:
            while True:
                due, data = await queue.get()
                wait = due - loop.time()
                if wait > 0:
                    await asyncio.sleep(wait)
                await send(data)

        async def enqueue(data) -> None:
            queue.put_nowait((loop.time() + state.one_way_s, data))
        return enqueue, asyncio.create_task(pump())

    async def to_xvnc(data: bytes) -> None:
        writer.write(data)
        await writer.drain()

    send_down, down_pump = delayed(ws.send)
    send_up, up_pump = delayed(to_xvnc)

    async def rfb_to_ws() -> None:
        while True:
            chunk = await reader.read(READ_CHUNK)
            if not chunk:
                return
            stats["down"] += len(chunk)
            await send_down(chunk)

    async def ws_to_rfb() -> None:
        while True:
            try:
                data = await ws.recv()
            except websockets.ConnectionClosed as exc:
                code = exc.rcvd.code if exc.rcvd else None
                if code in CLEAN_CLOSE:
                    viewer_closed.set()
                return
            if isinstance(data, str):
                await ws.close(CLOSE_PROTOCOL, "RFB is binary")
                return
            try:
                allowed = rfb_filter.feed(data)
            except ValueError as exc:
                await ws.close(CLOSE_PROTOCOL, str(exc)[:100])
                return
            stats["up"] += len(allowed)
            if allowed:
                await send_up(allowed)

    async def watch_eviction() -> None:
        await evicted.wait()
        await ws.close(CLOSE_CONTROL_TAKEN, "control-taken")

    tasks = [asyncio.create_task(rfb_to_ws()), asyncio.create_task(ws_to_rfb()),
             asyncio.create_task(watch_eviction())]
    tasks += [t for t in (down_pump, up_pump) if t is not None]
    try:
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in pending:
            t.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        for t in done:
            exc = t.exception()
            if exc and not isinstance(exc, (websockets.ConnectionClosed, ConnectionError)):
                print(f"bridge: viewer ended: {exc!r}", file=sys.stderr, flush=True)
    finally:
        lease.listeners.discard(on_lease)
        writer.close()
        try:
            await writer.wait_closed()
        except OSError:
            pass
        if viewer_closed.is_set() and may_send_input():
            lease.set("agent", None)
        await ws.close()
        print(f"bridge: viewer closed (code {ws.close_code}); {stats['down']} bytes down, "
              f"{stats['up']} bytes up", file=sys.stderr, flush=True)


async def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--socket", required=True, help="Xvnc RFB Unix socket (-rfbunixpath)")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--require-header", action="append", default=[], metavar="NAME")
    p.add_argument("--latency-ms", type=float, default=0, help="added round-trip time")
    args = p.parse_args()
    state = State(args.socket, args.require_header, args.latency_ms)
    async with serve(lambda ws: handler(ws, state), args.host, args.port,
                     process_request=make_process_request(state), max_size=None,
                     compression=None):
        print(f"bridge: ws://{args.host}:{args.port}/api/display/ws -> {args.socket}",
              file=sys.stderr, flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
