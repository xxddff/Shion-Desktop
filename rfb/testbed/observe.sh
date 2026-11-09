#!/usr/bin/env bash
# Print a ws:// URL carrying a fresh single-use display ticket (like display.observe + the path).
# Prints the URL to stdout only; do not paste it into logs (it is spent after one use anyway).
#   rfb/testbed/observe.sh [viewer_id]
set -euo pipefail
PORT="${RFB_TESTBED_PORT:-8765}"
q=""; [[ -n "${1:-}" ]] && q="?viewer_id=$1"
curl -fsS --noproxy 127.0.0.1 "http://127.0.0.1:$PORT/observe$q" | python3 -I -B -c '
import json, sys
d = json.load(sys.stdin)
print(f"ws://127.0.0.1:'"$PORT"'{d["path"]}?display_ticket={d["ticket"]}")'
