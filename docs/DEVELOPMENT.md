# Developing HeadsUp

How to build, test and work on HeadsUp. For using it, see the [README](../README.md); for
making a release, [RELEASE.md](RELEASE.md).

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
| `just build` | The release: `build/HeadsUp.app` signed with `$HEADSUP_SIGN_ID`, and `build/HeadsUp.dmg`, both verified. See [RELEASE.md](RELEASE.md). |
| `just release-adhoc` | What CI publishes while there is no signing identity: every check of `just build` except the signer, then `build/HeadsUp.dmg`, an unsigned image holding the ad-hoc app. |
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

## Development

Code may be written on Linux (internal interim target), not the target platform HeadsUp ships for. On Linux there is no app — `just app`, `just app-quick` and `just build` all stop with a message.

To work that way, run `just setup-swift` once. It installs the pinned Swift toolchain into
`~/.cache/headsup` without root, and every download is checked against `tools/swift-linux.lock`;
`just test` and `just lint` then use that toolchain. The lock pins Linux aarch64 builds.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and every pull request: `just lint` and
`just test` on Linux (arm64, with the toolchain from `just setup-swift`), and `just test` and
`just app` on macOS. Pull requests always use GitHub's `macos-latest`; pushes to `main` may use
another runner through the repository variable `MACOS_RUNNER`. The build stops with a clear
message if the runner's Swift is older than 6.4. Releases are made by
`.github/workflows/release.yml`: see [RELEASE.md](RELEASE.md), which also covers what CI pins
and the runners' limits.
