#!/usr/bin/env bash
# The notice cards' checks (main.swift) against the app's own NoticeCards.swift and Notices.swift,
# and the store's reading of a turn's notice (AppStore.followNotices and the page read it goes
# through, AppStore.transcriptPage), of a page's rows into the chat's items (AppStore.transcriptItems,
# chatItems and what they call) and of the talk before a skill (AppStore.talkBefore), cut from the
# app's files as they are by extract.py, with Delivery.swift for the rows that name a submission and
# the files the rows are read with whole, against stand-ins for the rest of the app (stubs.swift) and
# transcripts paged as Hermes pages them, some of them Hermes's own, read before and after a
# compaction (compaction.json, from ../../real stage compact; autocompaction.json and copies.json,
# stages auto and copies, Hermes compacting by itself).
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
grep -q "var midTurn" "$work/event.swift"
"${SWIFTC:-swiftc}" -swift-version 6 -default-isolation MainActor -o "$work/check" \
    "$here/main.swift" "$here/stubs.swift" "$work/extracted.swift" "$work/event.swift" \
    "$model/NoticeCards.swift" "$model/Notices.swift" "$model/Delivery.swift" "$model/Silence.swift" \
    "$model/TurnFailure.swift" "$model/ChatMedia.swift" "$model/SkillReview.swift" \
    "$root/macos/Shion/Gateway/JSONValue.swift"
"$work/check" "$here/compaction.json" "$here/autocompaction.json" "$here/copies.json"
