"""Starts Hermes's own gateway (`python -m hermes_cli.main <arguments>`, from Hermes's directory)
with one thing added from outside its files: while the file HOLD exists, the answer to an attach
(`session.resume`, `session.create`) waits after the session was read.

Hermes's attach (gateway/session_authority.py) joins the viewer to the session's frames and reads
the session under one lock, and answers after two more waits; the first is
`asyncio.to_thread(cancel_persisted_close, ...)`. That function is wrapped here to stay in its
thread while HOLD exists. The gateway's loop goes on meanwhile, so what the session publishes
reaches the viewer before the snapshot does: the order a busy server gives by itself, made to
happen when a probe wants it (probe.py, stage `behind`). `HOLD.reached` is written when an attach
got there. Without the file nothing waits and the gateway is Hermes's as it is.

    python hold_gateway.py gateway run -v
"""
import os
import runpy
import sys
import time

HOLD = os.environ.get("SHION_HOLD", "/out/hold-attach")
LONGEST = 60.0  # seconds: a probe that died does not leave the gateway waiting

# as `python -m` has it: Hermes's directory first, and not this one
sys.path[0] = os.getcwd()

import gateway.session_viewer_close as viewer_close  # noqa: E402

hermes_own = viewer_close.cancel_persisted_close


def held(*args, **kwargs):
    result = hermes_own(*args, **kwargs)
    if os.path.exists(HOLD):
        open(HOLD + ".reached", "w").close()
        until = time.monotonic() + LONGEST
        while os.path.exists(HOLD) and time.monotonic() < until:
            time.sleep(0.02)
    return result


viewer_close.cancel_persisted_close = held
runpy.run_module("hermes_cli.main", run_name="__main__", alter_sys=True)
