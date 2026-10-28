#!/usr/bin/env bash
# Tests for tools/setup-swift.sh and tools/lint.sh. `just test` runs them, on Linux and macOS.
#
# setup-swift runs against a lock of local fixtures (a fake toolchain, a fake .deb,
# file:// URLs), so the tests are quick and need no network. It is for Linux only, so
# its tests run only there. The lint runs against a copy of this repo's Resources/
# with one file changed per test.
#
# Written for the bash 3.2 and BSD tools macOS ships, as well as GNU.
set -euo pipefail

tools=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$tools")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
pass() {
    passed=$((passed + 1))
    echo "  ok    $1"
}
fail() {
    failed=$((failed + 1))
    echo "  FAIL  $1: $2"
}

# --- setup-swift (Linux) ---------------------------------------------------------

setup_swift_tests() {
    echo "setup-swift"
    sha() { sha256sum "$1" | cut -d' ' -f1; }

    local files=$work/files
    mkdir -p "$files" "$work/src/fake-swift/usr/bin" "$work/src/fake-swift/usr/lib/swift/linux" \
        "$work/src/fake-swift/usr/lib/swift_static" "$work/src/deb/DEBIAN" "$work/src/deb/usr/lib/aarch64-linux-gnu"
    echo 'echo fake lld' >"$work/src/fake-swift/usr/bin/ld.lld"
    tar -czf "$files/toolchain.tar.gz" -C "$work/src" fake-swift
    printf 'Package: fake\nVersion: 1\nArchitecture: all\nMaintainer: HeadsUp tests\nDescription: test fixture\n' \
        >"$work/src/deb/DEBIAN/control"
    echo 'not really a library' >"$work/src/deb/usr/lib/aarch64-linux-gnu/libxml2.so.2"
    dpkg-deb --root-owner-group -b "$work/src/deb" "$files/fake.deb" >/dev/null
    echo 'fake signature' >"$files/toolchain.tar.gz.sig"

    local toolchain_sha deb_sha
    toolchain_sha=$(sha "$files/toolchain.tar.gz")
    deb_sha=$(sha "$files/fake.deb")

    # Writes a lock to $1. $2 is the .deb's pinned hash, $3 "signed" to add the signature line.
    write_lock() {
        {
            echo "swift-version 0.0.0"
            echo "toolchain toolchain.tar.gz $toolchain_sha file://$files/toolchain.tar.gz"
            echo "deb fake.deb $2 file://$files/fake.deb"
            if [ "${3:-}" = signed ]; then
                echo "signature toolchain.tar.gz.sig - file://$files/toolchain.tar.gz.sig"
            fi
        } >"$1"
    }

    # Runs setup-swift with lock $1 and cache $2; output goes to $work/out, the status to $status.
    setup() {
        status=0
        HEADSUP_SWIFT_LOCK=$1 HEADSUP_CACHE=$2 "$tools/setup-swift.sh" >"$work/out" 2>&1 || status=$?
    }

    # A folder with a fake gpgv that exits with $1, to put first in PATH.
    fake_gpgv() {
        local dir=$work/gpgv-$1
        mkdir -p "$dir"
        printf '#!/bin/sh\nexit %s\n' "$1" >"$dir/gpgv"
        chmod +x "$dir/gpgv"
        echo "$dir"
    }

    local lock=$work/good.lock cache=$work/cache-good
    write_lock "$lock" "$deb_sha"
    setup "$lock" "$cache"
    if [ "$status" -eq 0 ] && [ -f "$cache/swift/stamp" ] && [ -f "$cache/swift/env.sh" ] &&
        [ -f "$(readlink -f "$cache/swift/bin/ld")" ] &&
        [ -f "$cache/swift/sysroot/usr/lib/aarch64-linux-gnu/libxml2.so.2" ] &&
        [ -d "$cache/swift/sysroot/usr/lib/swift/linux" ] &&
        grep -q 'no signature or keyring in the lock' "$work/out"; then
        pass "a first run installs the toolchain, the sysroot and env.sh"
    else
        fail "a first run installs the toolchain, the sysroot and env.sh" "status $status: $(cat "$work/out")"
    fi

    # The second run must not download or unpack anything: take the downloads away.
    local stamp_before
    stamp_before=$(stat -c %Y.%i "$cache/swift/stamp")
    rm -rf "$cache/downloads"
    setup "$lock" "$cache"
    if [ "$status" -eq 0 ] && grep -q 'Nothing to do' "$work/out" && [ ! -e "$cache/downloads" ] &&
        [ "$(stat -c %Y.%i "$cache/swift/stamp")" = "$stamp_before" ]; then
        pass "a second run does nothing"
    else
        fail "a second run does nothing" "status $status: $(cat "$work/out")"
    fi

    echo "# a changed pin" >>"$lock"
    setup "$lock" "$cache"
    if [ "$status" -eq 0 ] && grep -q 'is set up in' "$work/out"; then
        pass "a changed lock sets up again"
    else
        fail "a changed lock sets up again" "status $status: $(cat "$work/out")"
    fi

    # env.sh quotes the install path, so a folder name can't run code when it's sourced.
    cache="$work/cache '\$(touch $work/pwned)'"
    write_lock "$lock" "$deb_sha"
    setup "$lock" "$cache"
    if [ "$status" -eq 0 ] && (source "$cache/swift/env.sh" && [ "$SDKROOT" = "$cache/swift/sysroot" ]) &&
        [ ! -e "$work/pwned" ]; then
        pass "env.sh quotes the install path"
    else
        fail "env.sh quotes the install path" "status $status: $(cat "$work/out")"
    fi

    local bad_lock=$work/bad.lock
    write_lock "$bad_lock" "$(printf '0%.0s' {1..64})"
    cache=$work/cache-mismatch
    setup "$bad_lock" "$cache"
    if [ "$status" -ne 0 ] && grep -q 'SHA-256 mismatch for fake.deb' "$work/out" &&
        [ ! -e "$cache/swift" ] && [ ! -e "$cache/swift.new" ] && [ ! -e "$cache/downloads/fake.deb" ]; then
        pass "a lock hash mismatch stops setup, installs nothing and deletes the download"
    else
        fail "a lock hash mismatch stops setup, installs nothing and deletes the download" "status $status: $(cat "$work/out")"
    fi

    # A cached download that was changed after it was checked is checked again.
    cache=$work/cache-tampered
    write_lock "$lock" "$deb_sha"
    setup "$lock" "$cache"
    echo tampered >>"$cache/downloads/fake.deb"
    echo "# another pin" >>"$lock"
    setup "$lock" "$cache"
    if [ "$status" -ne 0 ] && grep -q 'SHA-256 mismatch for fake.deb' "$work/out"; then
        pass "a changed file in the download cache stops setup"
    else
        fail "a changed file in the download cache stops setup" "status $status: $(cat "$work/out")"
    fi

    local signed_lock=$work/signed.lock
    write_lock "$signed_lock" "$deb_sha" signed
    cache=$work/cache-bad-signature
    PATH="$(fake_gpgv 1):$PATH" setup "$signed_lock" "$cache"
    if [ "$status" -ne 0 ] && grep -q 'signature does not verify' "$work/out" && [ ! -e "$cache/swift" ]; then
        pass "a bad toolchain signature stops setup when gpgv exists"
    else
        fail "a bad toolchain signature stops setup when gpgv exists" "status $status: $(cat "$work/out")"
    fi

    cache=$work/cache-good-signature
    PATH="$(fake_gpgv 0):$PATH" setup "$signed_lock" "$cache"
    if [ "$status" -eq 0 ] && grep -q 'signature verified' "$work/out"; then
        pass "a good toolchain signature lets setup go on"
    else
        fail "a good toolchain signature lets setup go on" "status $status: $(cat "$work/out")"
    fi

    local http_lock=$work/http.lock
    write_lock "$http_lock" "$deb_sha"
    sed "s|file://$files/fake.deb|http://example.com/fake.deb|" "$http_lock" >"$http_lock.new"
    mv "$http_lock.new" "$http_lock"
    setup "$http_lock" "$work/cache-http"
    if [ "$status" -ne 0 ] && grep -q 'only https:// URLs' "$work/out"; then
        pass "a plain http URL in the lock is refused"
    else
        fail "a plain http URL in the lock is refused" "status $status: $(cat "$work/out")"
    fi

    # The repo's own lock (not given through HEADSUP_SWIFT_LOCK) may not read local files.
    mkdir -p "$work/copy/tools"
    cp "$tools/setup-swift.sh" "$tools/swift-keys.gpg" "$work/copy/tools/"
    write_lock "$work/copy/tools/swift-linux.lock" "$deb_sha"
    status=0
    HEADSUP_CACHE=$work/cache-file "$work/copy/tools/setup-swift.sh" >"$work/out" 2>&1 || status=$?
    if [ "$status" -ne 0 ] && grep -q 'only https:// URLs' "$work/out"; then
        pass "file:// URLs work only in a lock given through HEADSUP_SWIFT_LOCK"
    else
        fail "file:// URLs work only in a lock given through HEADSUP_SWIFT_LOCK" "status $status: $(cat "$work/out")"
    fi
}

