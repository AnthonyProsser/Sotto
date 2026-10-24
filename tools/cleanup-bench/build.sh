#!/bin/zsh
# Builds ./bench from the shipping Cleanup.swift plus the bench's own files.
# Pass a directory to compile a different Cleanup.swift (a candidate's copy);
# SOTTO names the repo when the bench has been copied out of it. Extra bench
# sources go in EXTRA.
set -e
cd "${0:A:h}"
root="${SOTTO:-../..}"
src="${1:-$root/Sotto/Dictation}"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -swift-version 6 \
  "$src/Cleanup.swift" "$src/CleanupRules.swift" "$root/Sotto/Dictation/DictationProfile.swift" \
  Shims.swift Variant.swift main.swift ${=EXTRA} -o bench
