#!/usr/bin/env bash
# Every group of logic checks under this directory (each has its own run.sh), one after another;
# fails if any check of any group fails. No Xcode project, no window: the app's own source files
# compiled with small stand-ins and run against scripted answers.
#   ./run.sh [group...]     default: every group. SWIFTC names the compiler where `swiftc` is not it
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
groups=("$@")
if [ ${#groups[@]} -eq 0 ]; then
    for script in "$here"/*/run.sh; do groups+=("$(basename "$(dirname "$script")")"); done
fi
failed=()
for group in "${groups[@]}"; do
    echo "######## $group"
    if ! bash "$here/$group/run.sh" > "$here/.$group.out" 2>&1; then failed+=("$group"); fi
    grep -v "^ *ok " "$here/.$group.out" | tail -40
    echo "$group: $(grep -c "^ *ok " "$here/.$group.out") ok"
    rm -f "$here/.$group.out"
done
if [ ${#failed[@]} -gt 0 ]; then echo "FAILED: ${failed[*]}"; exit 1; fi
echo "all groups passed"
