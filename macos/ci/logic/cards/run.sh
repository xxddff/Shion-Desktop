#!/usr/bin/env bash
# The cards for what Hermes says on its own (main.swift) against the app's own StatusCards.swift and
# Compose.swift, and the store's reading of those frames (AppStore.noteSaid and what it reaches), of
# the chat as it shows (shownChat) and of a page's rows into the chat's items (transcriptItems,
# chatItems and what they call), cut from the app's files as they are by extract.py, with
# Delivery.swift for the rows that name a submission (chatItems asks: DeliveryCheck.submission),
# against stand-ins for the rest of the app (stubs.swift). Fed the frames and pages Hermes itself gave
# (held.json, from ../../real stage held: compactions held open, a prompt, a steer and a redirect
# sent meanwhile; status.json, stage status: notices, a fallback, a wait for the provider, a side
# question, a side task, a goal's verdict) and scripted ones.
#   ./run.sh                    SWIFTC names the compiler where `swiftc` is not it
#   SHION_ROOT=/another/copy    the app's files of another copy of the repository
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${SHION_ROOT:-$(cd "$here/../../../.." && pwd)}"
model="$root/macos/Shion/Model"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 "$here/extract.py" "$root" "$work/extracted.swift"
# ChatEvent, ChatRole and ChatItem alone out of Models.swift, which needs SwiftUI for its other types
{ echo "import Foundation"; awk '/^nonisolated enum ChatEvent/,/^}/' "$model/Models.swift"
  awk '/^enum ChatRole/,/^}/' "$model/Models.swift"; awk '/^struct ChatItem:/,/^}/' "$model/Models.swift"; } > "$work/event.swift"
grep -q "var startsTurn" "$work/event.swift"
"${SWIFTC:-swiftc}" -swift-version 6 -default-isolation MainActor -o "$work/check" \
    "$here/main.swift" "$here/stubs.swift" "$work/extracted.swift" "$work/event.swift" \
    "$model/StatusCards.swift" "$model/Compose.swift" "$model/Notices.swift" "$model/Delivery.swift" \
    "$model/Silence.swift" "$model/TurnFailure.swift" "$model/ChatMedia.swift" \
    "$root/macos/Shion/Gateway/JSONValue.swift"
"$work/check" "$here/held.json" "$here/status.json"
