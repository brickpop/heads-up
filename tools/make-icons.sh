#!/usr/bin/env bash
# Rebuilds the icon files in Resources/ from the SVG sources in Resources/Icons/source/:
# MenuBarGlyph.pdf, MenuBarGlyph.png, MenuBarGlyph@2x.png and AppIcon.icns.
#
# Usage: tools/make-icons.sh
# Needs Node.js and npm. Works on Linux and macOS. It installs one pinned package,
# @resvg/resvg-js, into a temporary folder (with install scripts off) and removes it after.
# This is a manual tool for when the SVGs change; `just build` never runs it.
set -euo pipefail

die() {
    echo "make-icons: $*" >&2
    exit 1
}

resvg_version=2.6.2

command -v node >/dev/null || die "needs Node.js"
command -v npm >/dev/null || die "needs npm"

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

npm install --prefix "$tmp" --ignore-scripts --no-audit --no-fund --silent "@resvg/resvg-js@$resvg_version" ||
    die "couldn't install @resvg/resvg-js@$resvg_version"

NODE_PATH="$tmp/node_modules" node "$root/tools/make-icons.js" "$root/Resources/Icons/source" "$root/Resources"
echo "make-icons: wrote MenuBarGlyph.pdf, MenuBarGlyph.png, MenuBarGlyph@2x.png and AppIcon.icns in Resources/"
