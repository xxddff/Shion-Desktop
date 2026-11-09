#!/usr/bin/env python3
"""Plays another local process trying the relay's port: without the token, with a wrong token, with
the token but a foreign or no Origin, and (``--after``) with everything right once the page is on.
Every attempt must be refused. Prints one JSON line {attempt: outcome}.

    RELAY_PORT=… RELAY_TOKEN=… relay_probe.py [--after]
"""

import asyncio
import json
import os
import sys

from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus

PORT = int(os.environ["RELAY_PORT"])
TOKEN = os.environ["RELAY_TOKEN"]
ORIGIN = os.environ.get("RELAY_PAGE_ORIGIN", "https://webvnc.test")


async def attempt(subprotocols, origin):
    try:
        async with connect(f"ws://127.0.0.1:{PORT}/", subprotocols=subprotocols or None, origin=origin,
                           open_timeout=3, user_agent_header=None):
            return "accepted"
    except InvalidStatus as exc:
        return f"refused {exc.response.status_code}"
    except OSError as exc:
        return f"refused ({type(exc).__name__})"
    except Exception as exc:  # handshake errors
        return f"failed ({type(exc).__name__})"


async def main():
    good = f"shion.{TOKEN}"
    if "--after" in sys.argv:
        tries = {"right token and origin, second connection": ([good], ORIGIN)}
    else:
        tries = {
            "no subprotocol": ([], ORIGIN),
            "wrong token": ([f"shion.{'0' * len(TOKEN)}"], ORIGIN),
            "token, foreign origin": ([good], "https://evil.example"),
            "token, no origin": ([good], None),
        }
    out = {}
    for name, (protocols, origin) in tries.items():
        out[name] = await attempt(protocols, origin)
    print(json.dumps(out))


asyncio.run(main())
