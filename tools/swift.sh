#!/usr/bin/env bash
# Runs swift with the right toolchain: on macOS the one the Command Line Tools (or Xcode)
# installed, after checking it is the pinned series; on Linux the one `just setup-swift` installed,
# compiling and linking against its sysroot.
#
# Usage: tools/swift.sh <swift arguments>, e.g. tools/swift.sh test
set -euo pipefail

if [ "$(uname -s)" != Linux ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    "$root/tools/check-swift-version.sh" "$(swift --version 2>&1)" "$root/.swift-version"
    # swift format ships with the Swift toolchain; if this one lacks it, a separate swift-format
    # (Homebrew) takes the same arguments.
    if [ "${1:-}" = format ] && ! swift format --version >/dev/null 2>&1; then
        if command -v swift-format >/dev/null; then
            shift
            exec swift-format "$@"
        fi
        echo "swift format isn't in this Swift toolchain. Install it with: brew install swift-format" >&2
        exit 1
    fi
    exec swift "$@"
fi

env_sh=${HEADSUP_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/headsup}/swift/env.sh
if [ ! -f "$env_sh" ]; then
    echo "Swift isn't set up on this machine. Run: just setup-swift" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$env_sh"

case "${1:-}" in
build | test | run)
    command=$1
    shift
    # The default build system can't use a user-space sysroot yet, so the native one it is.
    exec swift "$command" --build-system native \
        -Xcc "--sysroot=$SDKROOT" \
        -Xswiftc -sdk -Xswiftc "$SDKROOT" \
        -Xlinker "-L$SDKROOT/usr/lib/aarch64-linux-gnu" \
        "$@"
    ;;
*) exec swift "$@" ;;
esac
