#!/usr/bin/env bash
# The Bot Chat's attach and rejoin, checked away from a Mac: the methods are cut out of the app's
# own files as they are (extract.py) and compiled with its JSONValue.swift, EventCursors.swift and
# SecretRequest.swift against stand-ins for the rest of the app (stubs.swift), then run against a
# session whose frames can overtake the answer to `session.resume` (main.swift).
#
#   ./run.sh                      this repository's files
#   ./run.sh <another tree> old   the methods of a tree from before `resumed` existed, to see
#                                 which checks it fails (the checks that call it are left out)
#
# SWIFTC names the compiler (default: swiftc). Exits non-zero when a check fails.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"
tree="${1:-$repo}"
old="${2:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 "$here/extract.py" "$tree" "$work/extracted.swift" $old
"${SWIFTC:-swiftc}" -swift-version 6 -default-isolation MainActor ${old:+-D OLD} -o "$work/chat" \
    "$here/main.swift" "$here/stubs.swift" "$work/extracted.swift" \
    "$repo/macos/Shion/Gateway/JSONValue.swift" "$repo/macos/Shion/Gateway/EventCursors.swift" \
    "$repo/macos/Shion/Model/SecretRequest.swift" "$repo/macos/Shion/Model/Rejoin.swift"
"$work/chat"
