#!/usr/bin/env bash
# Checks that this Mac's Swift is at least the series the project is checked with: the
# major.minor in .swift-version (6.2 for 6.2.4). Linux tests with exactly that release.
#   - Older: refused, with how to update. The code may use what that series added.
#   - The same series, any patch release: accepted, silently.
#   - Newer: accepted, with a one-line note. A newer Swift can warn where Linux's doesn't, and
#     warnings are errors here: if one stops the build, paste it to the team to fix.
# tools/swift.sh runs it on macOS, before a build fails less clearly.
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
need_major=${BASH_REMATCH[1]} need_minor=${BASH_REMATCH[2]}
series=$need_major.$need_minor

IFS=. read -r have_major have_minor _ <<<"$have"
have_minor=${have_minor:-0}
# Compares number by number, so 6.10 is newer than 6.2.
if ((10#$have_major < 10#$need_major || (10#$have_major == 10#$need_major && 10#$have_minor < 10#$need_minor))); then
    echo "HeadsUp needs Swift $series or newer; this Mac has Swift $have. Update the Command Line Tools:" \
        "softwareupdate --list, then install the newest \"Command Line Tools for Xcode\"." >&2
    exit 1
fi
if ((10#$have_major != 10#$need_major || 10#$have_minor != 10#$need_minor)); then
    echo "Note: this Mac has Swift $have, newer than the $series that Linux checks; building anyway." >&2
fi
exit 0
