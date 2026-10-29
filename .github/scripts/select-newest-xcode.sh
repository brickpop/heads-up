#!/usr/bin/env bash
# GitHub's macOS images carry several Xcode versions and default to an older one. HeadsUp needs
# Swift 6.4 or newer, so this selects the newest released Xcode on the runner, or the newest beta
# when no released one is installed. On a Mac with only the Command Line Tools, it leaves them
# selected.
set -euo pipefail
all=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V || true)
released=$(grep -vi beta <<<"$all" || true)
newest=$(tail -1 <<<"${released:-$all}")
if [ -n "$newest" ]; then
    sudo xcode-select -s "$newest/Contents/Developer"
    echo "Selected $newest"
else
    echo "No Xcode in /Applications: using $(xcode-select -p)"
fi
