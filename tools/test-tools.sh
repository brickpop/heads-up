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
add_to_plist HeadsUp.entitlements '    <key>com.apple.security.get-task-allow</key>
    <true/>'
expect_lint_fails "the lint fails on an extra entitlement" 'must hold exactly these keys'

lint_root
add_to_plist Info.plist '    <key>CFBundleURLTypes</key>
    <array/>'
expect_lint_fails "the lint fails on a URL scheme in Info.plist" 'has CFBundleURLTypes'

lint_root
add_to_plist Info.plist '    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>To reach models on this Mac.</string>'
expect_lint_passes "the lint allows local networking and one of the four usage strings"

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