if [ "$(uname -s)" = Linux ]; then
    setup_swift_tests
else
    echo "setup-swift: skipped (it is for Linux only)"
fi

# --- building on a Mac with only the Command Line Tools ------------------------------

echo "macOS build"

version_check() { # expected status, swift --version output
    status=0
    "$tools/check-swift-version.sh" "$2" "$work/swift-version" >"$work/out" 2>&1 || status=$?
    [ "$status" -eq "$1" ]
}
echo 6.2.4 >"$work/swift-version"
# Older than the pinned series: refused, naming both versions.
for refused in "swift-driver version: 1.120.5 Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)" \
    "Apple Swift version 5.10" "Apple Swift version 6"; do
    if version_check 1 "$refused" && grep -q "HeadsUp needs Swift 6.2 or newer; this Mac has Swift" "$work/out"; then
        pass "refuses an older Swift: $refused"
    else
        fail "refuses an older Swift: $refused" "$(cat "$work/out")"
    fi
done
# The same series: accepted, with nothing printed.
for ok in "Apple Swift version 6.2 (swiftlang-6.2.0.1)" "Apple Swift version 6.2.1" "Apple Swift version 6.2.4"; do
    if version_check 0 "$ok" && [ ! -s "$work/out" ]; then
        pass "accepts silently: $ok"
    else
        fail "accepts silently: $ok" "$(cat "$work/out")"
    fi
