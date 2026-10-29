#!/usr/bin/env bash
# Builds build/HeadsUp.app on macOS (ADR-001 §10), for Apple silicon (arm64) only,
# signed with the hardened runtime and the entitlements in Resources/.
#
# Usage: tools/make-app.sh <adhoc|adhoc-release|identity|quick> <bundle id> <version> <build number>
#   adhoc     signs with no identity (`just app`). macOS forgets the app's permissions
#             and Keychain access after each ad-hoc build.
#   adhoc-release  the public release while there is no signing identity (`just release-adhoc`,
#             run by CI): the checks of `identity` except the signer, the core tests on this
#             Mac's Swift, and build/HeadsUp.dmg, an unsigned image holding the ad-hoc app.
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

[ $# -eq 4 ] || die "usage: tools/make-app.sh <adhoc|adhoc-release|identity|quick> <bundle id> <version> <build number>"
mode=$1 bundle_id=$2 version=$3 build_number=$4

# A public release fixes the bundle id for good: tokens saved under one id aren't found under
# another. So it never ships with the justfile's placeholder (Nick). Checked first, on any OS.
if [ "$mode" = adhoc-release ] && [ "$bundle_id" = dev.headsup.app ]; then
    die "bundle_id is still the placeholder dev.headsup.app. Set the real one in the justfile before a public release: tokens saved under one id aren't found under another."
fi

[ "$(uname -s)" = Darwin ] || die "building HeadsUp.app needs macOS, with the Command Line Tools (Xcode isn't needed)."
# Apple silicon only: the macOS 27 Command Line Tools ship Swift's support libraries for arm64
# only, so an Intel slice can't link.
[ "$(uname -m)" = arm64 ] || die "HeadsUp builds on Apple silicon (arm64) only; Intel isn't supported by the macOS 27 Command Line Tools. This Mac is $(uname -m)."
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
adhoc | adhoc-release | quick) sign_id=- ;;
identity)
    sign_id=${HEADSUP_SIGN_ID:-}
    # One whole identity, checked before the build, so a typo doesn't cost a full build first.
    # Its message goes through die, so it starts with "make-app:" like every other stop.
    identity_problem=$("$(dirname "${BASH_SOURCE[0]}")/check-sign-identity.sh" "$sign_id" 2>&1) ||
        die "$identity_problem"
    ;;
*) die "mode must be adhoc, adhoc-release, identity or quick, not '$mode'" ;;
esac

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

swift_version=$(swift --version 2>&1 || true)
echo "make-app: ${swift_version%%$'\n'*}"

# What to clean up, whatever happens, even a failure halfway: the background jobs (and what they
# started), the opened image, and the temporary folders (Scan I21).
logs=$(mktemp -d)
check=$(mktemp -d)
mount=""
job_pids=()
job_names=()
cleanup() {
    # ${a[@]+"${a[@]}"} keeps an empty array from tripping set -u in the bash 3.2 macOS ships.
    for pid in ${job_pids[@]+"${job_pids[@]}"}; do
        kill -- "-$pid" 2>/dev/null || true
    done
    if [ -n "$mount" ]; then
        hdiutil detach -force "$mount" >/dev/null 2>&1 || true
        rmdir "$mount" 2>/dev/null || true
    fi
    rm -rf "$check" "$logs"
}
trap cleanup EXIT

# Starts the job "$1" (an architecture, or "tests") in the background, running the rest of the
# arguments. It is its own process group, so cleanup stops it with everything it started. Its
# output shows as it comes, each line marked "[arm64] " or "[tests] ", and is kept in $logs/<name>.log.
start_job() {
    local name=$1
    shift
    set -m
    ("$@" 2>&1 | tee "$logs/$name.log" | awk -v mark="[$name] " '{ print mark $0; fflush() }') &
    set +m
    job_pids+=("$!")
    job_names+=("$name")
}

# Waits for every job started; the names of those that failed go in failed_jobs.
wait_jobs() {
    local i
    failed_jobs=()
    for i in "${!job_pids[@]}"; do
        wait "${job_pids[$i]}" || failed_jobs+=("${job_names[$i]}")
    done
    job_pids=()
    job_names=()
}

# The build, and in the release modes the core tests, run at the same time, each in its own build
# folder (two SwiftPM runs can't share one). The app is arm64 only (see the check at the top);
# the list of architectures has that one entry.
# Only the versions in Package.resolved, and no resolution at build time (F15).
resolved=(--only-use-versions-from-resolved-file --disable-automatic-resolution)
architectures=(arm64)
if [ "$mode" = quick ]; then
    build_args=(-c debug -Xswiftc -DHEADSUP_QUICK_TIMERS)
else
    build_args=(-c release)
