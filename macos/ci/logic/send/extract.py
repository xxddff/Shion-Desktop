"""Cuts the store's sending and rejoining methods out of the production files, verbatim (less
`private`), into one `extension AppStore`, so they compile and run against stand-ins (stubs.swift)
away from the app. A method that moved or was renamed stops the run: say where it is now. Usage:
    python3 extract.py <repository root> <out file>"""
import sys
from pathlib import Path

root, out = Path(sys.argv[1]), Path(sys.argv[2])

WANTED = {
    "macos/Shion/Model/AppStore.swift": ["func send(_ text: String, to botId: String, mode:", "func loadLatestPage(",
                                         "func uniqued("],
    "macos/Shion/Model/AppStore+Media.swift": [
        "func canSend(", "func sendMessage(", "func submit(_ words: String, _ drafts:"],
    "macos/Shion/Model/AppStore+Reconnect.swift": [
        "func say(", "func submit(_ text: String, id:", "func waitForChat(", "func requeue(", "func resend(",
        "func canResend(", "func rejoin(", "func keepReply(", "func reconcile(", "func settleCorrections(",
        "?func onPage("],
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
