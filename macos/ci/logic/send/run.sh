#!/usr/bin/env bash
# The store's sending and rejoining, checked away from the app (Linux, or a Mac's own swiftc): what
# becomes of a message whose receipt the connection took, of one put into a running turn, of one
# said while the chat is being attached again, and what a page read in the chat's place keeps.
#
# The methods are the production ones: cut from the store's files as they are (extract.py), and
# compiled with AppStore+Compose.swift, Deliveries.swift, Delivery.swift, Compose.swift,
# NoticeCards.swift, Rejoin.swift, JSONValue.swift and EventCursors.swift whole, against stand-ins
# for the rest of the app (stubs.swift). main.swift runs them against a server it scripts and says
# what it expects, line by line. Exits non-zero when a check fails or the sources no longer compile
# with the stand-ins.
#
#   ./run.sh                    the checks, against the sources this file sits among
#   SWIFTC=/path/to/swiftc      another compiler than `swiftc`
#   SHION_ROOT=/another/copy    the production files of another copy of the repository
#   SHION_BEFORE=1              with SHION_ROOT at a copy from before the boundary named its
#                               messages (5e58a20 or older): leaves out the checks that name them,
#                               so the rest can be seen failing there
#
# What ReconnectTests has the stand-in do for the same cases end to end is checked apart, from
# Shion's side of the socket: ../../check_fake_reconnect.py.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${SHION_ROOT:-$(cd "$here/../../../.." && pwd)}"
model="$root/macos/Shion/Model"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 "$here/extract.py" "$root" "$work/extracted.swift"
# ChatEvent alone out of Models.swift, which needs SwiftUI for its other types
{ echo "import Foundation"; awk '/^nonisolated enum ChatEvent/,/^}/' "$model/Models.swift"; } > "$work/event.swift"
"${SWIFTC:-swiftc}" -swift-version 6 -default-isolation MainActor ${SHION_BEFORE:+-D BEFORE} -o "$work/checks" \
    "$here/main.swift" "$here/stubs.swift" "$work/extracted.swift" "$work/event.swift" \
    "$model/AppStore+Compose.swift" "$model/Deliveries.swift" "$model/Delivery.swift" "$model/Compose.swift" \
    "$model/NoticeCards.swift" "$model/Rejoin.swift" "$root/macos/Shion/Gateway/JSONValue.swift" \
    "$root/macos/Shion/Gateway/EventCursors.swift"
"$work/checks"
