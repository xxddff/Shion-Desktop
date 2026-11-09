#!/usr/bin/env bash
# End-to-end check against a live testbed (Xvnc + bridge.py), as CI runs it:
#   1. without the Access header the upgrade is refused (HTTP 403);
#   2. a watcher gets a picture, and its paste never reaches the screen;
#   3. a ticket works once: the second use is closed with 4401;
#   4. the lease holder's UTF-8 paste arrives in X intact.
#   rfb/testbed/smoke.sh        (builds rfb-probe first)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
export RFB_TESTBED_DISPLAY=:25 RFB_TESTBED_PORT=8771 RFB_TESTBED_RUN="${TMPDIR:-/tmp}/rfb-smoke-$$"
export RFB_TESTBED_REQUIRE_HEADER=CF-Access-Client-Id NO_PROXY=127.0.0.1
WORK="$RFB_TESTBED_RUN/work"; mkdir -p "$WORK"
"$HERE/start.sh" >"$WORK/testbed.log" 2>&1 &
TB=$!
trap 'kill $TB 2>/dev/null; wait $TB 2>/dev/null || true; rm -rf "$RFB_TESTBED_RUN"' EXIT
for _ in $(seq 1 100); do curl -fs "http://127.0.0.1:$RFB_TESTBED_PORT/lease" >/dev/null 2>&1 && break; sleep 0.1; done
(cd "$PKG" && swift build --product rfb-probe >/dev/null)
PROBE="$PKG/.build/debug/rfb-probe"
X() { DISPLAY=$RFB_TESTBED_DISPLAY XAUTHORITY=$RFB_TESTBED_RUN/Xauthority "$@"; }
API="http://127.0.0.1:$RFB_TESTBED_PORT"
export CF_ID=smoke-id
fail() { echo "FAIL: $*" >&2; cat "$WORK"/*.log >&2 || true; exit 1; }

echo "== 1. no Access header -> refused"
if "$PROBE" "$("$HERE/observe.sh")" --out "$WORK/p1" --seconds 1 2>"$WORK/p1.log"; then fail "connected without the header"; fi
grep -q "HTTP 403" "$WORK/p1.log" || fail "expected HTTP 403"

echo "== 2. watcher: picture, paste dropped"
X sh -c 'printf before | xclip -i -selection clipboard'
URL="$("$HERE/observe.sh" watcher)"
"$PROBE" "$URL" -H 'CF-Access-Client-Id: @env:CF_ID' --out "$WORK/p2" --seconds 2 --paste "from a watcher" 2>"$WORK/p2.log" &
P=$!; sleep 1.5
GOT=$(X timeout 3 xclip -o -selection clipboard || true)
wait $P || fail "watcher probe failed"
[[ "$GOT" == before ]] || fail "watcher paste reached the screen: $GOT"
grep -q "first picture" "$WORK/p2.log" || fail "no picture"
[[ -s "$WORK/p2/frame.png" ]] || fail "no frame.png"

echo "== 3. ticket is single-use -> 4401"
if "$PROBE" "$URL" -H 'CF-Access-Client-Id: @env:CF_ID' --out "$WORK/p3" --seconds 1 2>"$WORK/p3.log"; then :; fi
grep -q "code 4401" "$WORK/p3.log" || fail "expected close 4401"

echo "== 4. lease holder: UTF-8 paste arrives"
curl -fs "$API/lease/acquire?viewer_id=holder" >/dev/null
TEXT=$'云桌面 クラウド 👋\nsecond line'
"$PROBE" "$("$HERE/observe.sh" holder)" -H 'CF-Access-Client-Id: @env:CF_ID' --out "$WORK/p4" --seconds 3 --paste "$TEXT" 2>"$WORK/p4.log" &
P=$!; sleep 1.5
GOT=$(X timeout 3 xclip -o -selection clipboard || true)
wait $P || fail "holder probe failed"
[[ "$GOT" == "$TEXT" ]] || fail "pasted text differs: $(printf %q "$GOT")"
# A normal close (1000) by the holder hands the lease back, as on Hermes.
curl -fs "$API/lease" | grep -q '"holder": "agent"' || fail "lease not handed back on close"
cat "$WORK/p4.log"
echo "OK"
