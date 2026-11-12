#!/bin/bash
# xcodebuild's warnings do not become annotations by themselves: list them, so a run with any
# shows them on its page.
#   ci/compiler_warnings.sh build/xcodebuild.log …     (from macos/)
warnings=$(cat "$@" 2>/dev/null | grep -E '^/.*: warning: ' | sort -u || true)
if [ -z "$warnings" ]; then
  echo "no compiler warnings"
else
  while IFS= read -r line; do
    echo "::warning title=Compiler::${line#"$PWD/"}"
  done <<< "$warnings"
fi
