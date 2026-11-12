#!/bin/bash
# The password SecretsTests types must never be written down: not by the stand-in (it logs names
# and ids only), not by Shion (its preferences, Application Support). An answer must go out once.
#   ci/no_password_written.sh [folder with fake_hermes-*.log]     (default build)
logs="${1:-build}"
found=""
for log in "$logs"/fake_hermes-*.log; do
  if [ -f "$log" ] && grep -qF 'ci-sudo-Pa55' "$log"; then found="$found $log"; fi
done
if defaults read dev.shion.Shion 2>/dev/null | grep -qF 'ci-sudo-Pa55'; then found="$found preferences"; fi
if grep -rqF 'ci-sudo-Pa55' "$HOME/Library/Application Support/dev.shion.Shion" 2>/dev/null; then
  found="$found application-support"
fi
if [ -n "$found" ]; then
  echo "::error title=Secrets::the password SecretsTests typed is written down in:$found"
  exit 1
fi
if grep -qF '!! answered twice' "$logs/fake_hermes-SecretsTests.log" 2>/dev/null; then
  echo "::error title=Secrets::Shion answered a request twice (fake_hermes-SecretsTests.log)"
  exit 1
fi
echo "the password is in none of the stand-in logs, the preferences or Application Support"
