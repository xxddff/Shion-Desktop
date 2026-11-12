#!/usr/bin/env python3
"""Puts every job's screenshots and stand-in logs (one folder per job) into one folder.

    collect_shots.py parts shots

Names are the tests' own, so they differ between jobs; where two jobs did write the same name
(XCTest's "App UI hierarchy" at a failed lookup), the later one gets a number instead of
replacing the first.
"""
import filecmp, os, shutil, sys

parts, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
for part in sorted(os.listdir(parts)) if os.path.isdir(parts) else []:
    for folder, _, names in os.walk(os.path.join(parts, part)):
        for name in sorted(names):
            source = os.path.join(folder, name)
            target, (stem, extension), count = os.path.join(out, name), os.path.splitext(name), 2
            while os.path.exists(target) and not filecmp.cmp(source, target, shallow=False):
                target = os.path.join(out, f'{stem} {count}{extension}')
                count += 1
            shutil.copyfile(source, target)
    print(f'{part}: collected')
print(f'{len(os.listdir(out))} files')
print('\n'.join(sorted(os.listdir(out))))
