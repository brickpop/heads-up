#!/usr/bin/env bash
# Checks that HEADSUP_SIGN_ID names one whole valid code-signing identity in the keychain: its
# 40-character SHA-1 hash, or its exact name as `security find-identity` prints it. A part of a
# name, a list number, "-" (ad-hoc) or any other word is refused (Scan L1). make-app.sh runs it
# before an identity build, so a typo doesn't cost a full build first.
#
# Usage: tools/check-sign-identity.sh "<identity>"
set -euo pipefail

identity=${1:-}
list="To list them: security find-identity -v -p codesigning"
if [ -z "$identity" ]; then
    echo "set HEADSUP_SIGN_ID to your signing identity. $list" >&2
    exit 1
fi
if [ "$identity" = - ]; then
    echo "HEADSUP_SIGN_ID is '-', which signs ad-hoc. just build needs a real identity; just app signs ad-hoc. $list" >&2
    exit 1
fi

# Each valid identity is a line like:
#   1) 3E8A…(40 hex) "Apple Development: Name (ABCDE12345)"
# The list is read whole first: awk stops at the first match, and a pipe from security under
# pipefail would then fail on SIGPIPE.
identities=$(security find-identity -v -p codesigning) || {
    echo "couldn't list the code-signing identities (security find-identity failed). $list" >&2
    exit 1
}
found=$(awk -v want="$identity" '
    match($0, /^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-Fa-f]{40}[[:space:]]+"/) {
        hash = $2
        name = substr($0, RLENGTH + 1)
        sub(/"[[:space:]]*$/, "", name)
        if (toupper(hash) == toupper(want) || name == want) { print "yes"; exit }
    }' <<<"$identities")
if [ "$found" != yes ]; then
    echo "no valid code-signing identity is exactly HEADSUP_SIGN_ID='$identity'. Use its 40-character hash or its full name in quotes. $list" >&2
    exit 1
fi
