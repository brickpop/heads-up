#!/usr/bin/env bash
# Builds build/HeadsUp.app on macOS (ADR-001 §10), for both arm64 and x86_64,
# signed with the hardened runtime and the entitlements in Resources/.
#
# Usage: tools/make-app.sh <adhoc|identity|quick> <bundle id> <version> <build number>
#   adhoc     signs with no identity (`just app`). macOS forgets the app's permissions
#             and Keychain access after each ad-hoc build.
#   identity  signs with $HEADSUP_SIGN_ID, a code-signing identity in your keychain,
#             and then makes build/HeadsUp.dmg (`just build`).
#   quick     a debug build for this Mac only, signed ad-hoc, where one timer minute lasts
#             5 seconds (`just app-quick`), for checking a whole Focus round quickly. It is a
#             separate app, "HeadsUp Quick" (build/HeadsUp Quick.app, bundle id <id>.quick,
#             data in ~/Library/Application Support/HeadsUp-Quick), so it never touches the real one.
#             The release modes refuse to finish if their binary has the quick timers.
set -euo pipefail

die() {
    echo "make-app: $*" >&2
    exit 1
}

[ $# -eq 4 ] || die "usage: tools/make-app.sh <adhoc|identity|quick> <bundle id> <version> <build number>"
mode=$1 bundle_id=$2 version=$3 build_number=$4

[ "$(uname -s)" = Darwin ] || die "building HeadsUp.app needs macOS, with the Command Line Tools (Xcode isn't needed)."
# Values that end up inside Info.plist: keep them to safe characters.
[[ "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "'$bundle_id' is not a bundle identifier"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "'$version' is not a version like 1.2.3"
[[ "$build_number" =~ ^[0-9]+$ ]] || die "'$build_number' is not a build number"

# The quick build is a separate app: its own name, bundle id (so its permissions and Keychain
# entries are its own) and data folder (HeadsUp-Quick, chosen by the app itself).
name=HeadsUp
if [ "$mode" = quick ]; then
    name="HeadsUp Quick"
    bundle_id="$bundle_id.quick"
fi

case "$mode" in
adhoc | quick) sign_id=- ;;
identity)
    sign_id=${HEADSUP_SIGN_ID:-}
    [ -n "$sign_id" ] || die "set HEADSUP_SIGN_ID to your signing identity. To list them: security find-identity -v -p codesigning"
    ;;
*) die "mode must be adhoc, identity or quick, not '$mode'" ;;
esac

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

echo "make-app: $(swift --version 2>&1 | head -n 1)"

# One build per architecture: building both at once needs Xcode's build system (xcbuild),
# which the Command Line Tools don't have. lipo then joins them into one universal binary.
# Only the versions in Package.resolved, and no resolution at build time (F15).
resolved=(--only-use-versions-from-resolved-file --disable-automatic-resolution)
if [ "$mode" = quick ]; then
    # A debug build for this Mac only.
    architectures=("$(uname -m)")
    build_args=(-c debug -Xswiftc -DHEADSUP_QUICK_TIMERS)
else
    architectures=(arm64 x86_64)
    build_args=(-c release)
fi
binaries=()
for arch in "${architectures[@]}"; do
    swift_args=("${build_args[@]}" --build-system native --triple "$arch-apple-macosx14.0" "${resolved[@]}")
    tools/swift.sh build "${swift_args[@]}"
    binaries+=("$(tools/swift.sh build "${swift_args[@]}" --show-bin-path)/HeadsUp")
done

# The quick timers exist only in debug builds; a release binary that has their log line fails.
quick_marker="HeadsUp quick timers"
if [ "$mode" != quick ]; then
    for binary in "${binaries[@]}"; do
        if grep -qa "$quick_marker" "$binary"; then
            die "this release binary contains the debug quick timers. Build it without -DHEADSUP_QUICK_TIMERS."
        fi
    done
fi

app="build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create -output "$app/Contents/MacOS/HeadsUp" "${binaries[@]}"
archs=" $(lipo -archs "$app/Contents/MacOS/HeadsUp") "
for arch in "${architectures[@]}"; do
    [[ "$archs" == *" $arch "* ]] || die "the app's binary has no $arch slice: $(lipo -info "$app/Contents/MacOS/HeadsUp")"
done
echo "make-app: $(lipo -info "$app/Contents/MacOS/HeadsUp")"
# The app icon (CFBundleIconFile) and the menu bar glyph, which the shell loads from the bundle.
for resource in AppIcon.icns MenuBarGlyph.pdf; do
    [ -f "Resources/$resource" ] || die "Resources/$resource is missing"
    cp "Resources/$resource" "$app/Contents/Resources/$resource"
done
sed -e "s/@BUNDLE_ID@/$bundle_id/" -e "s/@NAME@/$name/" -e "s/@VERSION@/$version/" -e "s/@BUILD_NUMBER@/$build_number/" \
    Resources/Info.plist >"$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

codesign --force --options runtime --timestamp=none \
    --entitlements Resources/HeadsUp.entitlements -s "$sign_id" "$app"
codesign --verify --strict --deep "$app"

# Read back what was signed (F8), for each architecture's slice: exactly the two allowed
# entitlements, both true, and the hardened runtime on. Both sides go through plutil, so key
# order and layout don't matter.
check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
cat >"$check/expected.plist" <<'PLIST'
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
PLIST
plutil -convert json -o "$check/expected.json" "$check/expected.plist"
for arch in "${architectures[@]}"; do
    codesign -d --arch "$arch" --entitlements - --xml "$app" >"$check/signed-$arch.plist" 2>/dev/null ||
        die "could not read the signed entitlements of the $arch slice"
    plutil -convert json -o "$check/signed-$arch.json" "$check/signed-$arch.plist"
    if ! cmp -s "$check/signed-$arch.json" "$check/expected.json"; then
        die "the $arch slice's signed entitlements are not exactly apple-events and calendars, both true. Signed: $(cat "$check/signed-$arch.json")"
    fi
    codesign -dv --arch "$arch" "$app" 2>&1 | grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' ||
        die "the $arch slice is signed without the hardened runtime"
    echo "make-app: $arch: signed entitlements $(cat "$check/signed-$arch.json"), hardened runtime on"
done
echo "make-app: built $app ($bundle_id $version, build $build_number)"

if [ "$mode" = identity ]; then
    dmg=build/HeadsUp.dmg
    hdiutil create -volname HeadsUp -srcfolder "$app" -ov -format UDZO "$dmg" >/dev/null
    echo "make-app: built $dmg"
fi
