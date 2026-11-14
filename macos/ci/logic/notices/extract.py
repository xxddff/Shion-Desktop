"""Cuts the store's reading of a turn's notice (followNotices, and what it calls in its file) out of
the app's files, verbatim (less `private`), into one `extension AppStore`, so it compiles and runs
against stand-ins (stubs.swift) away from the app. A declaration that moved or was renamed stops
the run: say where it is now. Usage:
    python3 extract.py <repository root> <out file>"""
import sys
from pathlib import Path

root, out = Path(sys.argv[1]), Path(sys.argv[2])

WANTED = {
    "macos/Shion/Model/AppStore+Events.swift": ["func followNotices(", "func awaitsOwnReply(", "static func notice(",
                                                "static func rowNumber(", "static let noticeRows"],
    "macos/Shion/Model/AppStore.swift": ["static let pageSize", "func transcriptPage("],
}


def cut(lines, start):
    """The declaration that starts at `start` (its line): that line alone when it opens no body,
    else to its closing brace at the same indent."""
    if not lines[start].rstrip().endswith("{"):
        return lines[start:start + 1]
    for end in range(start, len(lines)):
        if lines[end] == "    }":
            return lines[start:end + 1]
    raise SystemExit(f"no end for {lines[start]}")


parts = ["import Foundation", "", "// Cut from the app's files by extract.py: do not edit.", "extension AppStore {"]
for path, wanted in WANTED.items():
    lines = (root / path).read_text().split("\n")
    for signature in wanted:
        found = [i for i, line in enumerate(lines)
                 if line.startswith("    ") and line.strip().removeprefix("private ").startswith(signature)]
        if len(found) != 1:
            raise SystemExit(f"{path}: {signature!r} found {len(found)} times")
        body = cut(lines, found[0])
        body[0] = body[0].replace("    private ", "    ", 1)
        parts += [f"    // {path}"] + body + [""]
parts.append("}")
out.write_text("\n".join(parts) + "\n")
print(f"cut {sum(len(v) for v in WANTED.values())} declarations")
