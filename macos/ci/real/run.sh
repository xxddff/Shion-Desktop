#!/usr/bin/env bash
# The turns only a model can start (a teammate's message and its answer, a background result, a
# subscription Hermes ends), against Hermes itself with a stand-in model, in a container without
# network. Needs Docker and the image hermes-plugin/test-with-hermes.sh builds (Hermes at the commit
# pinned there): run that once first.
#
#   ./run.sh [directory for the captures]      default: ./captures
#   STAGES="peer gap" ./run.sh                 only some of probe.py's stages
#
# Then, where there is a Swift compiler, the Mac's own code over what was captured: its notice
# reader, and its review talk over a turn's end that overtook the answer to session.resume:
#   ./read_notices.sh captures/capture-peer.json captures/capture-peer2.json captures/capture-background.json
#   ./read_behind.sh captures/capture-behind.json
# and the pages read before and after a compaction (stage compact) are what the logic checks of
# sending and of notices run over:
#   cp captures/compaction-send.json ../logic/send/compaction.json
#   cp captures/compaction-notices.json ../logic/notices/compaction.json
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${HERMES_TEST_IMAGE:-shion-hermes-test}"
out="${1:-$here/captures}"
mkdir -p "$out"
name="shion-real-$$"
docker run --detach --name "$name" --network none --volume "$here:/real:ro" --volume "$(cd "$out" && pwd):/out" \
    "$image" sleep 3600 > /dev/null
trap 'docker rm --force "$name" > /dev/null' EXIT
# Hermes's gateway does not run as root, and wants a home only its user can write to
docker exec "$name" sh -c 'mkdir -p /tmp/u/home && chown -R 1000:1000 /tmp/u /out'
docker exec --user 1000:1000 --env HOME=/tmp/u --env HERMES_HOME=/tmp/u/home --env STAGES="${STAGES:-}" \
    "$name" sh /real/inside.sh
echo "captures in $out"
