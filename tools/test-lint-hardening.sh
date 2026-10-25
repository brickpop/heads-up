#!/usr/bin/env bash
# Scan's exploit tests for tools/lint.sh (slice 0 code gate, F8 and F19).
# Each case writes a plist the lint must reject. They fail while the lint reads
# plists with grep; they pass once it parses them as a plist parser would.
#
# Usage: tools/test-lint-hardening.sh [path to lint.sh]   (default: tools/lint.sh in this repo)
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lint=${1:-$repo/tools/lint.sh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

plist() { # $1 = the <dict> body
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n%s\n</dict>\n</plist>\n' "$1"
}
allowed='<key>com.apple.security.automation.apple-events</key><true/>
<key>com.apple.security.personal-information.calendars</key><true/>'
info='<key>CFBundleIdentifier</key><string>@BUNDLE_ID@</string>
<key>CFBundleExecutable</key><string>HeadsUp</string>
<key>LSUIElement</key><true/>'

expect_reject() { # name, entitlements body, Info.plist body
    local root=$work/root
    rm -rf "$root"
    mkdir -p "$root/Resources"
    plist "$2" >"$root/Resources/HeadsUp.entitlements"
    plist "$3" >"$root/Resources/Info.plist"
    if "$lint" "$root" >/dev/null 2>&1; then
        echo "FAIL: $1 (the lint passed)"
        failures=$((failures + 1))
    else
        echo "ok:   $1"
    fi
}

expect_reject "a forbidden entitlement in a CDATA key" \
    "$allowed
<key><![CDATA[com.apple.security.cs.disable-library-validation]]></key><true/>" "$info"
expect_reject "a forbidden entitlement with whitespace in the key tag" \
    "$allowed
<key >com.apple.security.get-task-allow</key ><true/>" "$info"
expect_reject "ATS turned off in Info.plist (F9)" \
    "$allowed" "$info
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>"
expect_reject "ATS exception domains in Info.plist (F9)" \
    "$allowed" "$info
<key>NSAppTransportSecurity</key><dict><key>NSExceptionDomains</key><dict/></dict>"

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
