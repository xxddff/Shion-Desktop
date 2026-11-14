#!/usr/bin/env bash
# A skill's review session, checked away from a Mac: the app's own SkillReviewTalk.swift (and the
# files it reads rows, deliveries and failures with) compiled as it is, with stand-ins for the
# rest of the app (stubs.swift), and run against a scripted session (main.swift).
#
#   ./run.sh [another SkillReviewTalk.swift]     e.g. an older one, to see which checks it fails
#
# SWIFTC names the compiler (default: swiftc). Exits non-zero when a check fails.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$here/../../../Shion"
talk="${1:-$app/Model/SkillReviewTalk.swift}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"${SWIFTC:-swiftc}" -swift-version 6 -default-isolation MainActor -o "$work/talk" \
    "$here/main.swift" "$here/stubs.swift" \
    "$talk" "$app/Model/SkillReview.swift" "$app/Model/Delivery.swift" "$app/Model/TurnFailure.swift" \
    "$app/Gateway/JSONValue.swift" "$app/Gateway/EventCursors.swift"
"$work/talk"
