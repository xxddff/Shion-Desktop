"""Cuts the Bot Chat's attach and rejoin out of the app's files, verbatim (less `private`), into
one `extension AppStore`, so they compile and run against stand-ins away from a Mac. Usage:
    python3 extract.py <repository root> <out file> [old]
`old`: a tree from before `resumed` and `runs` existed (they are then not looked for)."""
import sys
from pathlib import Path

root, out = Path(sys.argv[1]), Path(sys.argv[2])
old = len(sys.argv) > 3

WANTED = {
    "macos/Shion/Model/AppStore.swift": ["func resumeParams(", "func attach(_ botId: String, snapshot:"]
    + ([] if old else ["func resumed(", "func runs("]),
    "macos/Shion/Model/AppStore+Reconnect.swift": ["func rejoin(", "func keepReply(", "func settleAsks("],
    "macos/Shion/Model/AppStore+Secrets.swift": ["func resumeSecrets("],
}


def cut(lines, start):
    """The method that starts at `start` (its line), to its closing brace at the same indent."""
    for end in range(start, len(lines)):
        if lines[end] == "    }":
            return lines[start:end + 1]
    raise SystemExit(f"no end for {lines[start]}")


parts = ["import Foundation", "", "// Cut from the app's files by extract.py: do not edit.", "extension AppStore {"]
count = 0
for path, wanted in WANTED.items():
    lines = (root / path).read_text().split("\n")
    for signature in wanted:
        found = [i for i, line in enumerate(lines)
                 if line.startswith("    ") and line.strip().removeprefix("private ").startswith(signature)]
        if len(found) != 1:
            raise SystemExit(f"{path}: {signature!r} found {len(found)} times")
        body = cut(lines, found[0])
        body = [line.replace("    private func ", "    func ", 1) if line.startswith("    private func ") else line for line in body]
        parts += [f"    // {path}"] + body + [""]
        count += 1
parts.append("}")
out.write_text("\n".join(parts) + "\n")
print(f"cut {count} methods")
