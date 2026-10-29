# HeadsUp

A no-friction HUD for casual AI prompts, for launching timers, commands and services.

## Requirements

The Command Line Tools are enough; Xcode isn't needed. They must ship Swift 6.4 or newer
(`swift --version`):

    xcode-select --install

The project is checked on Linux with the Swift in `.swift-version` (6.4). A newer Swift on
the Mac builds too: the recipes print a one-line note saying so. Warnings are errors here, and a
newer Swift can warn about things 6.4 doesn't; if one stops the build, paste it to the team. An
older Swift stops the recipes with how to update.

`just lint` uses `swift format` from the toolchain; if your toolchain lacks it, install it with
`brew install swift-format`.

Dependencies are pinned in `Package.resolved`, and builds never resolve new versions. To change
a dependency, edit `Package.swift`, run `swift package resolve`, and commit both files.

## Build

Run `just` with no arguments to list the recipes. The ones you want on a Mac:

| Recipe | What it does |
|---|---|
| `just app` | Builds `build/HeadsUp.app`, signed ad-hoc with the hardened runtime. This is the one to use day to day. |
| `just app-quick` | `build/HeadsUp Quick.app`: a separate debug app (own name, bundle id and data folder) where one timer minute lasts 5 seconds, to check a whole Focus round quickly. Release builds can't contain it. |
| `just build` | The release: `build/HeadsUp.app` signed with `$HEADSUP_SIGN_ID`, and `build/HeadsUp.dmg`, both verified. See [docs/RELEASE.md](docs/RELEASE.md). |
| `just test` | Runs the core tests and the tests of `tools/`. |
| `just lint` | Checks the project's rules (no Apple-only imports in the core, the entitlements, Info.plist) and the formatting. |

HeadsUp builds for Apple silicon (arm64) only; Intel isn't supported by the macOS 27 Command Line
Tools. To sign for distribution, put a code-signing identity in your keychain and set `HEADSUP_SIGN_ID` to it
(`security find-identity -v -p codesigning` lists them). The bundle identifier and the version
are variables at the top of the `justfile`.

Ad-hoc builds are signed with the hardened runtime but with no identity, so macOS forgets the
app's permissions and Keychain access after each one. That is normal for `just app`.

The package is two modules: `HeadsUpCore` holds the logic, `HeadsUpApp` is the macOS shell, and
the manifest adds the shell only when it runs on macOS.

## Services

A service inherits HeadsUp's environment: all of a terminal's variables if HeadsUp was started
from one, or the short one macOS gives apps otherwise. It runs in your login shell, which adds
what your profile sets.

## Development

Code may be written on Linux (internal interim target), not the target platform HeadsUp ships for. On Linux there is no app — `just app`, `just app-quick` and `just build` all stop with a message.

To work that way, run `just setup-swift` once. It installs the pinned Swift toolchain into
`~/.cache/headsup` without root, and every download is checked against `tools/swift-linux.lock`;
`just test` and `just lint` then use that toolchain. The lock pins Linux aarch64 builds.
