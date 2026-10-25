# HeadsUp

A macOS menu bar HUD for casual AI prompting and for launching timers, commands and services.

## Build

HeadsUp is one Swift package: `HeadsUpCore` (the logic, built and tested on Linux and macOS)
and `HeadsUpApp` (the macOS shell). The recipes are in the `justfile`:

| Recipe | Where | What it does |
|---|---|---|
| `just setup-swift` | Linux | Installs the pinned Swift toolchain into `~/.cache/headsup`, without root. Every download is checked against `tools/swift-linux.lock`. |
| `just test` | Linux, macOS | Runs the core tests and the tests of `tools/`. |
| `just lint` | Linux, macOS | Checks the project's rules (no Apple-only imports in the core, the entitlements, Info.plist) and the formatting. |
| `just app` | macOS | Builds `build/HeadsUp.app`, signed ad-hoc with the hardened runtime. |
| `just build` | macOS | Builds `build/HeadsUp.app` signed with `$HEADSUP_SIGN_ID`, and `build/HeadsUp.dmg`. |
| `just app-quick` | macOS | `build/HeadsUp Quick.app`: a separate debug app (own name, bundle id and data folder) where one timer minute lasts 5 seconds, to check a whole Focus round quickly. Release builds can't contain it. |

On macOS, use Xcode's Swift, at least the version in `.swift-version`.
The bundle identifier and the version are variables at the top of the `justfile`.
Dependencies are pinned in `Package.resolved`, and builds never resolve new versions.
To change a dependency, edit `Package.swift`, run `swift package resolve`, and commit both files.
