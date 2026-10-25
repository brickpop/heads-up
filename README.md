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

On macOS, the Command Line Tools are enough; Xcode isn't needed. HeadsUp builds with one Swift
series everywhere, the one in `.swift-version` (6.2): Linux uses exactly that release, and the Mac
needs a "Command Line Tools for Xcode 26" release that ships Swift 6.2.x (`swift --version` says
`Apple Swift version 6.2…`). `xcode-select --install` installs the newest tools; if they ship
another Swift, download one with Swift 6.2 from https://developer.apple.com/download/all/. The
recipes stop with a clear message when the version doesn't match. `just lint` uses `swift format`
from the toolchain; if the toolchain lacks it, install it with `brew install swift-format`.
`just app` builds arm64 and x86_64 separately and joins them with `lipo`.
The bundle identifier and the version are variables at the top of the `justfile`.
Dependencies are pinned in `Package.resolved`, and builds never resolve new versions.
To change a dependency, edit `Package.swift`, run `swift package resolve`, and commit both files.
