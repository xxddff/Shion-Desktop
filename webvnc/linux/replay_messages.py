#!/usr/bin/env python3
"""Plays a recorded noVNC session back over WebSocket, message by message, like the display bridge
delivered it (for the macOS shell: no Xvnc there). A variant of rfb/testbed/replay_server.py that
keeps the original WebSocket message boundaries: noVNC stops reading after its handshake until the
next message arrives, so a replay that packs the handshake and the first updates into one frame
stalls it (a live Xvnc never does that: it sends nothing until the client has asked).

    replay_messages.py SAMPLE [--require-header NAME]...

SAMPLE: zlib of (u32 length, bytes) repeated, as webvnc/relay/relay.py records with RELAY_RECORD.
Binds 127.0.0.1 on a free port and prints ``port N``. Each connection to
``/api/display/ws?then=…`` gets every message as fast as the client takes them, then:

- ``then=close4000``: closes with 4000 "control-taken" (another viewer took over);
- ``then=wait`` (default): waits for the client to close and prints ``client closed CODE``.

Without a required header the upgrade is refused with HTTP 403, as Cloudflare Access does.
"""

from __future__ import annotations

import argparse
import asyncio
import http
import signal
import sys
import urllib.parse
import zlib

from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.exceptions import ConnectionClosed
from websockets.http11 import Response


def messages(blob: bytes) -> list[bytes]:
    out, i = [], 0
    while i + 4 <= len(blob):
        n = int.from_bytes(blob[i:i + 4], "big")
        out.append(blob[i + 4:i + 4 + n])
        i += 4 + n
    return out


def main() -> None:
    signal.pthread_sigmask(signal.SIG_SETMASK, [])  # a parent's blocked SIGTERM would stick
    p = argparse.ArgumentParser()
    p.add_argument("sample")
    p.add_argument("--require-header", action="append", default=[])
    args = p.parse_args()
    recorded = messages(zlib.decompress(open(args.sample, "rb").read()))
    required = [h.lower() for h in args.require_header]

    def process_request(connection, request):
        if urllib.parse.urlsplit(request.path).path != "/api/display/ws":
            return Response(404, "Not Found", Headers([("Content-Length", "0")]), b"")
        for name in required:
            if not request.headers.get(name):
                return Response(403, http.HTTPStatus(403).phrase, Headers([("Content-Length", "0")]), b"")
        return None

    async def handler(ws) -> None:
        query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(ws.request.path).query))
        then = query.get("then", "wait")
        try:
            for message in recorded:
                await ws.send(message)
        except ConnectionClosed:
            return
        if then == "close4000":
            await ws.close(4000, "control-taken")
            return
        code = None
        try:
            while True:
                await ws.recv()  # what the client sends (requests, fence answers, input) is ignored
        except ConnectionClosed as exc:
            code = exc.rcvd.code if exc.rcvd else None
        print(f"client closed {code}", flush=True)

    async def run() -> None:
        async with serve(handler, "127.0.0.1", 0, process_request=process_request,
                         max_size=None, compression=None) as server:
            port = next(iter(server.sockets)).getsockname()[1]
            print(f"port {port}", flush=True)
            await asyncio.Future()

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