done
# Newer: accepted, with a one-line note (the CEO's Mac has 6.4).
ceo_6_4="swift-driver version: 1.148.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-1800.0.30.1)"
for newer in "$ceo_6_4" "Apple Swift version 6.10" "Swift version 7.0 (swift-7.0-RELEASE)"; do
    if version_check 0 "$newer" && [ "$(wc -l <"$work/out")" -eq 1 ] &&
        grep -q "newer than the 6.2 that Linux checks; building anyway" "$work/out"; then
        pass "accepts a newer Swift with a note: $newer"
    else
        fail "accepts a newer Swift with a note: $newer" "$(cat "$work/out")"
    fi
done
if "$tools/check-swift-version.sh" "Apple Swift version 6.4 (swiftlang-6.4.0.34.1)" "$repo/.swift-version" >"$work/out" 2>&1; then
    pass "the repo's .swift-version is read"
else
    fail "the repo's .swift-version is read" "$(cat "$work/out")"
fi
echo "not a version" >"$work/swift-version"
if version_check 1 "Apple Swift version 6.2.1" && grep -q "Couldn't read a Swift version" "$work/out"; then
    pass "a broken .swift-version stops the build"
else
    fail "a broken .swift-version stops the build" "$(cat "$work/out")"
fi
if version_check 1 "something else" && grep -q "Command Line Tools" "$work/out"; then
    pass "an unknown swift --version says how to install the tools"
else
    fail "an unknown swift --version says how to install the tools" "$(cat "$work/out")"
