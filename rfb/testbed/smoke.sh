#!/usr/bin/env bash
# End-to-end check against a live testbed (Xvnc + bridge.py), as CI runs it:
#   1. without the Access header the upgrade is refused (HTTP 403);
#   2. a watcher gets a picture, and its paste never reaches the screen;
#   3. a ticket works once: the second use is closed with 4401;
#   4. the lease holder's UTF-8 paste arrives in X intact;
#   5. (when a Chrome or Chromium is installed) typing by clipboard + Ctrl+V lands in a text box.
#   rfb/testbed/smoke.sh        (builds rfb-probe first; RFB_TESTBED_CHROME=/path/to/chrome to pick one)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
export RFB_TESTBED_DISPLAY=:25 RFB_TESTBED_PORT=8771 RFB_TESTBED_RUN="${TMPDIR:-/tmp}/rfb-smoke-$$"
export RFB_TESTBED_REQUIRE_HEADER=CF-Access-Client-Id NO_PROXY=127.0.0.1
WORK="$RFB_TESTBED_RUN/work"; mkdir -p "$WORK"
"$HERE/start.sh" >"$WORK/testbed.log" 2>&1 &
TB=$!
trap 'kill $TB 2>/dev/null; wait $TB 2>/dev/null || true; rm -rf "$RFB_TESTBED_RUN"' EXIT
(cd "$PKG" && swift build --product rfb-probe >/dev/null)
up=0
for _ in $(seq 1 100); do
  curl -fs "http://127.0.0.1:$RFB_TESTBED_PORT/lease" >/dev/null 2>&1 && { up=1; break; }
  kill -0 $TB 2>/dev/null || break
  sleep 0.1
done
[[ $up == 1 ]] || { echo "FAIL: the testbed did not come up" >&2; cat "$WORK/testbed.log" >&2; exit 1; }
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

CHROME="${RFB_TESTBED_CHROME:-$(command -v google-chrome chromium chromium-browser 2>/dev/null | head -1 || true)}"
if [[ -n "$CHROME" ]]; then
  echo "== 5. clipboard + Ctrl+V types into a browser text box ($(basename "$CHROME"))"
  X "$CHROME" --no-sandbox --disable-gpu --no-first-run --user-data-dir="$WORK/chrome" \
    --window-position=0,0 --window-size=1000,700 --app="file://$HERE/input.html" >"$WORK/chrome.log" 2>&1 &
  CH=$!
  for _ in $(seq 1 100); do X xdotool search --name '^empty$' >/dev/null 2>&1 && break; sleep 0.2; done
  X xdotool mousemove 300 200 click 1   # focus the text box (no window manager here)
  curl -fs "$API/lease/acquire?viewer_id=typist" >/dev/null
  TEXT=$'你好，云桌面\nクラウド 👋 ok'
  "$PROBE" "$("$HERE/observe.sh" typist)" -H 'CF-Access-Client-Id: @env:CF_ID' --out "$WORK/p5" --seconds 3 --type "$TEXT" 2>"$WORK/p5.log" \
    || fail "typing probe failed"
  GOT=""
  for _ in $(seq 1 25); do
    GOT=$(X xdotool search --name '^T:' getwindowname 2>/dev/null | head -1 || true)
    [[ -n "$GOT" ]] && break; sleep 0.2
  done
  kill $CH 2>/dev/null || true
  [[ "$GOT" == "T:${TEXT//$'\n'/⏎}" ]] || fail "typed text differs: $(printf %q "$GOT")"
else
  echo "== 5. skipped: no Chrome or Chromium (set RFB_TESTBED_CHROME)"
fi
echo "OK"
