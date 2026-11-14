#!/bin/sh
# Inside the container (run.sh starts it): a Hermes home with three Bot Mode profiles pointed at the
# stand-in model, the model, a gateway, and then the probes. Captures and logs go to /out.
set -eu
cd /opt/hermes
hermes="python -m hermes_cli.main"

# Hermes's model is the stand-in, on this machine
printf 'model:\n  default: "mock-model"\n  provider: "custom"\n  base_url: "http://127.0.0.1:9911/v1"\n  api_key: "mock-key"\n  context_length: 200000\n' > "$HERMES_HOME/config.yaml"
# two more profiles with the same model, and all three marked as Bot Mode's (ui_meta's hermes-bots,
# where Shion keeps an assistant's title): message_agent is offered only on such an install
$hermes profile create study --clone --no-alias --description "课程助手（mock）" > /dev/null
$hermes profile create commute --clone --no-alias --description "通勤助手（mock）" > /dev/null
bot() { printf 'description: %s\ndescription_auto: false\nui_meta:\n  hermes-bots:\n    title: %s\n' "$2" "$3" > "$1/profile.yaml"; }
bot "$HERMES_HOME" "总秘书（mock）" "詩音"
bot "$HERMES_HOME/profiles/study" "课程助手（mock）" "课程"
bot "$HERMES_HOME/profiles/commute" "通勤助手（mock）" "通勤"
# 通勤 compacts a session by rotating it into a new one; the others compact it in place, as Hermes
# does by default (stage compact)
printf 'compression:\n  in_place: false\n' >> "$HERMES_HOME/profiles/commute/config.yaml"
# the gateway refuses a home others can write to
chmod -R go-w "$HOME"

nohup python /real/mock_model.py 9911 /out/mock-model.log > /out/mock-model.out 2>&1 &
# the gateway, Hermes's own, started through hold_gateway.py: it can hold the answer to an attach (stage behind)
nohup python /real/hold_gateway.py gateway run -v > /out/gateway.log 2>&1 &
ready=""
for _ in $(seq 1 60); do
    if $hermes gateway attach --json 2>/dev/null | grep -q '"state":"ready"'; then ready=yes; break; fi
    sleep 2
done
[ -n "$ready" ] || { echo "the gateway did not come up"; tail -20 /out/gateway.log; exit 1; }

for stage in ${STAGES:-plain peer peer2 background gap behind compact}; do
    echo "######## $stage"
    python /real/probe.py "$stage" "/out/capture-$stage.json" > "/out/$stage.txt" 2>&1 || { tail -20 "/out/$stage.txt"; exit 1; }
    # the frames that say little are left out of what is shown (they are in the .txt); stage behind
    # names such frames in what it found, so only the lines of the frames themselves go there
    quiet="session.info\|session.usage\|thinking.delta\|agent.step"
    if [ "$stage" = behind ]; then quiet=" event \(session.info\|session.usage\|thinking.delta\|agent.step\) "; fi
    grep -v "$quiet" "/out/$stage.txt" | cut -c1-400
done
