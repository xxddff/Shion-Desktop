#!/usr/bin/env bash
# Record a test sample: start a static testbed on its own display and port, watch it through the
# bridge with rfb-probe while a script changes the screen, then grab the real screen with xwd.
# The probe's recording, replayed, must decode to exactly that picture (Tests/RFBTests).
#
#   rfb/testbed/record-sample.sh NAME SCRIPT [probe options…]
#     SCRIPT: watch | resize | raw     (see below)
#
# Writes rfb/Tests/RFBTests/Samples/NAME.{server.z,expected.z,json}.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
NAME="$1"; SCRIPT="$2"; shift 2
OUT="$PKG/Tests/RFBTests/Samples"
export RFB_TESTBED_DISPLAY=:23 RFB_TESTBED_PORT=8767 RFB_TESTBED_SCENE=static
export RFB_TESTBED_RUN="${TMPDIR:-/tmp}/rfb-sample-$$"
export RFB_TESTBED_GEOMETRY="${RFB_TESTBED_GEOMETRY:-800x500}"
export NO_PROXY=127.0.0.1
WORK="$RFB_TESTBED_RUN/work"
mkdir -p "$WORK"
"$HERE/start.sh" >"$WORK/testbed.log" 2>&1 &
TB=$!
trap 'kill $TB 2>/dev/null; wait $TB 2>/dev/null; rm -rf "$RFB_TESTBED_RUN"' EXIT
for _ in $(seq 1 100); do curl -fs "http://127.0.0.1:8767/lease" >/dev/null 2>&1 && break; sleep 0.1; done
sleep 2   # let the windows map and draw
read -r PX PY <<<"${RFB_SAMPLE_POINTER:-600 440}"

X() { DISPLAY=$RFB_TESTBED_DISPLAY XAUTHORITY=$RFB_TESTBED_RUN/Xauthority "$@"; }
# Park the pointer somewhere visible: without the Cursor pseudo-encoding Xvnc paints it into the
# picture, and xwd does not, so the test allows differences only around this point.
X xdotool mousemove "$PX" "$PY"
(cd "$PKG" && swift build --product rfb-probe >/dev/null)
"$PKG/.build/debug/rfb-probe" "$("$HERE/observe.sh")" --out "$WORK/probe" --seconds 6 "$@" 2>"$WORK/probe.log" &
PROBE=$!
sleep 1
case "$SCRIPT" in
  watch)   # window moves (CopyRect), terminal scroll (CopyRect), new text, background change
    X xdotool search --classname '^rfbinput$' windowmove 380 300; sleep 0.7
    touch "$RFB_TESTBED_RUN/more"; sleep 0.7
    X xsetroot -solid '#2e3440'; sleep 0.7
    X xdotool search --classname '^rfbinput$' windowmove 300 260; sleep 0.7
    X xdotool search --classname '^xlogo$' windowmove 600 300 ;;
  resize)  # the agent's screen changes size under us (DesktopSize / ExtendedDesktopSize)
    X xrandr -s 640x480; sleep 1
    X xdotool search --classname '^rfbinput$' windowmove 200 200 ;;
  raw)     # whatever the probe options asked for (e.g. --encodings raw,copyrect)
    X xdotool search --classname '^rfbinput$' windowmove 380 300; sleep 0.7
    touch "$RFB_TESTBED_RUN/more" ;;
  *) echo "unknown script $SCRIPT" >&2; exit 2 ;;
esac
sleep 2   # quiet: everything has reached the probe
X xwd -root -silent >"$WORK/screen.xwd"
wait $PROBE || { cat "$WORK/probe.log" >&2; exit 1; }
cat "$WORK/probe.log" >&2
SIZE=$(python3 -I "$HERE/xwd2bgrx.py" "$WORK/screen.xwd" "$OUT/$NAME.expected.z")
python3 -I -c 'import sys, zlib; open(sys.argv[2], "wb").write(zlib.compress(open(sys.argv[1], "rb").read(), 9))' \
  "$WORK/probe/server.bin" "$OUT/$NAME.server.z"
cp "$WORK/probe/frame.png" "$OUT/$NAME.png"
printf '{"name": "%s", "script": "%s", "size": "%s", "pointer": [%d, %d], "xvnc": "%s", "probe_options": "%s"}\n' \
  "$NAME" "$SCRIPT" "$SIZE" "$PX" "$PY" "$(Xvnc -version 2>&1 | grep -o 'TigerVNC [0-9.]*' | head -1)" "$*" >"$OUT/$NAME.json"
ls -l "$OUT/$NAME".*
