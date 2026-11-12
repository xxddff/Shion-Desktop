#!/bin/bash
# Xcode's compilation cache (build/cas), kept between runs by actions/cache: says how big it is
# before and after a build, so a run's log shows whether it started with one.
#   ci/compile_cache.sh before|after     (from macos/)
cas=build/cas
size() { du -sm "$cas" 2>/dev/null | cut -f1; }
case "$1" in
  before)
    if [ -d "$cas" ]; then
      echo "compile cache: $(size) MB restored, $(find "$cas" -type f | wc -l | tr -d ' ') files"
      # every run adds to it; past 3 GB start again instead of carrying old results along
      if [ "$(size)" -gt 3000 ]; then
        echo "compile cache: over 3 GB, starting again"
        rm -rf "$cas"
      fi
    else
      echo "compile cache: none restored, this build fills it"
    fi
    ;;
  after)
    if [ -d "$cas" ] && [ -n "$(find "$cas" -type f | head -1)" ]; then
      echo "compile cache: $(size) MB after the build, $(find "$cas" -type f | wc -l | tr -d ' ') files"
      ls -la "$cas"
    else
      echo "::warning title=Compile cache::build/cas is empty after the build: Xcode did not use it"
      find build "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 3 -iname '*CompilationCache*' 2>/dev/null || true
    fi
    ;;
esac
