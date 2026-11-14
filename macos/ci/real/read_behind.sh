#!/usr/bin/env bash
# The app's own review talk (SkillReviewTalk.swift) and SessionWords (EventCursors.swift), compiled
# as they are with the stand-ins of ci/logic/talk for the rest of the app, over a capture of stage
# `behind` from run.sh: a turn's end that reached the viewer before the answer to `session.resume`.
# Works on Linux too (SWIFTC names the compiler). Exits non-zero when a check fails.
#
#   ./read_behind.sh <capture-behind.json> [another SkillReviewTalk.swift]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$here/../../Shion"
talk="${2:-$app/Model/SkillReviewTalk.swift}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$here/read_behind.swift" "$work/main.swift"
"${SWIFTC:-swiftc}" -swift-version 6 -default-isolation MainActor -o "$work/read" \
    "$work/main.swift" "$here/../logic/talk/stubs.swift" \
    "$talk" "$app/Model/SkillReview.swift" "$app/Model/Delivery.swift" "$app/Model/TurnFailure.swift" \
    "$app/Gateway/JSONValue.swift" "$app/Gateway/EventCursors.swift"
"$work/read" "$1"
