"""Cuts the store's sending, rejoining and retrying methods out of the production files, verbatim
(less `private`), into one `extension AppStore`, so they compile and run against stand-ins
(stubs.swift) away from the app. A method that moved or was renamed stops the run: say where it is
now. Usage:
    python3 extract.py <repository root> <out file>"""
import sys
from pathlib import Path

root, out = Path(sys.argv[1]), Path(sys.argv[2])

WANTED = {
    "macos/Shion/Model/AppStore.swift": ["func send(_ text: String, to botId: String, mode:", "func loadLatestPage(",
                                         "func uniqued(", "?func transcriptPage(",
                                         # a page's rows as the chat reads them
                                         "func transcriptItems(", "func chatItems(from row:", "static func noticeCards(",
                                         "static func sentMessage(", "static func madeCard(", "func text(of row:",
                                         "func toolLine("],
    "macos/Shion/Model/AppStore+Media.swift": [
        "func canSend(", "func sendMessage(", "func submit(_ words: String, _ drafts:", "static func retryable(",
        "static func userItem("],
    "macos/Shion/Model/AppStore+Control.swift": [
        "func noteFences(", "func controlNote(", "func retryTarget(", "static func startsTurn(", "static func endsTurn(",
        "func retryReply(",
        "func storedRow(", "?func rowNow(", "func rewind(to row:", "static func failedTurn("],
    "macos/Shion/Model/AppStore+Reconnect.swift": [
        "func say(", "func submit(_ text: String, id:", "func waitForChat(", "func requeue(", "func resend(",
        "func canResend(", "func rejoin(", "func keepReply(", "func reconcile(", "func settleCorrections(",
        "?func onPage(", "?func began("],
    # what 3e1c409 and a4c1a83 read an item's row from, to see them fail (SHION_ROOT)
    "macos/Shion/Model/AppStore+Events.swift": ["?static func rowNumber("],
}


def cut(lines, start):
    """The method that starts at `start` (its line), to its closing brace at the same indent."""
    first = start - 1 if lines[start - 1].strip() == "@discardableResult" else start
    for end in range(start, len(lines)):
        if lines[end] == "    }":
            return lines[first:end + 1]
    raise SystemExit(f"no end for {lines[start]}")


parts = ["import Foundation", "", "// Cut from the production files by extract.py: do not edit.", "extension AppStore {"]
for path, wanted in WANTED.items():
    lines = (root / path).read_text().split("\n")
    for signature in wanted:
        optional, signature = signature.startswith("?"), signature.removeprefix("?")
        found = [i for i, line in enumerate(lines)
                 if line.startswith("    ") and line.strip().removeprefix("private ").startswith(signature)]
        if optional and not found:
            continue
        if len(found) != 1:
            raise SystemExit(f"{path}: {signature!r} found {len(found)} times")
        body = cut(lines, found[0])
        body = [line.replace("    private func ", "    func ", 1) if line.startswith("    private func ") else line for line in body]
        parts += [f"    // {path}"] + body + [""]
parts.append("}")
out.write_text("\n".join(parts) + "\n")
print(f"cut {sum(len(v) for v in WANTED.values())} methods")
