#!/usr/bin/env bash
# Writes the Homebrew cask for one release to stdout, from packaging/homebrew/headsup.rb.in.
# The release workflow commits it to the tap as Casks/headsup.rb.
#
# Usage: tools/render-cask.sh <version> <sha256 of the .dmg> <owner/repo> <bundle id>
set -euo pipefail

die() {
    echo "render-cask: $*" >&2
    exit 1
}

[ $# -eq 4 ] || die "usage: tools/render-cask.sh <version> <sha256> <owner/repo> <bundle id>"
version=$1 sha256=$2 repo=$3 bundle_id=$4

# Every value lands in Ruby source: keep each to the characters it needs.
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "'$version' is not a version like 1.2.3"
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || die "'$sha256' is not a SHA-256 in lower-case hex"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "'$repo' is not owner/repo"
[[ "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "'$bundle_id' is not a bundle identifier"

template="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/packaging/homebrew/headsup.rb.in"
sed -e "s|@VERSION@|$version|g" -e "s|@SHA256@|$sha256|g" -e "s|@REPO@|$repo|g" \
    -e "s|@BUNDLE_ID@|$bundle_id|g" "$template"
