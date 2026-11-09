#!/usr/bin/env python3
"""What Hermes' RFB filter (tools/bot_desktop/rfb_filter.py, vendored in rfb/testbed/hermes) does with
the 7-byte PointerEvent noVNC 1.6+ sends for the mouse's back / forward buttons once the server has
confirmed the ExtendedMouseButtons pseudo-encoding (-316; TigerVNC 1.15 and later offers it).

The filter frames every PointerEvent as 6 bytes, so the 7th byte is read as the next message type:
back (0x01) is an unknown type and the bridge closes the display with 1003; forward (0x02) is read as
a SetEncodings header and the following input is swallowed into it and handed to Xvnc as one.

    python3 webvnc/linux/filter_check.py      # prints one JSON line
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "rfb" / "testbed" / "hermes"))
from rfb_filter import RfbClientFilter  # noqa: E402

HANDSHAKE = b"RFB 003.008\n" + b"\x01" + b"\x01"


def pointer(x, y, mask):                      # RFB 6143 §7.5.5
    return bytes([5, mask & 0xFF]) + x.to_bytes(2, "big") + y.to_bytes(2, "big")


def extended_pointer(x, y, mask):             # noVNC core/rfb.js RFB.messages.extendedPointerEvent
    return bytes([5, (mask & 0x7F) | 0x80]) + x.to_bytes(2, "big") + y.to_bytes(2, "big") + bytes([(mask >> 7) & 0xFF])


def key(keysym, down):                        # §7.5.4
    return bytes([4, 1 if down else 0, 0, 0]) + keysym.to_bytes(4, "big")


def run(stream: bytes):
    f = RfbClientFilter(lambda: True)
    try:
        out = f.feed(HANDSHAKE + stream)
    except ValueError as exc:
        return {"bridge": "closes 1003", "error": str(exc)}
    passed = out[len(HANDSHAKE):]
    return {"forwarded": len(passed), "of": len(stream), "buffered": len(f._buf),
            "intact": passed == stream}


after = key(0x61, True) + key(0x61, False) + pointer(100, 100, 0)
result = {
    "plain pointer + key": run(pointer(100, 100, 1) + pointer(100, 100, 0) + after),
    "back button (noVNC, server offers -316)": run(extended_pointer(100, 100, 1 << 7) + after),
    "forward button (noVNC, server offers -316)": run(extended_pointer(100, 100, 1 << 8) + after),
}
print(json.dumps(result, ensure_ascii=False))
