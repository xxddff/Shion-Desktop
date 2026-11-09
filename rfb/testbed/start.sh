#!/usr/bin/env bash
# Start a local stand-in for a Hermes Bot Screen: TigerVNC's Xvnc with the flags Hermes'
# tools/bot_desktop/launcher.sh uses, a few X programs so the picture changes, and bridge.py in front.
#
#   rfb/testbed/start.sh            # foreground; Ctrl-C stops everything
#   RFB_TESTBED_PORT=8765 RFB_TESTBED_DISPLAY=:21 RFB_TESTBED_GEOMETRY=1440x900 rfb/testbed/start.sh
#   RFB_TESTBED_REQUIRE_HEADER=CF-Access-Client-Id rfb/testbed/start.sh   # refuse upgrades without it
#   RFB_TESTBED_SCENE=static rfb/testbed/start.sh   # nothing moves on its own (for recording samples)
#
# Then get a URL with a fresh single-use ticket:  rfb/testbed/observe.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPLAY_NUM="${RFB_TESTBED_DISPLAY:-:21}"
GEOM="${RFB_TESTBED_GEOMETRY:-1440x900}"
PORT="${RFB_TESTBED_PORT:-8765}"
RUN="${RFB_TESTBED_RUN:-${XDG_RUNTIME_DIR:-/tmp}/rfb-testbed}"
mkdir -p "$RUN"; chmod 700 "$RUN"
SOCK="$RUN/rfb.sock"
export XAUTHORITY="$RUN/Xauthority"
export LANG=C.UTF-8 LC_ALL=C.UTF-8

command -v Xvnc >/dev/null || { echo "Xvnc missing: apt-get install tigervnc-standalone-server x11-apps xterm x11-xserver-utils x11-utils xdotool" >&2; exit 1; }
python3 -c 'import websockets' 2>/dev/null || { echo "python websockets missing: pip install websockets" >&2; exit 1; }

pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; wait 2>/dev/null || true; rm -f "$SOCK"; }
trap cleanup EXIT INT TERM

rm -f "$SOCK"
: > "$XAUTHORITY"; chmod 600 "$XAUTHORITY"
xauth -q -f "$XAUTHORITY" source - <<COOKIE
add $DISPLAY_NUM MIT-MAGIC-COOKIE-1 $(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
COOKIE

# Same flags as Hermes' launcher.sh (keep in sync when Hermes changes them).
Xvnc "$DISPLAY_NUM" -geometry "$GEOM" -depth 24 -dpi 96 \
  -rfbport -1 -rfbunixpath "$SOCK" -rfbunixmode 0600 \
  -SecurityTypes None -AlwaysShared -AcceptSetDesktopSize -FrameRate 30 -SendCutText=0 -MaxCutText 262144 \
  -desktop "hermes:testbed" -auth "$XAUTHORITY" -nolisten tcp \
  -Log '*:stderr:30' 2> >(grep -v --line-buffered 'Could not resolve keysym' >&2) &
pids+=($!)
export DISPLAY="$DISPLAY_NUM"
for _ in $(seq 1 100); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
xdpyinfo >/dev/null 2>&1 || { echo "Xvnc did not become ready" >&2; exit 1; }
xsetroot -solid '#1c1f29' 2>/dev/null || true

if [[ "${RFB_TESTBED_SCENE:-live}" == static ]]; then
  # Nothing changes unless a script makes it: anti-aliased text, a 256-colour swatch, a logo.
  xdotool mousemove 2000 2000 2>/dev/null || true   # pointer out of the way (clamped to the corner)
  xterm -u8 -geometry 70x26+20+20 -fa 'DejaVu Sans Mono' -fs 10 -bg '#202430' -fg '#d8dee9' -T swatch \
    -e bash "$HERE/scene-swatch.sh" & pids+=($!)
  xlogo -geometry 120x120+560+40 & pids+=($!)
  xterm -geometry 50x8+20+380 -name rfbinput -T input & pids+=($!)
else
  # Something that changes on its own (clock hands, a ticking counter) and something to type into.
  xclock -update 1 -geometry 200x200+40+60 & pids+=($!)
  xterm -geometry 80x24+300+60 -bg '#202430' -fg '#d8dee9' -e bash -c 'while :; do date "+%T  %N"; sleep 0.5; done' & pids+=($!)
  xterm -geometry 60x12+300+460 -T input & pids+=($!)
  xeyes -geometry 160x120+40+320 & pids+=($!)
fi

headers=()
for h in ${RFB_TESTBED_REQUIRE_HEADER:-}; do headers+=(--require-header "$h"); done
python3 -I "$HERE/bridge.py" --socket "$SOCK" --port "$PORT" "${headers[@]}" & pids+=($!)
echo "testbed: Xvnc $DISPLAY_NUM ($GEOM), socket $SOCK, bridge ws://127.0.0.1:$PORT/api/display/ws" >&2
echo "testbed: get a ticket URL with  $HERE/observe.sh" >&2
wait -n "${pids[@]}"
