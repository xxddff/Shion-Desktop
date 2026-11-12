#!/bin/bash
# Takes the screenshots and other attachments out of result bundles and puts them, with the
# stand-in's logs, in build/shots under the names the tests gave them.
#   ci/export_shots.sh Shots SignInTests …     (from macos/; build/<name>.xcresult each)
mkdir -p build/shots
for bundle in "$@"; do
  if [ -d "build/$bundle.xcresult" ]; then
    mkdir -p "build/export-$bundle"
    xcrun xcresulttool export attachments --path "build/$bundle.xcresult" --output-path "build/export-$bundle" \
      || echo "attachment export failed for $bundle"
  fi
done
cp build/fake_hermes-*.log build/shots/ 2>/dev/null || true
python3 - "$@" <<'PY'
import json, os, re, shutil, sys
out = 'build/shots'
for bundle in sys.argv[1:]:
    folder = f'build/export-{bundle}'
    manifest = os.path.join(folder, 'manifest.json')
    if not os.path.exists(manifest):
        continue
    for test in json.load(open(manifest)):
        for item in test.get('attachments', []):
            source = os.path.join(folder, item.get('exportedFileName', ''))
            # XCTest's own UI snapshots and synthesized events have no extension; skip them
            if not source.endswith(('.png', '.txt', '.mp4')) or not os.path.isfile(source):
                continue
            name = item.get('suggestedHumanReadableName') or os.path.basename(source)
            name = re.sub(r'_\d+_[0-9A-Fa-f-]{36}', '', name)
            # upload-artifact refuses " : < > | * ? and line breaks (XCTest's debug descriptions quote ids)
            name = re.sub(r'["`:<>|*?\r\n]', '', name).strip()
            # newest first: an older attachment of the same name (the UI hierarchy XCTest
            # keeps at each failed lookup) gets a number instead of replacing it
            target, (stem, extension), count = os.path.join(out, name), os.path.splitext(name), 2
            while os.path.exists(target):
                target = os.path.join(out, f'{stem} {count}{extension}')
                count += 1
            shutil.move(source, target)
print('\n'.join(sorted(os.listdir(out))))
PY
