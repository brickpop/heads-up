# Making a release build

The release is `build/HeadsUp.dmg`, which holds `HeadsUp.app` for Apple silicon (arm64) only;
Intel isn't supported by the macOS 27 Command Line Tools. The image and the app are signed with
your own code-signing identity, with the hardened runtime. There is no notarization and no
auto-update (ADR-001 §10).

This page covers the signed build on your own Mac (`just build`). The public release on GitHub
and Homebrew is built by CI, unsigned for now: see [Publishing a release (CI)](#publishing-a-release-ci).

## Once: the tools and the identity

1. Install the Command Line Tools with Swift 6.4 or newer: check with `swift --version` (see the
   README). Install `just` with `brew install just`.
2. A code-signing identity in your login keychain. **Recommended: a free Apple Development
   certificate.** Sign in with your Apple ID in Xcode's Settings → Accounts, which creates a
   free "Personal Team", then Manage Certificates → + → Apple Development. If you don't want
   Xcode installed, a teammate who has it can export the certificate to you as a .p12.
   It needs no extra trust step. Because every build is signed by the same trusted identity,
   macOS also doesn't ask for your login password the first time each new build reads a
   saved API token from the Keychain; with a self-signed certificate it may ask once after
   every rebuild (ADR-001 §6.4).

   **Or a self-signed certificate**, made in Keychain Access → Certificate Assistant →
   Create a Certificate…, with Certificate Type "Code Signing". A new self-signed
   certificate isn't trusted yet, so it isn't listed as valid, and `just build` stops. Trust it
   once: in Keychain Access, double-click the certificate → Trust → Code Signing: **Always
   Trust**, then close the window and type your password.

   Either way, check that it is listed as a valid identity:

   ```sh
   security find-identity -v -p codesigning
   ```

3. Name it in one place, the environment variable `HEADSUP_SIGN_ID`: its full name exactly as
   that list prints it (in quotes), or its 40-character hash. Part of a name, the list number,
   or `-` is refused.

   ```sh
   export HEADSUP_SIGN_ID="Apple Development: Your Name (ABCDE12345)"
   ```

## Each release

```sh
just test && just lint
just build
```

`just build` stops at the first check that fails, with a line starting `make-app:`.

| Check | What it proves |
|---|---|
| `HEADSUP_SIGN_ID` is one whole valid identity in `security find-identity -v` (its hash or exact name; not `-`) | the identity you named exists and is trusted, checked before the build starts |
| `swift --version` is 6.4 or newer; a newer one prints a note | this Mac's Swift isn't older than the tested one (Linux runs the tests on the `.swift-version` release) |
| Only versions from `Package.resolved` (F15) | no dependency changed since review |
| The core tests pass on this Mac's Swift (`swift test`, run alongside the two builds), before anything is signed | the release compiler runs the tests too, not only Linux's |
| Each architecture's binary has no quick timers | no debug timing in a release |
| `lipo -archs` is exactly arm64 | it is the Apple silicon build we tested, with nothing else in it |
| `codesign --verify --strict --deep` | the signature covers everything in the app |
| Each architecture's entitlements are exactly `automation.apple-events` and `personal-information.calendars`, both true, and the hardened runtime is on (F8) | the app has only the permissions we reviewed |
| The signature isn't ad-hoc, and `codesign -dv` shows its `Authority=` | that identity really signed the app |
| `hdiutil verify`, `codesign --verify` on the `.dmg`, and the app inside it verifies | the image you hand out is whole, signed, and holds the signed app |

`just lint` checked the same entitlements and Info.plist before the build (F8, F19, R3).

To change the version, edit `version` at the top of the `justfile`. The build number is the
number of commits. To change the bundle id, edit `bundle_id` there; it is the only place. Do it before the first
real release: API tokens saved under the old id aren't found by the renamed app.

## Publishing a release (CI)

The public release is made by GitHub Actions (`.github/workflows/release.yml`), not on a Mac
of ours. Until there is an identity to sign it with (CEO, 2026-10-29: unsigned for now), it
publishes the ad-hoc build: `just release-adhoc` runs every check in the table above except the
signer, and makes `build/HeadsUp.dmg`, an unsigned image holding the ad-hoc app. Users open it
once with System Settings › Privacy & Security › Open Anyway (see the README).

**Before the first public release, set the real `bundle_id` in the `justfile`.**
`just release-adhoc` refuses the placeholder `dev.headsup.app`: API tokens saved under one id
aren't found under another, so the id must not change after people install HeadsUp.

To publish version 0.2.0:

1. Set `version := "0.2.0"` in the `justfile`, and merge that to `main`.
2. Tag that commit on `main` and push the tag:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

The workflow then:

1. stops if the tag isn't `v` + the justfile's version, or if the tagged commit isn't on `main`;
2. runs `just lint`, the tests of `tools/`, then `just release-adhoc` (which runs the core tests
   on the runner's Swift too);
3. creates the GitHub release `v0.2.0` with `HeadsUp-0.2.0.dmg` and `HeadsUp-0.2.0.dmg.sha256`,
   and notes generated from the merged pull requests;
4. writes `Casks/headsup.rb` in the Homebrew tap, from `packaging/homebrew/headsup.rb.in`
   (`tools/render-cask.sh`), with the new version and checksum, and pushes it.

### Settings, once (the CEO)

In the repository's **Settings › Secrets and variables › Actions**:

| Name | Kind | Value |
|---|---|---|
| `HOMEBREW_TAP` | variable | The tap repository, e.g. `brickpop/homebrew-tap`. Without it, the cask step is skipped. |
| `HOMEBREW_TAP_TOKEN` | secret | A fine-grained personal access token with **Contents: read and write** on the tap repository only. |
| `MACOS_RUNNER` | variable, optional | The runner for CI's macOS job on pushes to `main` only. Default `macos-latest`. |

In **Settings › Rules › Rulesets**, a tag ruleset on `v*` that lets only the CEO create, update
or delete those tags. A pushed `v*` tag publishes a release, so it is the release permission.

The tap repository must exist and be public. A tap named `<owner>/homebrew-tap` installs as
`brew install --cask <owner>/tap/headsup`; the README uses `brickpop/tap/headsup`.

### Runners

- **A release is built only on GitHub's own `macos-latest`**, never on a personal Mac or a
  shared runner. The workflow names no other.
- **Pull requests always run on GitHub's own runners**, never a self-hosted one: code from a fork
  must not reach a machine of ours. `MACOS_RUNNER` applies to pushes to `main` only.
- **`macos-latest` needs Swift 6.4 or newer** (the newest Xcode on it is selected). With an
  older one, the macOS jobs fail at once with `tools/swift.sh`'s message, until GitHub's image
  catches up.
- **`ubuntu-24.04-arm` runners are free for public repositories only.** For a private repository
  they are billed, or the Linux job must move to another runner.

### What is pinned

- GitHub actions (`actions/checkout`, `actions/cache`) are pinned by full commit, with their tag
  in a comment. To update one, take the commit of its new release tag.
- On macOS, `just` is a pinned release whose SHA-256 is checked before it runs
  (`.github/scripts/install-just.sh`).
- **Not pinned:** `just` on CI's Linux job comes from `apt`, at whatever version Ubuntu has that
  day. It runs only the lint and the tests, never the release.
- The runners' images (Xcode, Swift, the OS) are GitHub's, and change when GitHub updates them.

## Other builds

- `just app`: the same app signed ad-hoc, no `.dmg`. macOS forgets its permissions and
  Keychain access after every ad-hoc build, so use `just build` day to day.
- `just app-quick`: "HeadsUp Quick", a separate debug app where a timer minute lasts 5 seconds.

## When something fails

Paste these back to the team:

1. the last 30 lines of `just build`;
2. `swift --version` and `sw_vers`;
3. `security find-identity -v -p codesigning` (it lists names and hashes, no secrets);
4. if the app was built: `codesign -dv --verbose=4 build/HeadsUp.app` and
   `codesign -d --entitlements - --xml build/HeadsUp.app`.
