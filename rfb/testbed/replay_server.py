#!/usr/bin/env python3
"""Plays a recorded server stream over WebSocket, like Hermes' display bridge would deliver it.

For transport tests that need no Xvnc (the macOS CI job, where Xvnc is not available):

    replay_server.py SAMPLE.server.z [--require-header NAME]

It binds 127.0.0.1 on a free port and prints ``port N`` on stdout. Each connection to
``/api/display/ws?then=…`` gets the recorded bytes in 64 KiB binary frames, then:

- ``then=close4000``: the server closes with 4000 "control-taken" (another viewer took over);
- ``then=wait`` (default): it waits for the client to close and prints ``client closed CODE``.

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


def main() -> None:
    # A parent that spawns us from a libdispatch thread (the Swift test runner) passes on a mask
    # that blocks SIGTERM; unblock everything so terminate() works.
    signal.pthread_sigmask(signal.SIG_SETMASK, [])
    p = argparse.ArgumentParser()
    p.add_argument("sample")
    p.add_argument("--require-header", action="append", default=[])
    args = p.parse_args()
    data = zlib.decompress(open(args.sample, "rb").read())
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
        for i in range(0, len(data), 64 * 1024):
            await ws.send(data[i:i + 64 * 1024])
        if then == "close4000":
            await ws.close(4000, "control-taken")
            return
        code = None
        try:
            while True:
                await ws.recv()  # whatever the client sends (FBURs, fence answers) is ignored
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
