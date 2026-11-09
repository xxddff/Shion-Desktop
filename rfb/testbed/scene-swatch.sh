#!/usr/bin/env bash
# Content for the static scene's first window: a 256-colour swatch and some multilingual text,
# then it prints more lines when ./record-sample.sh touches $RFB_TESTBED_RUN/more (so the terminal
# scrolls, which Xvnc sends as CopyRect).
for i in $(seq 0 255); do printf '\e[48;5;%dm  ' "$i"; (( i % 32 == 31 )) && printf '\e[0m\n'; done
printf '\e[0m\n\e[1;32mHermes Bot Screen\e[0m · 云桌面 · クラウドデスクトップ\n'
for i in $(seq 1 5); do printf 'line %02d  \e[3%dm■■■■\e[0m  the quick brown fox\n' "$i" "$((i % 7 + 1))"; done
RUN="${RFB_TESTBED_RUN:-${XDG_RUNTIME_DIR:-/tmp}/rfb-testbed}"
while [[ ! -e "$RUN/more" ]]; do sleep 0.1; done
for i in $(seq 6 12); do printf 'line %02d  \e[3%dm■■■■\e[0m  jumps over the lazy dog\n' "$i" "$((i % 7 + 1))"; done
exec sleep infinity