fi
# make-app builds each architecture alone and joins them; nothing needs Xcode's xcbuild.
make_app_code=$(grep -v '^[[:space:]]*#' "$tools/make-app.sh")
if grep -qE -- '--arch [a-z0-9_]+ --arch' <<<"$make_app_code" || grep -qi xcbuild <<<"$make_app_code"; then
    fail "make-app.sh doesn't need xcbuild" "it builds two architectures at once"
else
    pass "make-app.sh doesn't need xcbuild"
fi

# --- the signing identity (Scan L1) -----------------------------------------------------

echo "signing identity"

# A fake `security` that lists one identity the way macOS prints it.
mkdir -p "$work/fake-security"
cat >"$work/fake-security/security" <<'FAKE'
#!/usr/bin/env bash
cat <<'LIST'
  1) 3E8A1B2C3D4E5F60718293A4B5C6D7E8F9012345 "Apple Development: Sam Lee (ABCDE12345)"
     1 valid identities found
LIST
FAKE
chmod 755 "$work/fake-security/security"
identity_check() { # expected status, identity
    status=0
    PATH="$work/fake-security:$PATH" "$tools/check-sign-identity.sh" "$2" >"$work/out" 2>&1 || status=$?
    [ "$status" -eq "$1" ]
}
for ok in "3E8A1B2C3D4E5F60718293A4B5C6D7E8F9012345" "3e8a1b2c3d4e5f60718293a4b5c6d7e8f9012345" \
    "Apple Development: Sam Lee (ABCDE12345)"; do
    if identity_check 0 "$ok"; then pass "the identity check accepts: $ok"; else fail "accepts: $ok" "$(cat "$work/out")"; fi
done
for refused in "valid" "-" "2" "1" "Apple Development" "Sam Lee" "3E8A1B2C" ""; do
    if identity_check 1 "$refused"; then
        pass "the identity check refuses: '$refused'"
    else
        fail "the identity check refuses: '$refused'" "status $status: $(cat "$work/out")"
    fi
done
# make-app stops before building, with a line starting "make-app:" as RELEASE.md says (Rev).
printf '#!/usr/bin/env bash\necho Darwin\n' >"$work/fake-security/uname"
chmod 755 "$work/fake-security/uname"
status=0
HEADSUP_SIGN_ID="Sam Lee" PATH="$work/fake-security:$PATH" \
    "$tools/make-app.sh" identity dev.headsup.app 0.1.0 1 >"$work/out" 2>&1 || status=$?
if [ "$status" -ne 0 ] && grep -q "^make-app: no valid code-signing identity is exactly" "$work/out"; then
    pass "make-app stops on a partial identity with a make-app: line"
else
    fail "make-app stops on a partial identity with a make-app: line" "status $status: $(cat "$work/out")"
fi
rm -f "$work/fake-security/uname"
if identity_check 1 "-" && grep -q "signs ad-hoc" "$work/out"; then
    pass "'-' is refused as ad-hoc, with why"
else
    fail "'-' is refused as ad-hoc, with why" "$(cat "$work/out")"
fi

# --- make-app's parallel builds (on fakes) -------------------------------------------------

echo "parallel builds"

# Fakes for a Mac: uname says Darwin on arm64; security has one valid identity; swift records
# when each job starts and ends in $events. FAIL_ARCH makes that architecture's build fail,
# FAIL_TESTS the tests, and SLEEP sets how long each job takes.
fakes=$work/fake-mac
events=$work/events
mkdir -p "$fakes"
cat >"$fakes/uname" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = -m ]; then echo arm64; else echo Darwin; fi
FAKE
cat >"$fakes/security" <<'FAKE'
#!/usr/bin/env bash
echo '  1) 3E8A1B2C3D4E5F60718293A4B5C6D7E8F9012345 "Apple Development: Sam Lee (ABCDE12345)"'
FAKE
# The SDK and swiftc make-app.sh asks for; their plugin folders don't exist, so none are added.
cat >"$fakes/xcrun" <<'FAKE'
#!/usr/bin/env bash
case "$*" in --show-sdk-path) echo /nonexistent/MacOSX.sdk ;; *) echo /nonexistent/usr/bin/swiftc ;; esac
FAKE
cat >"$fakes/swift" <<'FAKE'
#!/usr/bin/env bash
case "$*" in *--version*) echo "Apple Swift version 6.4.1"; exit 0 ;; esac
job=tests
[[ "$*" =~ --scratch-path\ \.build/make-app-([a-z0-9_]+) ]] && job=${BASH_REMATCH[1]}
echo "start $job" >>"$EVENTS"
[ -n "${PIDS:-}" ] && echo "$$" >>"$PIDS"
echo "compiling for $job"
sleep "${SLEEP:-1}"
echo "end $job" >>"$EVENTS"
if [ "$job" = "${FAIL_ARCH:-}" ] || { [ "$job" = tests ] && [ -n "${FAIL_TESTS:-}" ]; }; then
    echo "error: something broke in $job"
    exit 1
