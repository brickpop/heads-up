#!/usr/bin/env bash
# Prints HeadsUp's version. The release tag (vX.Y.Z) is the only place it is written.
#
# Usage:
#   tools/version.sh         the latest vX.Y.Z tag reachable from HEAD, without its v; 0.0.0
#                            when there is none (a fork, or a clone without tags). Tags that
#                            aren't vX.Y.Z (v1.0-beta, v2) are skipped. The justfile uses this.
#   tools/version.sh <tag>   the release tag's version, without its v; it stops if the tag isn't
#                            vX.Y.Z. The release workflow uses this, and make-app.sh and
#                            render-cask.sh check their version through it.
#
# X, Y and Z are whole numbers with no leading zeros: 1.10.0, not 1.010.0.
#
# Written for the bash 3.2 macOS ships, as well as Linux's.
set -euo pipefail

is_version() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

if [ $# -eq 1 ]; then
    is_version "${1#v}" && [ "${1:0:1}" = v ] ||
        { echo "version: the tag is '$1', but a release tag must be vX.Y.Z, like v1.2.3." >&2; exit 1; }
    echo "${1#v}"
    exit 0
fi
[ $# -eq 0 ] || { echo "usage: tools/version.sh [vX.Y.Z]" >&2; exit 1; }

# The nearest v-tag, then the nearest one again without each tag that isn't vX.Y.Z.
skip=()
while tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' ${skip[@]+"${skip[@]}"} 2>/dev/null); do
    if is_version "${tag#v}"; then
        echo "${tag#v}"
        exit 0
    fi
    skip+=(--exclude "$tag")
done
echo 0.0.0
