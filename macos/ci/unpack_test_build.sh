#!/bin/bash
# Unpacks the test build the build job handed on (build/test-products.tar.gz) where it was built,
# checks that the signatures came through, and tells later steps where the .xctestrun is.
#   ci/unpack_test_build.sh     (from macos/)
set -euo pipefail
mkdir -p build/DerivedData/Build
tar -xzf build/test-products.tar.gz -C build/DerivedData/Build
rm build/test-products.tar.gz
products=build/DerivedData/Build/Products
ls "$products" "$products/Debug"
codesign --verify --deep --strict --verbose=2 "$products/Debug/Shion.app"
codesign --verify --deep --verbose=2 "$products/Debug/ShionUITests-Runner.app" \
  || echo "::warning title=Test build::the test runner's signature does not verify after unpacking"
run=$(ls "$products"/*.xctestrun)
echo "XCTESTRUN=$PWD/$run" >> "$GITHUB_ENV"
echo "test-without-building runs from $run"
