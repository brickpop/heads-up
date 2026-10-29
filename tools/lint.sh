#!/usr/bin/env bash
# The project's policy checks (ADR-001 §2.2, §7, §10). `just lint` runs this, then swift format.
#
#   1. The core and its tests import no Apple-only module, so they build on Linux.
#   2. The entitlements are exactly the two the app needs (F8).
#   3. Info.plist holds only known keys: no URL schemes, document types or scripting (F19),
#      no App Transport Security exceptions besides local networking (F9), and no privacy
#      usage string besides the four the app asks for.
#   4. The debug quick timers appear only behind `#if DEBUG && HEADSUP_QUICK_TIMERS`.
#   5. The fixed AppleScript files Commands runs are there, each with the one handler
#      `run_in_terminal(theDir, theCommand)` and its own app as the only one it names, and each
#      matches its SHA-256 below, so any change fails until a reviewed diff updates the hash (F14).
#   6. HeadsUpApp uses no @State: it is a macro the Command Line Tools can't expand.
#
# The plists are read with grep, so they must stay simple: every key written as
# <key>Name</key> on one line, with no CDATA. Anything else fails, rather than risk a
# key a plist parser would see and grep wouldn't.
#
# Usage: tools/lint.sh [repo root]   (the root defaults to this script's repo; the tests pass another)
set -euo pipefail

root=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
failures=0
fail() {
    echo "lint: $*" >&2
    failures=$((failures + 1))
}

# 1. Apple-only modules in the core. Matches attributed and scoped imports too, such as
# `@preconcurrency import AppKit` and `import struct SwiftUI.Color`. Darwin is allowed:
# the core imports it, behind `#if canImport(Darwin)`, for the POSIX calls Glibc has on Linux.
# CoreGraphics is allowed the same way, behind `#if canImport(CoreGraphics)`: on Apple's
# platforms it gives CGRect its geometry, which newer Foundation no longer re-exports, and
# Linux's Foundation has its own CGRect. An unguarded import fails the Linux build anyway.
apple_only='AppKit|Cocoa|Carbon|SwiftUI|IOKit|EventKit|Security|UserNotifications|ServiceManagement'
apple_only+='|os|Combine|CryptoKit|ImageIO|UniformTypeIdentifiers|Network|ObjectiveC'
import_pattern="^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((struct|class|enum|protocol|typealias|func|let|var)[[:space:]]+)?($apple_only)([[:space:].]|\$)"
for dir in Sources/HeadsUpCore Tests/HeadsUpCoreTests; do
    [ -d "$root/$dir" ] || continue
    while IFS= read -r hit; do
        fail "${hit#"$root"/}: the core must build on Linux, so it can't import a module only Apple's platforms have. Put this behind a port in HeadsUpApp."
    done < <(grep -rnE --include='*.swift' "$import_pattern" "$root/$dir" || true)
done

