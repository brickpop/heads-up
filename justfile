# HeadsUp's recipes (ADR-001 §10). Run `just` to list them.
#
# Linux: run `just setup-swift` once; `test` and `lint` then use that toolchain.
# macOS: the Command Line Tools with Swift 6.2.x, the series in .swift-version (Xcode isn't needed). `app` and `build`
# need macOS.

set shell := ["bash", "-euo", "pipefail", "-c"]

# The app's bundle identifier. A placeholder until the CEO chooses the real one.
bundle_id := "dev.headsup.app"
version := "0.1.0"
build_number := `git rev-list --count HEAD 2>/dev/null || echo 0`

# Lists the recipes.
default:
    @just --list

# Installs the pinned Swift toolchain for Linux, without root. A second run does nothing.
setup-swift:
    tools/setup-swift.sh

# Runs the core tests, then the tests of the scripts in tools/.
test:
    tools/swift.sh test --only-use-versions-from-resolved-file --disable-automatic-resolution
    tools/test-tools.sh

# Checks the project's rules (no Apple imports in the core, entitlements, Info.plist) and the formatting.
lint:
    tools/lint.sh
    tools/swift.sh format lint --strict --recursive Package.swift Sources Tests

# Builds build/HeadsUp.app, signed ad-hoc with the hardened runtime.
[macos]
app:
    tools/make-app.sh adhoc "{{ bundle_id }}" "{{ version }}" "{{ build_number }}"

[linux]
app:
    @echo "just app needs macOS. On Linux, use just test and just lint." >&2; exit 1

# Builds "HeadsUp Quick", a separate debug app where one timer minute lasts 5 seconds, for quick checks.
[macos]
app-quick:
    tools/make-app.sh quick "{{ bundle_id }}" "{{ version }}" "{{ build_number }}"

[linux]
app-quick:
    @echo "just app-quick needs macOS with Xcode. On Linux, use just test and just lint." >&2; exit 1

# Builds build/HeadsUp.app signed with $HEADSUP_SIGN_ID, and build/HeadsUp.dmg.
[macos]
build:
    tools/make-app.sh identity "{{ bundle_id }}" "{{ version }}" "{{ build_number }}"

[linux]
build:
    @echo "just build needs macOS. On Linux, use just test and just lint." >&2; exit 1
