#!/usr/bin/env bash
# Installs just on a GitHub-hosted macOS runner (Apple silicon): a pinned release, checked
# against its SHA-256 before it runs, then put on PATH for the next steps. Brew's just would be
# whatever version brew has that day.
#
# To update: take the new version's line for just-<version>-aarch64-apple-darwin.tar.gz from that
# release's SHA256SUMS, and check it against a download of your own.
set -euo pipefail

version=1.59.0
sha256=6574cea774ed4cae12e24b6aa11857de33e80dab4667cf628fd5840df96a2a9d
archive="just-$version-aarch64-apple-darwin.tar.gz"

[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || {
    echo "install-just: this is for macOS on Apple silicon, not $(uname -s)-$(uname -m)" >&2
    exit 1
}
dir="${RUNNER_TEMP:?}/just-$version"
mkdir -p "$dir"
curl -fsSL --proto '=https' -o "$dir/$archive" "https://github.com/casey/just/releases/download/$version/$archive"
echo "$sha256  $dir/$archive" | shasum -a 256 -c -
tar -xzf "$dir/$archive" -C "$dir" just
"$dir/just" --version
echo "$dir" >>"${GITHUB_PATH:?}"
