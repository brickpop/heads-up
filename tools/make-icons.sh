#!/usr/bin/env bash
# Rebuilds the icon files in Resources/ from the SVG sources in Resources/Icons/source/:
# MenuBarGlyph.pdf, MenuBarGlyph.png, MenuBarGlyph@2x.png and AppIcon.icns.
#
# Usage: tools/make-icons.sh
# Needs Node.js and npm. Works on Linux and macOS. It installs one pinned package,
# @resvg/resvg-js, into a temporary folder with `npm ci` from tools/icons/package-lock.json
# (sha512-checked, install scripts off) and removes it after.
# This is a manual tool for when the SVGs change; `just build` never runs it.
set -euo pipefail

die() {
    echo "make-icons: $*" >&2
    exit 1
}

command -v node >/dev/null || die "needs Node.js"
command -v npm >/dev/null || die "needs npm"

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$root/tools/icons/package.json" "$root/tools/icons/package-lock.json" "$tmp/"
(cd "$tmp" && npm ci --ignore-scripts --registry=https://registry.npmjs.org/ --no-audit --no-fund --silent) ||
    die "couldn't install the pinned packages in tools/icons/package-lock.json"
# npm skips an optional package whose sha512 doesn't match, without failing: the renderer
# for this platform is one, so check that it loads.
NODE_PATH="$tmp/node_modules" node -e 'require("@resvg/resvg-js")' 2>/dev/null ||
    die "the renderer for this platform wasn't installed. Look for a 'corrupted' warning from npm above."

NODE_PATH="$tmp/node_modules" node "$root/tools/make-icons.js" "$root/Resources/Icons/source" "$root/Resources"
echo "make-icons: wrote MenuBarGlyph.pdf, MenuBarGlyph.png, MenuBarGlyph@2x.png and AppIcon.icns in Resources/"
