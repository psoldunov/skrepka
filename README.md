# Skrepka

A clipboard-history manager for macOS 26. Lives in the menu bar with no Dock
icon; press ⌘⇧V anywhere and a Liquid Glass picker opens over whatever app you
are in, without taking focus away from it.

![The Skrepka picker open over Safari, showing recent clipboard entries with
their source app and a ⌘N shortcut on each row](docs/images/picker.png)

- Text, rich text, URLs, files and images, with inline image previews
- Type to filter; ↑↓ to move; ↩ to paste into the app you were using
- ⌘1–⌘9 paste that row outright, ⇧⌘↩ pastes as plain text, ⌘P pins
- Pinned entries never age out
- Per-app exclusions, on top of automatically skipping anything a password
  manager marks transient or concealed
- Retention by item count and age, both configurable

## Requirements

macOS 26.0 or later, Apple silicon or one of the four Intel Macs that run
macOS 26. Xcode 26 to build.

## Install

```sh
brew install --cask psoldunov/tap/skrepka
```

Or download `Skrepka.zip` from the
[latest release](https://github.com/psoldunov/skrepka/releases/latest), unzip
it, and drag `Skrepka.app` into `/Applications`.

Either way the build is universal and notarized, so it opens on first launch
with no Gatekeeper detour.

The cask lives in
[`psoldunov/homebrew-tap`](https://github.com/psoldunov/homebrew-tap). Skrepka
has no in-app updater, so `brew upgrade --cask skrepka` is the whole update
path — and `brew uninstall --zap --cask skrepka` is the one that takes the
clipboard history with it.

## Build and run

```sh
scripts/run.sh        # build, bundle, sign, launch
scripts/bundle.sh     # produce build/Skrepka.app only
scripts/notarize.sh   # build, sign, notarize, staple — the copy you send out
scripts/doctor.sh     # the quality gate
scripts/make-icon.sh  # redraw Sources/Skrepka/Resources/AppIcon.icns
```

Launch with `scripts/run.sh` rather than running the binary directly. TCC
attributes permissions to the responsible process, so a shell-launched binary
inherits the terminal's grants instead of exercising the real permission path.

### Architecture

`scripts/bundle.sh` builds for the machine it runs on. `SKREPKA_UNIVERSAL=1`
builds an arm64 + x86_64 binary instead:

```sh
SKREPKA_UNIVERSAL=1 scripts/bundle.sh
```

`scripts/notarize.sh` sets it, because that is the build that goes to other
people. macOS 26 is the last release to support Intel, and four models still run
it — the 2019 Mac Pro, the 2019 16-inch MacBook Pro, the 2020 13-inch MacBook
Pro with four Thunderbolt 3 ports, and the 2020 27-inch iMac. An arm64-only
`.app` does not launch on any of them.

The universal build costs roughly twice the compile work and doubles the
executable — 2.3 MB to 4.7 MB, measured on this release build. The local edit
loop pays neither.

### Signing

`scripts/bundle.sh` signs with a Developer ID identity, overridable via
`SKREPKA_SIGN_IDENTITY`. This is not cosmetic: an ad-hoc signature pins the
designated requirement to the binary's cdhash, which changes on every source
edit, so macOS treats each rebuild as a new app and drops the Accessibility
grant. A Developer ID requirement names only the bundle id and team, so the
grant survives rebuilds. Without an identity the script falls back to ad-hoc and
warns.

### Icon

One mark, drawn once: a swirl paperclip, one continuous wire through three
U-turns with a semicircular cap on each free end. It lives as a `CGPath` in
`PaperclipPath` (`Sources/SkrepkaCore/Branding/`), and `scripts/paperclip.svg`
is the same artwork in SVG form — the design source the path was transcribed
from. The source art cuts both free ends square; the caps are the one change.

Everything that shows the mark draws that path:

- **`AppIcon.icns`** — `scripts/make-icon.swift` renders the vectors once per
  iconset size and `scripts/make-icon.sh` packs them. The script is *compiled*
  rather than interpreted, with `PaperclipPath.swift` linked in beside it, so
  the icon cannot drift from the app. Palettes are `paper` (off-white tile,
  near-black clip — ships) and `carbon` (off-black tile, chrome clip); pass one
  by name, or `--preview <dir>` to write both at 1024 and 64 px.
- **The menu bar** — `StatusItemIcon` in `SkrepkaCore`, the same path flattened
  into an 18pt template image. A test pins its ink coverage to a band, because
  a mark drawn too heavy reads as a blob and one drawn too light disappears,
  and neither fails loudly. The wire is drawn at its own weight and not
  boldened: the three nested wires leave gaps narrower than the wire, and
  thickening it closes them.
- **In-app** — `PaperclipMark`, a SwiftUI `Shape` in `Sources/Skrepka/Branding/`,
  on the Welcome header, the Settings identity row and the empty picker. The
  permission rows keep the system `doc.on.clipboard` symbol: they label the
  clipboard, not Skrepka.

The app icon artwork is full-bleed square on purpose. macOS 26 masks a legacy
`.icns` into its own rounded-rectangle, insets it and adds the shadow — checked
on this machine by asking `NSWorkspace.icon(forFile:)` for a throwaway bundle,
not assumed from the icon's own corners.

## Permissions

- **None** for capturing history or for the global shortcut. The hotkey goes
  through Carbon's `RegisterEventHotKey`, which needs no grant.
- **Accessibility**, only to paste into the frontmost app — Skrepka synthesises
  ⌘V. It asks the first time you paste something. Decline it and Skrepka falls
  back to copying, which you then paste yourself. That fallback is also
  available deliberately: turn off "Paste automatically" in Settings.

## Layout

```
Sources/SkrepkaCore/    models, storage, pasteboard, search — testable, no UI
Sources/Skrepka/        app shell, panel, SwiftUI views, platform glue
Tests/SkrepkaCoreTests/ Swift Testing
```

`SkrepkaCore` is a plain SwiftPM library with no window-server dependency, so
`swift test` runs in well under a second. The app target holds only what cannot
run without a live window.

## Quality gate

`scripts/doctor.sh` runs format check, lint, build with warnings as errors,
tests, and a dead-code scan, and is the definition of done. `--fast` skips tests
and the dead-code scan; a pre-commit hook uses that.

Install the two external tools once:

```sh
brew install swiftlint periphery
```

Doctor skips either one with a warning if it is missing rather than failing.

Note: Periphery's upstream repository was archived in August 2026 and Homebrew
disables the formula in 2027. It is kept because nothing else finds an
unreferenced type across modules; expect to drop it eventually.

## Storage

SwiftData at
`~/Library/Application Support/dev.soldunov.skrepka/skrepka.store`. Image
payloads use `@Attribute(.externalStorage)`, so large blobs land beside the
database rather than inside a row. The picker holds only lightweight summaries
plus a small thumbnail; a full payload is read only when an entry is pasted.

## License

MIT — see [LICENSE](LICENSE).
