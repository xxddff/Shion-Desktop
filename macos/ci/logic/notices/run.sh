#!/usr/bin/env bash
# The notice cards' checks (main.swift) against the app's own NoticeCards.swift and Notices.swift,
# and the store's reading of a turn's notice (AppStore.followNotices and the page read it goes
# through, AppStore.transcriptPage, cut from the app's files as they are by extract.py, with
# Delivery.swift for the rows that name a submission) against stand-ins for the rest of the app
# (stubs.swift) and transcripts paged as Hermes pages them.
#   ./run.sh                    SWIFTC names the compiler where `swiftc` is not it
#   SHION_ROOT=/another/copy    the app's files of another copy of the repository
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${SHION_ROOT:-$(cd "$here/../../../.." && pwd)}"
model="$root/macos/Shion/Model"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 "$here/extract.py" "$root" "$work/extracted.swift"
# ChatEvent alone out of Models.swift, which needs SwiftUI for its other types
{ echo "import Foundation"; awk '/^nonisolated enum ChatEvent/,/^}/' "$model/Models.swift"; } > "$work/event.swift"
grep -q "var startsTurn" "$work/event.swift"
"${SWIFTC:-swiftc}" -swift-version 6 -default-isolation MainActor -o "$work/check" \
    "$here/main.swift" "$here/stubs.swift" "$work/extracted.swift" "$work/event.swift" \
    "$model/NoticeCards.swift" "$model/Notices.swift" "$model/Delivery.swift" \
    "$root/macos/Shion/Gateway/JSONValue.swift"
"$work/check"