fi
# The macro plugins (SwiftUI's @State) and --triple for the architecture that isn't this Mac's:
# see tools/swift-build-args.sh.
sdk=$(xcrun --show-sdk-path) || die "can't find the macOS SDK (xcrun --show-sdk-path). Install the Command Line Tools."
swiftc=$(xcrun -f swiftc) || die "can't find swiftc (xcrun -f swiftc). Install the Command Line Tools."
host_arch=$(uname -m)
set_args() { # the build arguments for architecture $1, into args: its own scratch path
    args=("${build_args[@]}" --build-system native --scratch-path ".build/make-app-$1" "${resolved[@]}")
    local arg
    while IFS= read -r arg; do
        args+=("$arg")
    done < <(tools/swift-build-args.sh "$1" "$host_arch" "$sdk" "$swiftc")
}
echo "make-app: building for ${architectures[*]}"
for arch in "${architectures[@]}"; do
    set_args "$arch"
    start_job "$arch" tools/swift.sh build "${args[@]}"
done
# The release is built by this Mac's Swift, so the core's tests run on it too, alongside the
# builds. Nothing is signed or packaged unless they pass.
if [ "$mode" = identity ] || [ "$mode" = adhoc-release ]; then
    echo "make-app: running the core tests on this Mac's Swift, while it builds"
    start_job tests tools/swift.sh test --scratch-path .build/make-app-tests "${resolved[@]}"
fi
wait_jobs
for failed in ${failed_jobs[@]+"${failed_jobs[@]}"}; do
    if [ "$failed" = tests ]; then
        die "the core tests failed on this Mac's Swift, so no release was built (their output is above, marked [tests])"
    fi
done
for failed in ${failed_jobs[@]+"${failed_jobs[@]}"}; do
    die "the $failed build failed (its output is above, marked [$failed])"
done

binaries=()
for arch in "${architectures[@]}"; do
    set_args "$arch"
    binaries+=("$(tools/swift.sh build "${args[@]}" --show-bin-path)/HeadsUp")
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
cp "${binaries[0]}" "$app/Contents/MacOS/HeadsUp"
# Exactly arm64: an x86_64 (or any other) slice means something built what we don't ship.
archs=$(lipo -archs "$app/Contents/MacOS/HeadsUp")
[ "$archs" = arm64 ] || die "the app's binary must be arm64 only, but it has: $archs"
echo "make-app: $(lipo -info "$app/Contents/MacOS/HeadsUp")"
# The app icon (CFBundleIconFile), the menu bar glyph, and the fixed AppleScript files Commands
# compiles (F14): the shell loads them from the bundle.
for resource in AppIcon.icns MenuBarGlyph.pdf Terminal.applescript iTerm.applescript; do
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
    # codesign's output is read whole first, then matched. Piping it into `grep -q` breaks under
    # pipefail: grep stops at its first match, codesign gets SIGPIPE writing the rest, and the
    # pipeline fails even though the line was there.
    info=$(codesign -dv --arch "$arch" "$app" 2>&1) || die "couldn't read the $arch slice's signature"
    grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$info" ||
        die "the $arch slice is signed without the hardened runtime"
    echo "make-app: $arch: signed entitlements $(cat "$check/signed-$arch.json"), hardened runtime on"
done
echo "make-app: built $app ($bundle_id $version, build $build_number)"

if [ "$mode" = identity ]; then
    # The identity really signed it: an ad-hoc signature here means the wrong recipe ran. Read
    # whole, then matched, as above: a pipe into grep could let an ad-hoc signature through.
    info=$(codesign -dv "$app" 2>&1) || die "couldn't read the app's signature"
    if grep -q '^Signature=adhoc' <<<"$info"; then
        die "the app is signed ad-hoc, not with HEADSUP_SIGN_ID"
    fi
    authority=$(grep -m1 '^Authority=' <<<"$info" || true)
    echo "make-app: signed by ${authority:-$sign_id}"
fi

if [ "$mode" = identity ] || [ "$mode" = adhoc-release ]; then
    dmg=build/HeadsUp.dmg
    rm -f "$dmg"
    hdiutil create -volname HeadsUp -srcfolder "$app" -ov -format UDZO "$dmg" >/dev/null
    # Only an identity signs the image: an ad-hoc signature on it would prove nothing.
    if [ "$mode" = identity ]; then
        codesign --force --timestamp=none -s "$sign_id" "$dmg"
    fi
    # The image's checksums, its signature, and the app inside it, as the user will open it.
    hdiutil verify "$dmg" >/dev/null 2>&1 || die "$dmg doesn't verify (hdiutil verify)"
    if [ "$mode" = identity ]; then
        codesign --verify --strict "$dmg" || die "$dmg's signature doesn't verify"
    fi
    mount=$(mktemp -d)
    hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null || die "can't open $dmg"
    codesign --verify --strict --deep "$mount/$name.app" || die "the app inside $dmg doesn't verify"
    if [ "$mode" = identity ]; then
        echo "make-app: built $dmg (signed, verified, and the app inside it verifies)"
    else
        echo "make-app: built $dmg (unsigned image, verified; the ad-hoc app inside it verifies)"
    fi
fi
