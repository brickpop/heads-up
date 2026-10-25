#!/usr/bin/env bash
# Checks that this Mac's Swift is the series the project builds with: the major.minor in
# .swift-version (6.2 for 6.2.4), any patch release. Linux builds with exactly that release, so
# a newer Swift on the Mac could accept code the Linux build refuses, and an older one could
# refuse code Linux accepts. tools/swift.sh runs it on macOS, before a build fails less clearly.
#
# Usage: tools/check-swift-version.sh "<output of swift --version>" [path to .swift-version]
set -euo pipefail

output=${1:-}
pin_file=${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.swift-version}

# "swift-driver version: 1.127.14 Apple Swift version 6.2.3 (swiftlang-…)" → 6.2.3
if [[ "$output" =~ Swift\ version\ ([0-9]+(\.[0-9]+)*) ]]; then
    have=${BASH_REMATCH[1]}
else
    echo "Couldn't tell which Swift this is. Install the Command Line Tools: xcode-select --install" >&2
    exit 1
fi
pinned=$(tr -d '[:space:]' <"$pin_file" 2>/dev/null || true)
[[ "$pinned" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]] || {
    echo "Couldn't read a Swift version like 6.2.4 from $pin_file" >&2
    exit 1
}
series=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}

IFS=. read -r have_major have_minor _ <<<"$have"
if [ "$have_major.${have_minor:-0}" != "$series" ]; then
    echo "HeadsUp builds with Swift $series.x (Linux uses $pinned); this Mac has Swift $have." \
        "Install the \"Command Line Tools for Xcode\" that ship Swift $series (see the README)," \
        "from https://developer.apple.com/download/all/, then check with: swift --version" >&2
    exit 1
fi
exit 0
