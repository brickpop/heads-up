#!/usr/bin/env bash
# Installs the Swift toolchain on Linux without root, for `just test` and `just lint`.
#
# Everything it downloads is pinned by SHA-256 in tools/swift-linux.lock, and any
# mismatch stops it. It unpacks the toolchain and a small sysroot (the C library,
# headers and a few libraries the toolchain needs) into the user's cache, then
# writes env.sh, which `just` sources before it runs swift.
#
# Running it again does nothing while the lock and this script are unchanged.
# If it is killed halfway, the next run starts the unpacking again from scratch.
#
# When gpgv exists, it also checks the toolchain's signature against tools/swift-keys.gpg.
#
# Environment (for the tests):
#   HEADSUP_SWIFT_LOCK  the lock file to read (default: tools/swift-linux.lock).
#                       Only a lock given this way may use file:// URLs.
#   HEADSUP_CACHE       where downloads and the install go (default: ~/.cache/headsup)
set -euo pipefail

say() { echo "setup-swift: $*"; }
die() {
    echo "setup-swift: $*" >&2
    exit 1
}

[ "$(uname -s)" = Linux ] || die "this is for Linux only. On macOS, use Xcode's Swift (xcrun swift --version)."
[ "$(uname -m)" = aarch64 ] || die "the lock pins Linux aarch64 builds, and this machine is $(uname -m)."
for tool in curl sha256sum tar dpkg-deb; do
    command -v "$tool" >/dev/null || die "$tool is missing. Install it, then run this again."
done

tools_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
lock=${HEADSUP_SWIFT_LOCK:-$tools_dir/swift-linux.lock}
keyring=$tools_dir/swift-keys.gpg
# The repo's lock downloads over https only; the tests' locks also read local files.
if [ -n "${HEADSUP_SWIFT_LOCK:-}" ]; then
    schemes='=https,file'
else
    schemes='=https'
fi
cache=${HEADSUP_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/headsup}
downloads=$cache/downloads
install=$cache/swift
staging=$cache/swift.new
system_ncurses=/usr/lib/aarch64-linux-gnu/libncursesw.so.6

[ -f "$lock" ] || die "lock file not found: $lock"
[ -f "$keyring" ] || die "the Swift release key is missing: $keyring"

# The stamp is the hash of the lock, the keyring and this script: change one, and the next run rebuilds.
wanted_stamp=$(cat "$lock" "$keyring" "${BASH_SOURCE[0]}" | sha256sum | cut -d' ' -f1)
if [ -f "$install/stamp" ] && [ "$(cat "$install/stamp")" = "$wanted_stamp" ]; then
    say "Swift is already set up in $install. Nothing to do."
    exit 0
fi

