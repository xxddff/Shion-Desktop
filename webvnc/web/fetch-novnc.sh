#!/usr/bin/env bash
# Puts an unmodified noVNC into web/vendor/novnc/: the npm tarball of the pinned version, checked
# against its registry integrity (sha512) before anything is unpacked. Only the files the page loads
# (core/, vendor/pako) and the license texts are kept. Nothing is changed in them: that keeps the
# MPL-2.0 obligations at "ship the licence, say where the source is" (no modified files to publish).
#
#   web/fetch-novnc.sh            # fetch (skips the download when the right version is already there)
#   web/fetch-novnc.sh --check    # fail unless the files on disk are exactly the tarball's
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=1.7.0   # the version Hermes' official desktop app pins (apps/desktop/package.json)
INTEGRITY=sha512-ucEJOx4T2avIRCleodk7YobZj5O2Ga2AeLfQ69A/yjG9HHba2+PDgwSkN3FttrmG+70ZGx21sElNFouK13RzyA==
URL="https://registry.npmjs.org/@novnc/novnc/-/novnc-$VERSION.tgz"
DEST="$HERE/vendor/novnc"
KEEP=(core vendor LICENSE.txt AUTHORS docs/LICENSE.MPL-2.0 docs/LICENSE.BSD-2-Clause docs/LICENSE.BSD-3-Clause docs/LICENSE.OFL-1.1)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/novnc.tgz" "$URL"
got="sha512-$(openssl dgst -sha512 -binary "$work/novnc.tgz" | base64 | tr -d '\n')"
[[ "$got" == "$INTEGRITY" ]] || { echo "noVNC $VERSION: integrity mismatch" >&2; exit 1; }
mkdir -p "$work/x"
tar xzf "$work/novnc.tgz" -C "$work/x"
src="$work/x/package"
grep -q "\"version\": \"$VERSION\"" "$src/package.json" || { echo "unexpected package.json" >&2; exit 1; }

if [[ "${1:-}" == --check ]]; then
  for p in "${KEEP[@]}"; do
    diff -r "$src/$p" "$DEST/$p" >/dev/null || { echo "vendor/novnc/$p differs from noVNC $VERSION" >&2; exit 1; }
  done
  # nothing extra either (a stray patched file next to the real ones)
  extra=$(cd "$DEST" && find . -type f ! -name VERSION | sed 's|^\./||' | while read -r f; do
    ok=0; for p in "${KEEP[@]}"; do [[ "$f" == "$p" || "$f" == "$p"/* ]] && ok=1; done; [[ $ok == 1 ]] || echo "$f"; done)
  [[ -z "$extra" ]] || { echo "unexpected files in vendor/novnc: $extra" >&2; exit 1; }
  echo "vendor/novnc is noVNC $VERSION, unmodified"
  exit 0
fi

rm -rf "$DEST"
mkdir -p "$DEST/docs"
for p in "${KEEP[@]}"; do cp -R "$src/$p" "$DEST/$p"; done
printf '%s\n%s\n%s\n' "$VERSION" "$URL" "$INTEGRITY" > "$DEST/VERSION"
echo "noVNC $VERSION -> ${DEST#"$HERE/"}"
