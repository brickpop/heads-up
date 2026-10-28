#!/usr/bin/env bash
# Prints, one per line, the extra `swift build` arguments make-app.sh needs for one architecture
# on macOS.
#
# - The macro plugins. SwiftUI's @State is a macro whose plugin (SwiftUIMacros) ships in the
#   SDK, and some macros (Observation's) ship with the toolchain. A plain host build finds both,
#   but a build with --triple is treated as a cross-compile and gets neither, so @State fails
#   with "plugin for module 'SwiftUIMacros' not found". The flags are the ones the Swift driver
#   adds on its own for a host build: the toolchain's folder with -plugin-path, and the SDK's
#   with -external-plugin-path through swift-plugin-server. Each is added only if its folder
#   exists.
# - --triple, only for an architecture that isn't this Mac's: the host build stays a plain one.
#
# Usage: tools/swift-build-args.sh <arch> <host arch> <SDK path> <swiftc path>
#   e.g. tools/swift-build-args.sh x86_64 arm64 "$(xcrun --show-sdk-path)" "$(xcrun -f swiftc)"
set -euo pipefail

[ $# -eq 4 ] || {
    echo "usage: tools/swift-build-args.sh <arch> <host arch> <SDK path> <swiftc path>" >&2
    exit 1
}
arch=$1 host=$2 sdk=$3 swiftc=$4

if [ "$arch" != "$host" ]; then
    echo --triple
    echo "$arch-apple-macosx14.0"
fi

bin=$(dirname "$swiftc")
toolchain_plugins=$bin/../lib/swift/host/plugins
if [ -d "$toolchain_plugins" ]; then
    printf '%s\n' -Xswiftc -plugin-path -Xswiftc "$(cd "$toolchain_plugins" && pwd)"
fi

sdk_plugins=$sdk/usr/lib/swift/host/plugins
if [ -d "$sdk_plugins" ]; then
    sdk_plugins=$(cd "$sdk_plugins" && pwd)
    if [ -x "$bin/swift-plugin-server" ]; then
        printf '%s\n' -Xswiftc -external-plugin-path -Xswiftc "$sdk_plugins#$bin/swift-plugin-server"
    else
        printf '%s\n' -Xswiftc -plugin-path -Xswiftc "$sdk_plugins"
    fi
fi