fi
FAKE
chmod 755 "$fakes"/*
make_app() { # mode; the environment carries FAIL_ARCH, FAIL_TESTS, SLEEP
    rm -f "$events"
    status=0
    EVENTS=$events HEADSUP_SIGN_ID="Apple Development: Sam Lee (ABCDE12345)" PATH="$fakes:$PATH" \
        "$tools/make-app.sh" "$1" dev.headsup.app 0.1.0 1 >"$work/out" 2>&1 || status=$?
}

FAIL_ARCH=x86_64 make_app adhoc
if [ "$status" -ne 0 ] && grep -q "^make-app: the x86_64 build failed" "$work/out" &&
    grep -q "^\[x86_64\] error: something broke in x86_64" "$work/out" && grep -q "^\[arm64\] compiling" "$work/out"; then
    pass "a failing x86_64 build stops make-app, named, with its marked output"
else
    fail "a failing x86_64 build stops make-app, named, with its marked output" "status $status: $(cat "$work/out")"
fi

# The two builds and the tests run at the same time: all three start before any ends.
FAIL_TESTS=1 make_app identity
starts_before_first_end=$(awk '/^end/ { exit } /^start/ { n++ } END { print n + 0 }' "$events")
if [ "$status" -ne 0 ] && [ "$starts_before_first_end" -eq 3 ] &&
    grep -q "^make-app: the core tests failed on this Mac's Swift, so no release was built" "$work/out"; then
    pass "just build runs both builds and the tests at once, and failing tests stop it"
else
    fail "just build runs both builds and the tests at once, and failing tests stop it" \
        "status $status, starts before the first end: $starts_before_first_end: $(cat "$work/out") $(cat "$events")"
fi

FAIL_ARCH=arm64 make_app quick
if [ "$status" -ne 0 ] && grep -q "^make-app: the arm64 build failed" "$work/out" &&
    [ "$(grep -c '^start' "$events")" -eq 1 ]; then
    pass "just app-quick builds one architecture, this Mac's"
else
    fail "just app-quick builds one architecture, this Mac's" "status $status: $(cat "$work/out") $(cat "$events")"
fi

# Killed while building: the EXIT trap stops the builds too. Each fake build writes its pid.
rm -f "$events" "$work/pids"
EVENTS=$events PIDS=$work/pids SLEEP=20 PATH="$fakes:$PATH" \
    "$tools/make-app.sh" adhoc dev.headsup.app 0.1.0 1 >"$work/out" 2>&1 &
make_app_pid=$!
for _ in $(seq 100); do
    [ "$(wc -l <"$work/pids" 2>/dev/null || echo 0)" -ge 2 ] && break
    sleep 0.1
done
kill -TERM "$make_app_pid"
wait "$make_app_pid" 2>/dev/null || true
sleep 0.5
still=0
# A stopped process whose parent is gone can stay a zombie where PID 1 doesn't reap (a container):
# it counts as stopped.
while read -r pid; do
    case "$(ps -o stat= -p "$pid" 2>/dev/null)" in "" | Z*) ;; *) still=$((still + 1)) ;; esac
done <"$work/pids"
if [ "$(wc -l <"$work/pids")" -eq 2 ] && [ "$still" -eq 0 ]; then
    pass "killing make-app stops its builds"
else
    while read -r pid; do kill "$pid" 2>/dev/null || true; done <"$work/pids"
    fail "killing make-app stops its builds" "$still of $(wc -l <"$work/pids") fake builds still running"
fi

# --- the macOS build arguments (SwiftUI's macro plugins) ----------------------------------

echo "macOS build arguments"

# A fake SDK and toolchain with the plugin folders where macOS keeps them.
sdk=$work/sdk/MacOSX.sdk
toolchain=$work/toolchain/usr
mkdir -p "$sdk/usr/lib/swift/host/plugins" "$toolchain/lib/swift/host/plugins" "$toolchain/bin"
touch "$toolchain/bin/swiftc" "$toolchain/bin/swift-plugin-server"
chmod 755 "$toolchain/bin/swift-plugin-server"
build_args() { "$tools/swift-build-args.sh" "$@" | tr '\n' ' '; }
expected_plugins="-Xswiftc -plugin-path -Xswiftc $toolchain/lib/swift/host/plugins -Xswiftc -external-plugin-path -Xswiftc $sdk/usr/lib/swift/host/plugins#$toolchain/bin/swift-plugin-server "
check_args() { # name, expected, arguments
    local name=$1 expected=$2 actual
    shift 2
    actual=$(build_args "$@")
    if [ "$actual" = "$expected" ]; then pass "$name"; else fail "$name" "got: $actual"; fi
}
check_args "this Mac's architecture: the plugin paths, no --triple" "$expected_plugins" \
    arm64 arm64 "$sdk" "$toolchain/bin/swiftc"
check_args "the other architecture: --triple, then the plugin paths" "--triple x86_64-apple-macosx14.0 $expected_plugins" \
    x86_64 arm64 "$sdk" "$toolchain/bin/swiftc"
rm "$toolchain/bin/swift-plugin-server"
check_args "without swift-plugin-server, the SDK's plugins load in process" \
    "-Xswiftc -plugin-path -Xswiftc $toolchain/lib/swift/host/plugins -Xswiftc -plugin-path -Xswiftc $sdk/usr/lib/swift/host/plugins " \
    arm64 arm64 "$sdk" "$toolchain/bin/swiftc"
rmdir "$sdk/usr/lib/swift/host/plugins" "$toolchain/lib/swift/host/plugins"
check_args "a missing plugin folder adds nothing" "--triple x86_64-apple-macosx14.0 " \
    x86_64 arm64 "$sdk" "$toolchain/bin/swiftc"
if ! "$tools/swift-build-args.sh" arm64 >/dev/null 2>&1; then
    pass "swift-build-args.sh refuses missing arguments"
else
    fail "swift-build-args.sh refuses missing arguments" "it accepted one argument"
fi

# --- lint (Linux and macOS) ----------------------------------------------------------

echo "lint"

# Makes a fresh copy of the repo's Resources/ and an empty core in $work/lint-root.
lint_root() {
    rm -rf "$work/lint-root"
    mkdir -p "$work/lint-root/Sources/HeadsUpCore" "$work/lint-root/Tests/HeadsUpCoreTests"
    cp -R "$repo/Resources" "$work/lint-root/Resources"
    echo 'import Foundation' >"$work/lint-root/Sources/HeadsUpCore/Fine.swift"
}
# Adds the lines $2 at the end of the top-level <dict> of plist $1 in the lint root.
add_to_plist() {
    local file=$work/lint-root/Resources/$1
    awk -v add="$2" '/^<\/dict>/ && !done { print add; done = 1 } { print }' "$file" >"$file.new"
    mv "$file.new" "$file"
}
# Removes key $2 and the line after it (its value) from plist $1 in the lint root.
remove_from_plist() {
    local file=$work/lint-root/Resources/$1
    awk -v key="<key>$2</key>" 'skip { skip = 0; next } index($0, key) { skip = 1; next } { print }' \
        "$file" >"$file.new"
    mv "$file.new" "$file"
}
lint() {
    status=0
    "$tools/lint.sh" "$work/lint-root" >"$work/out" 2>&1 || status=$?
}
expect_lint_fails() { # name, text the output must contain
    lint
    if [ "$status" -ne 0 ] && grep -q "$2" "$work/out"; then
        pass "$1"
    else
        fail "$1" "status $status: $(cat "$work/out")"
    fi
}
expect_lint_passes() { # name
    lint
    if [ "$status" -eq 0 ]; then
        pass "$1"
    else
        fail "$1" "$(cat "$work/out")"
    fi
}

status=0
"$tools/lint.sh" "$repo" >"$work/out" 2>&1 || status=$?
if [ "$status" -eq 0 ]; then pass "this repo passes the lint"; else fail "this repo passes the lint" "$(cat "$work/out")"; fi

lint_root
echo 'import AppKit' >"$work/lint-root/Sources/HeadsUpCore/Panel.swift"
expect_lint_fails "the lint fails on an Apple import in the core" 'Sources/HeadsUpCore/Panel.swift:1'

lint_root
printf 'import Foundation\n@preconcurrency import SwiftUI\n' >"$work/lint-root/Sources/HeadsUpCore/View.swift"
expect_lint_fails "the lint fails on an attributed Apple import in the core" 'View.swift:2'

lint_root
echo '    import struct Security.SecKey' >"$work/lint-root/Tests/HeadsUpCoreTests/KeyTests.swift"
expect_lint_fails "the lint fails on a scoped Apple import in the core tests" 'KeyTests.swift:1'

lint_root
echo 'import os' >"$work/lint-root/Sources/HeadsUpCore/Log.swift"
expect_lint_fails "the lint fails on os, which Linux doesn't have" 'Log.swift:1'

lint_root
printf '#if canImport(Darwin)\n    import Darwin\n#endif\n' >"$work/lint-root/Sources/HeadsUpCore/POSIX.swift"
expect_lint_passes "the lint allows Darwin behind canImport, for POSIX calls"

lint_root
printf '#if canImport(CoreGraphics)\n    import CoreGraphics\n#endif\n' >"$work/lint-root/Sources/HeadsUpCore/Geometry.swift"
expect_lint_passes "the lint allows CoreGraphics behind canImport, for CGRect's geometry"

lint_root
add_to_plist HeadsUp.entitlements '    <key>com.apple.security.get-task-allow</key>
    <true/>'
expect_lint_fails "the lint fails on an extra entitlement" 'must hold exactly these keys'

# F8: any third key fails, whatever it is.
for key in com.apple.security.device.camera com.apple.security.cs.allow-jit keychain-access-groups \
    com.apple.security.cs.disable-library-validation com.apple.security.personal-information.location; do
    lint_root
    add_to_plist HeadsUp.entitlements "    <key>$key</key>
    <true/>"
    expect_lint_fails "the lint fails on the entitlement $key (F8)" 'must hold exactly these keys'
done

# F8: the two allowed keys must be true.
lint_root
sed -i.bak '/automation.apple-events/{n;s|<true/>|<false/>|;}' "$work/lint-root/Resources/HeadsUp.entitlements"
expect_lint_fails "the lint fails on an allowed entitlement set to false (F8)" 'every value must be <true/>'
lint_root
sed -i.bak '/personal-information.calendars/{n;s|<true/>|<string>yes</string>|;}' \
    "$work/lint-root/Resources/HeadsUp.entitlements"
expect_lint_fails "the lint fails on an allowed entitlement set to a string (F8)" 'every value must be <true/>'
lint_root
remove_from_plist HeadsUp.entitlements com.apple.security.personal-information.calendars
expect_lint_fails "the lint fails when an allowed entitlement is missing (F8)" 'must hold exactly these keys'

lint_root
add_to_plist Info.plist '    <key>CFBundleURLTypes</key>
    <array/>'
expect_lint_fails "the lint fails on a URL scheme in Info.plist" 'has CFBundleURLTypes'

# F19: nothing that lets another app open or script HeadsUp.
for key in CFBundleDocumentTypes UTExportedTypeDeclarations NSAppleScriptEnabled OSAScriptingDefinition NSServices \
    NSUserActivityTypes; do
    lint_root
    add_to_plist Info.plist "    <key>$key</key>
    <array/>"
    expect_lint_fails "the lint fails on $key in Info.plist (F19)" "has $key"
done

for usage in NSCalendarsFullAccessUsageDescription NSRemindersFullAccessUsageDescription \
    NSAppleEventsUsageDescription NSLocalNetworkUsageDescription; do
    lint_root
    remove_from_plist Info.plist "$usage"
    expect_lint_fails "the lint fails without $usage (R3)" "is missing $usage"
done

lint_root
add_to_plist Info.plist '    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoadsInWebContent</key>
        <true/>
    </dict>'
expect_lint_fails "the lint fails on an ATS exception for web content" 'allows only NSAllowsLocalNetworking'

lint_root
add_to_plist Info.plist '    <key>NSCalendarsWriteOnlyAccessUsageDescription</key>
    <string>To add events.</string>'
expect_lint_fails "the lint fails on the write-only Calendar usage string" 'the only usage strings allowed'

lint_root
add_to_plist Info.plist '    <key>NSCameraUsageDescription</key>
    <string>To see you.</string>'
expect_lint_fails "the lint fails on any other usage string" 'NSCameraUsageDescription'

lint_root
add_to_plist Info.plist '    <key>LSEnvironment</key>
    <dict/>'
expect_lint_fails "the lint fails on a key it doesn't know" 'list of allowed keys'

lint_root
add_to_plist Info.plist '    <key>CFBundle&#85;RLTypes</key>
    <array/>'
expect_lint_fails "the lint fails on a key written with a character reference" 'write every key as'

lint_root
mkdir -p "$work/lint-root/Sources/HeadsUpApp"
printf '#if HEADSUP_QUICK_TIMERS\n    let minute = 5.0\n#endif\n' >"$work/lint-root/Sources/HeadsUpApp/Quick.swift"
expect_lint_fails "the lint fails on quick timers outside #if DEBUG" 'HEADSUP_QUICK_TIMERS may only appear'

lint_root
mkdir -p "$work/lint-root/Sources/HeadsUpApp"
printf '    #if DEBUG && HEADSUP_QUICK_TIMERS\n        let minute = 5.0\n    #endif\n' >"$work/lint-root/Sources/HeadsUpApp/Quick.swift"
expect_lint_passes "the lint allows quick timers behind #if DEBUG"

lint_root
rm "$work/lint-root/Resources/iTerm.applescript"
expect_lint_fails "the lint fails when a terminal script is missing" 'iTerm.applescript is missing'

lint_root
printf 'on run_in_terminal(theDir, theCommand)\nend run_in_terminal\non run_other(x)\nend run_other\n' \
    >"$work/lint-root/Resources/Terminal.applescript"
expect_lint_fails "the lint fails on a second handler in a terminal script" 'exactly one handler'

lint_root
printf 'tell application id "com.apple.Finder"\nend tell\n' >>"$work/lint-root/Resources/Terminal.applescript"
expect_lint_fails "the lint fails when a terminal script names another app" 'only its own app'

lint_root
printf -- '-- edited\n' >>"$work/lint-root/Resources/iTerm.applescript"
expect_lint_fails "the lint fails when a terminal script changes without its hash" 'iTerm.applescript changed'

echo
echo "scripts"
# Every script the justfile or these tests run must be executable (Rev 1, Scan L2).
for script in $(grep -ohE 'tools/[A-Za-z0-9_-]+\.sh' "$repo/justfile" "$repo/tools/test-tools.sh" | sort -u); do
    if [ -x "$repo/$script" ]; then
        pass "$script is executable"
    else
        fail "$script is executable" "chmod 755 $script"
    fi
done

echo
echo "Scan's terminal script cases"
if "$tools/test-applescript-lint.sh" | sed 's/^/  /'; then
    pass "Scan's four terminal script cases"
else
    fail "Scan's four terminal script cases" "see above"
fi

echo
echo "Scan's lint cases"
if "$tools/test-lint-hardening.sh" | sed 's/^/  /'; then
    pass "Scan's four lint hardening cases"
else
    fail "Scan's four lint hardening cases" "see above"
fi

echo
echo "tools: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
