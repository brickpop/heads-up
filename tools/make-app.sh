#!/usr/bin/env bash
# Builds build/HeadsUp.app on macOS (ADR-001 §10), for both arm64 and x86_64,
# signed with the hardened runtime and the entitlements in Resources/.
#
# Usage: tools/make-app.sh <adhoc|identity> <bundle id> <version> <build number>
#   adhoc     signs with no identity (`just app`). macOS forgets the app's permissions
#             and Keychain access after each ad-hoc build.
#   identity  signs with $HEADSUP_SIGN_ID, a code-signing identity in your keychain,
#             and then makes build/HeadsUp.dmg (`just build`).
set -euo pipefail

die() {
    echo "make-app: $*" >&2
    exit 1
}

[ $# -eq 4 ] || die "usage: tools/make-app.sh <adhoc|identity> <bundle id> <version> <build number>"
mode=$1 bundle_id=$2 version=$3 build_number=$4

[ "$(uname -s)" = Darwin ] || die "building HeadsUp.app needs macOS with Xcode."
# Values that end up inside Info.plist: keep them to safe characters.
[[ "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "'$bundle_id' is not a bundle identifier"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "'$version' is not a version like 1.2.3"
[[ "$build_number" =~ ^[0-9]+$ ]] || die "'$build_number' is not a build number"

case "$mode" in
adhoc) sign_id=- ;;
identity)
    sign_id=${HEADSUP_SIGN_ID:-}
    [ -n "$sign_id" ] || die "set HEADSUP_SIGN_ID to your signing identity. To list them: security find-identity -v -p codesigning"
    ;;
*) die "mode must be adhoc or identity, not '$mode'" ;;
esac

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

echo "make-app: $(xcrun swift --version 2>&1 | head -n 1)"

# Only the versions in Package.resolved, and no resolution at build time (F15).
swift_args=(-c release --arch arm64 --arch x86_64 --only-use-versions-from-resolved-file --disable-automatic-resolution)
swift build "${swift_args[@]}"
bin_dir=$(swift build "${swift_args[@]}" --show-bin-path)

app=build/HeadsUp.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/HeadsUp" "$app/Contents/MacOS/HeadsUp"
# The app icon (CFBundleIconFile) and the menu bar glyph, which the shell loads from the bundle.
for resource in AppIcon.icns MenuBarGlyph.pdf; do
    [ -f "Resources/$resource" ] || die "Resources/$resource is missing"
    cp "Resources/$resource" "$app/Contents/Resources/$resource"
done
sed -e "s/@BUNDLE_ID@/$bundle_id/" -e "s/@VERSION@/$version/" -e "s/@BUILD_NUMBER@/$build_number/" \
    Resources/Info.plist >"$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

codesign --force --options runtime --timestamp=none \
    --entitlements Resources/HeadsUp.entitlements -s "$sign_id" "$app"
codesign --verify --strict --deep "$app"

# Read back what was signed (F8): exactly the two allowed entitlements, both true, and
# the hardened runtime on. Both sides go through plutil, so key order and layout don't matter.
check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
codesign -d --entitlements - --xml "$app" >"$check/signed.plist" 2>/dev/null ||
    die "could not read the signed entitlements"
cat >"$check/expected.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.personal-information.calendars</key>
    <true/>
</dict>
</plist>
EOF
plutil -convert json -o "$check/signed.json" "$check/signed.plist"
plutil -convert json -o "$check/expected.json" "$check/expected.plist"
if ! cmp -s "$check/signed.json" "$check/expected.json"; then
    die "the signed entitlements are not exactly apple-events and calendars, both true. Signed: $(cat "$check/signed.json")"
fi
codesign -dv "$app" 2>&1 | grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' ||
    die "the app is signed without the hardened runtime"
echo "make-app: signed entitlements: $(cat "$check/signed.json"), hardened runtime on"
echo "make-app: built $app ($bundle_id $version, build $build_number)"

if [ "$mode" = identity ]; then
    dmg=build/HeadsUp.dmg
    hdiutil create -volname HeadsUp -srcfolder "$app" -ov -format UDZO "$dmg" >/dev/null
    echo "make-app: built $dmg"
fi
