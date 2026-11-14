#!/usr/bin/env bash
# The notice cards' checks (main.swift) against the app's own NoticeCards.swift and Notices.swift.
#   ./run.sh            SWIFTC names the compiler where `swiftc` is not it
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
model="$here/../../../Shion/Model"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
{ echo "import Foundation"; awk '/^nonisolated enum ChatEvent/,/^}/' "$model/Models.swift"; } > "$work/event.swift"
grep -q "var startsTurn" "$work/event.swift"
"${SWIFTC:-swiftc}" -swift-version 6 -o "$work/check" "$here/main.swift" "$work/event.swift" \
    "$model/NoticeCards.swift" "$model/Notices.swift"
"$work/check"
