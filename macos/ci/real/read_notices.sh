#!/usr/bin/env bash
# The app's own Notices.swift (compiled as it is, with ChatEvent cut out of Models.swift, which
# needs SwiftUI for its other types) over captures from run.sh: what the chat would show for each
# turn start and each stored row. Works on Linux too (SWIFTC names the compiler).
#
#   ./read_notices.sh <capture.json>...
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
model="$here/../../Shion/Model"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
{ echo "import Foundation"; awk '/^nonisolated enum ChatEvent/,/^}/' "$model/Models.swift"; } > "$work/event.swift"
cp "$here/read_notices.swift" "$work/main.swift"
"${SWIFTC:-swiftc}" -swift-version 6 -o "$work/read" "$work/main.swift" "$work/event.swift" "$model/Notices.swift"
for capture in "$@"; do
    echo "######## $(basename "$capture")"
    "$work/read" "$capture"
done
