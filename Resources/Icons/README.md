# Icons

Sources (SVG) are in `source/`. The file the app uses sits in `Resources/`:

- `AppIcon.icns`: the app icon (light), 16–1024 px. Set `CFBundleIconFile = AppIcon` in Info.plist.
- `source/AppIcon-Dark.svg` and `source/AppIcon-Tinted.svg`: the dark and tinted variants, for an Icon Composer icon later.

The menu bar item uses SF Symbols (`timer` and `cup.and.saucer`), not custom glyphs.

## Rebuilding

After you change `source/AppIcon-Light.svg`, run from the repository root:

```sh
tools/make-icons.sh
```

It needs Node.js and npm (Linux or macOS). It renders the SVG with `@resvg/resvg-js` 2.6.2, installed into a temporary folder for the run with `npm ci` from the lockfile in `tools/icons/` (every package checked against its sha512), and writes `AppIcon.icns` into `Resources/`: the app icon at 16, 32, 64, 128, 256, 512 and 1024 px.

The output is the same byte for byte on every run, so `git diff` shows only real changes.
