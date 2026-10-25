# Icons

Sources (SVG) are in `source/`. The files the app uses sit in `Resources/`:

- `MenuBarGlyph.pdf` (vector) and `MenuBarGlyph.png` / `@2x.png`: the idle menu bar item, 18 × 18 pt. Black on transparent: load it as a **template image** (`isTemplate = true`) so macOS tints it for light, dark and tinted menu bars.
- `AppIcon.icns`: the app icon (light), 16–1024 px. Set `CFBundleIconFile = AppIcon` in Info.plist.
- `source/AppIcon-Dark.svg` and `source/AppIcon-Tinted.svg`: the dark and tinted variants, for an Icon Composer icon later.

The timer, cup and pause items in the menu bar use SF Symbols (`timer`, `cup.and.saucer.fill`, `pause.circle`), not custom glyphs.

## Rebuilding

After you change an SVG in `source/`, run from the repository root:

```sh
tools/make-icons.sh
```

It needs Node.js and npm (Linux or macOS). It renders the SVGs with `@resvg/resvg-js` 2.6.2, installed into a temporary folder for the run with `npm ci` from the lockfile in `tools/icons/` (every package checked against its sha512), and writes the four files above into `Resources/`:

- the glyph at 18 and 36 px (PNG), and as a vector PDF drawn from the same geometry. `tools/make-icons.js` writes the PDF by hand, so if you change the glyph's shapes, change them there too;
- the app icon (light) at 16, 32, 64, 128, 256, 512 and 1024 px, packed into `AppIcon.icns`.

The output is the same byte for byte on every run, so `git diff` shows only real changes.