# Reads the lock into arrays. Each line is: <kind> <name> <sha256> <url>.
swift_version=""
toolchain_name="" toolchain_sha="" toolchain_url=""
signature_name="" signature_url=""
deb_names=() deb_shas=() deb_urls=()
line_number=0
while read -r kind name sha url rest; do
    line_number=$((line_number + 1))
    case "$kind" in "" | "#"*) continue ;; esac
    if [ "$kind" = swift-version ]; then
        swift_version=$name
        continue
    fi
    [ -n "$url" ] && [ -z "$rest" ] || die "$lock:$line_number: expected <kind> <name> <sha256> <url>"
    case "$name" in */* | .* | "") die "$lock:$line_number: '$name' is not a plain file name" ;; esac
    case "$url" in
    https://*) ;;
    file://*) [ "$schemes" = '=https,file' ] || die "$lock:$line_number: only https:// URLs are allowed" ;;
    *) die "$lock:$line_number: only https:// URLs are allowed" ;;
    esac
    if [ "$kind" != signature ] && ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        die "$lock:$line_number: '$sha' is not a SHA-256"
    fi
    case "$kind" in
    toolchain) toolchain_name=$name toolchain_sha=$sha toolchain_url=$url ;;
    signature) signature_name=$name signature_url=$url ;;
    deb)
        deb_names+=("$name")
        deb_shas+=("$sha")
        deb_urls+=("$url")
        ;;
    *) die "$lock:$line_number: unknown kind '$kind'" ;;
    esac
done <"$lock"
[ -n "$swift_version" ] || die "$lock: no swift-version line"
[[ "$swift_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "$lock: '$swift_version' is not a version"
[ -n "$toolchain_name" ] || die "$lock: no toolchain line"

# Downloads one file into $downloads and checks its SHA-256. A file already there
# is checked again before it is used. On a mismatch the file is deleted and setup stops.
fetch() {
    local name=$1 sha=$2 url=$3
    local file=$downloads/$name
    if [ ! -f "$file" ]; then
        say "downloading $name"
        curl --fail --silent --show-error --location --retry 3 \
            --proto "$schemes" --proto-redir '=https' \
            --output "$file.part" "$url" || die "could not download $url"
        mv "$file.part" "$file"
    fi
    if [ "$sha" != - ]; then
        local actual
        actual=$(sha256sum "$file" | cut -d' ' -f1)
        if [ "$actual" != "$sha" ]; then
            rm -f "$file"
            die "SHA-256 mismatch for $name: the lock pins $sha, the download is $actual. Setup stopped and the file was deleted."
        fi
    fi
}

mkdir -p "$downloads"
fetch "$toolchain_name" "$toolchain_sha" "$toolchain_url"
for i in "${!deb_names[@]}"; do
    fetch "${deb_names[$i]}" "${deb_shas[$i]}" "${deb_urls[$i]}"
done

# The pinned hash is the main check (F15). When gpgv exists, the toolchain's
# signature is checked too, against the Swift release key committed in tools/.
if [ -z "$signature_url" ]; then
    say "no signature or keyring in the lock: the pinned SHA-256 is the only check of the toolchain"
elif command -v gpgv >/dev/null; then
    rm -f "$downloads/$signature_name"
    fetch "$signature_name" - "$signature_url"
    gpgv --keyring "$keyring" "$downloads/$signature_name" "$downloads/$toolchain_name" ||
        die "the toolchain's signature does not verify. Setup stopped."
    say "toolchain signature verified"
else
    say "gpgv not found: the pinned SHA-256 is the only check of the toolchain"
fi

# Unpacks into a staging folder, removed if anything fails, then swaps it in.
rm -rf "$staging"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/toolchain" "$staging/sysroot" "$staging/lib" "$staging/bin"

say "unpacking the toolchain"
tar -xzf "$downloads/$toolchain_name" -C "$staging/toolchain" --strip-components=1
for name in "${deb_names[@]}"; do
    dpkg-deb -x "$downloads/$name" "$staging/sysroot"
done

# Links are relative, so they still hold once staging is renamed.
# The compiler looks for the Swift runtime inside the sysroot.
ln -s ../../../toolchain/usr/lib/swift "$staging/sysroot/usr/lib/swift"
ln -s ../../../toolchain/usr/lib/swift_static "$staging/sysroot/usr/lib/swift_static"
# libc.so names /lib/... paths, which the linker resolves inside the sysroot.
[ -e "$staging/sysroot/lib" ] || ln -s usr/lib "$staging/sysroot/lib"
# Libraries the toolchain's own programs load, which the image lacks.
ln -s "$system_ncurses" "$staging/lib/libncurses.so.6"
ln -s ../sysroot/usr/lib/aarch64-linux-gnu/libxml2.so.2 "$staging/lib/libxml2.so.2"
# The swift driver calls `ld`; the toolchain ships lld.
ln -s ../toolchain/usr/bin/ld.lld "$staging/bin/ld"

cat >"$staging/env.sh" <<EOF
# Written by tools/setup-swift.sh for Swift $swift_version. Source it before running swift.
HEADSUP_SWIFT_HOME=$(printf %q "$install")
export PATH="\$HEADSUP_SWIFT_HOME/bin:\$HEADSUP_SWIFT_HOME/toolchain/usr/bin:\$PATH"
export SDKROOT="\$HEADSUP_SWIFT_HOME/sysroot"
export LD_LIBRARY_PATH="\$HEADSUP_SWIFT_HOME/lib:\$HEADSUP_SWIFT_HOME/toolchain/usr/lib/swift/linux\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF

rm -rf "$install"
mv "$staging" "$install"
trap - EXIT
# The stamp is written last: without it, the next run starts again.
echo "$wanted_stamp" >"$install/stamp.part"
mv "$install/stamp.part" "$install/stamp"
say "Swift $swift_version is set up in $install"