# Checks that a plist is simple enough to read with grep (see the top of this file).
# Returns 1, after saying why, if it isn't.
plist_is_simple() {
    local file=$1 name=${1#"$root"/} simple=0
    if grep -q 'CDATA' "$file"; then
        fail "$name: CDATA isn't allowed in our plists"
        simple=1
    fi
    local tags plain
    tags=$(grep -o '<key' "$file" | wc -l)
    plain=$(grep -oE '<key>[A-Za-z0-9._-]+</key>' "$file" | wc -l)
    if [ "$tags" -ne "$plain" ]; then
        fail "$name: write every key as <key>Name</key> on one line, with letters, digits, dots, dashes and underscores only"
        simple=1
    fi
    return "$simple"
}

# 4. The debug quick timers (`just app-quick`) may appear in the sources only as the exact
# condition `#if DEBUG && HEADSUP_QUICK_TIMERS`, so a release build can never contain them.
while IFS= read -r hit; do
    line=$(printf '%s\n' "${hit#*:*:}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ "$line" = "#if DEBUG && HEADSUP_QUICK_TIMERS" ] ||
        fail "${hit%%:*}: HEADSUP_QUICK_TIMERS may only appear as '#if DEBUG && HEADSUP_QUICK_TIMERS'"
done < <(grep -rn --include='*.swift' HEADSUP_QUICK_TIMERS "$root/Sources" 2>/dev/null || true)

# Prints the key names of a simple plist, one per line, sorted.
plist_keys() {
    grep -oE '<key>[A-Za-z0-9._-]+</key>' "$1" | sed -E 's|</?key>||g' | sort -u
}

# 2. Entitlements: exactly these keys. Anything else, get-task-allow and
# disable-library-validation included, fails. make-app.sh checks the signed app again.
entitlements=$root/Resources/HeadsUp.entitlements
allowed_entitlements=$(printf '%s\n' \
    com.apple.security.automation.apple-events \
    com.apple.security.personal-information.calendars | sort)
if [ ! -f "$entitlements" ]; then
    fail "Resources/HeadsUp.entitlements is missing"
elif plist_is_simple "$entitlements"; then
    actual=$(plist_keys "$entitlements")
    if [ "$actual" != "$allowed_entitlements" ]; then
        fail "Resources/HeadsUp.entitlements must hold exactly these keys:"$'\n'"$allowed_entitlements"$'\n'"It holds:"$'\n'"$actual"
    fi
    # Each value is exactly <true/>: a key set to false, a string or an array fails (F8).
    not_true=$(awk '
        /<key>/ { key = $0; gsub(/.*<key>|<\/key>.*/, "", key); waiting = 1; next }
        waiting && NF { if ($0 !~ /^[[:space:]]*<true\/>[[:space:]]*$/) print key; waiting = 0 }
    ' "$entitlements")
    [ -z "$not_true" ] || fail "Resources/HeadsUp.entitlements: every value must be <true/>; these aren't: $not_true"
fi

# 3. Info.plist: only the keys below. A new key goes in this list after a review.
# Inside NSAppTransportSecurity, only NSAllowsLocalNetworking (F9).
info_allowed='CFBundleIdentifier CFBundleName CFBundleDisplayName CFBundleExecutable CFBundleIconFile
CFBundlePackageType CFBundleInfoDictionaryVersion CFBundleShortVersionString CFBundleVersion
LSMinimumSystemVersion LSUIElement NSPrincipalClass NSHumanReadableCopyright
NSAppTransportSecurity NSAllowsLocalNetworking'
# The four privacy usage strings the app carries (§7, R3): all of them, and no other.
usage_allowed='NSCalendarsFullAccessUsageDescription NSRemindersFullAccessUsageDescription
NSAppleEventsUsageDescription NSLocalNetworkUsageDescription'
inbound_keys='CFBundleURLTypes CFBundleDocumentTypes UTExportedTypeDeclarations UTImportedTypeDeclarations
NSAppleScriptEnabled OSAScriptingDefinition NSServices NSUserActivityTypes'
ats_exceptions='NSAllowsArbitraryLoads NSAllowsArbitraryLoadsForMedia NSAllowsArbitraryLoadsInWebContent
NSExceptionDomains'

info_plist=$root/Resources/Info.plist
if [ ! -f "$info_plist" ]; then
    fail "Resources/Info.plist is missing"
elif plist_is_simple "$info_plist"; then
    keys=$(plist_keys "$info_plist")
    for key in $keys; do
        if grep -qwF "$key" <<<"$inbound_keys"; then
            fail "Resources/Info.plist has $key, which opens HeadsUp to other apps (F19)"
        elif grep -qwF "$key" <<<"$ats_exceptions"; then
            fail "Resources/Info.plist has $key: App Transport Security allows only NSAllowsLocalNetworking (F9)"
        elif [[ "$key" == NS*UsageDescription ]]; then
            grep -qwF "$key" <<<"$usage_allowed" ||
                fail "Resources/Info.plist has $key: the only usage strings allowed are"$'\n'"$usage_allowed"
        elif ! grep -qwF "$key" <<<"$info_allowed"; then
            fail "Resources/Info.plist has $key, which isn't on the lint's list of allowed keys. Add it to tools/lint.sh after a review."
        fi
    done
    # All four must be there (R3): without one, macOS refuses that permission without asking.
    for key in $usage_allowed; do
        grep -qxF "$key" <<<"$keys" ||
            fail "Resources/Info.plist is missing $key: the app asks for that permission (§7, R3)"
    done
fi

# 5. The terminal scripts (F14). A change to a script must change its hash here too.
sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d" " -f1; else shasum -a 256 "$1" | cut -d" " -f1; fi
}
for script in \
    "Terminal.applescript com.apple.Terminal 2a6425952799aea5c962538e4803d802d76186b8088effd14a4248e6fff68ec1" \
    "iTerm.applescript com.googlecode.iterm2 b7a4abe155ee58f61a31169ff2b081bba8dd812a9ad57f21a6a38dd691485519"; do
    read -r name app hash <<<"$script"
    file=$root/Resources/$name
    if [ ! -f "$file" ]; then
        fail "Resources/$name is missing"
        continue
    fi
    if [ "$(grep -c '^on run_in_terminal(theDir, theCommand)$' "$file")" -ne 1 ] ||
        [ "$(grep -c '^on ' "$file")" -ne 1 ]; then
        fail "Resources/$name must have exactly one handler: on run_in_terminal(theDir, theCommand)"
    fi
    if [ "$(grep -c 'tell application' "$file")" -ne 1 ] || ! grep -q "tell application id \"$app\"" "$file"; then
        fail "Resources/$name must name only its own app: tell application id \"$app\""
    fi
    if [ "$(sha256 "$file")" != "$hash" ]; then
        fail "Resources/$name changed: its SHA-256 isn't the one tools/lint.sh pins. Review the change, then update the hash."
    fi
done

# 6. No @State in the app. In the new macOS SDK it is a macro, and the Command Line Tools
# don't ship SwiftUI's macro plugin, so it can't compile without Xcode. Comment lines are fine.
while IFS= read -r hit; do
    where=$(printf "%s" "${hit#"$root"/}" | cut -d: -f1,2)
    fail "$where: the Command Line Tools have no SwiftUI macro plugin: use State(initialValue:) (see CoreNames.swift)"
done < <(grep -rnE --include='*.swift' '@State([^A-Za-z0-9_]|$)' "$root/Sources/HeadsUpApp" 2>/dev/null |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)

if [ "$failures" -gt 0 ]; then
    echo "lint: $failures problem(s)" >&2
    exit 1
fi
echo "lint: policy checks passed"
