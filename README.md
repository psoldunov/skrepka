# Clippy

A clipboard-history manager for macOS 26. Lives in the menu bar with no Dock
icon; press ⌘⇧V anywhere and a Liquid Glass picker opens over whatever app you
are in, without taking focus away from it.

- Text, rich text, URLs, files and images, with inline image previews
- Type to filter; ↑↓ to move; ↩ to paste into the app you were using
- ⌘1–⌘9 paste that row outright, ⇧⌘↩ pastes as plain text, ⌘P pins
- Pinned entries never age out
- Per-app exclusions, on top of automatically skipping anything a password
  manager marks transient or concealed
- Retention by item count and age, both configurable

## Requirements

macOS 26.0 or later, Apple silicon. Xcode 26 to build.

## Build and run

```sh
scripts/run.sh        # build, bundle, sign, launch
scripts/bundle.sh     # produce build/Clippy.app only
scripts/doctor.sh     # the quality gate
scripts/make-icon.sh  # redraw Sources/Clippy/Resources/AppIcon.icns
```

Launch with `scripts/run.sh` rather than running the binary directly. TCC
attributes permissions to the responsible process, so a shell-launched binary
inherits the terminal's grants instead of exercising the real permission path.

### Signing

`scripts/bundle.sh` signs with a Developer ID identity, overridable via
`CLIPPY_SIGN_IDENTITY`. This is not cosmetic: an ad-hoc signature pins the
designated requirement to the binary's cdhash, which changes on every source
edit, so macOS treats each rebuild as a new app and drops the Accessibility
grant. A Developer ID requirement names only the bundle id and team, so the
grant survives rebuilds. Without an identity the script falls back to ad-hoc and
warns.

### Icon

The app icon is a gem clip with eyes holding a stack of notes — a nod to the
Office assistant the app is named after. It is drawn in code, not in a design
tool: `scripts/make-icon.swift` renders the vectors once per iconset size and
`scripts/make-icon.sh` packs them into `Sources/Clippy/Resources/AppIcon.icns`.
Pass a palette name (`sand`, `ink`, `graphite`, `sage`) to try another; `sand`
ships. `--preview <dir>` writes every palette at 1024 and 64 px for comparison.

The menu bar mark is drawn too, by `StatusItemIcon` in `ClippyCore` — the same
gem clip, thinned and flattened into an 18pt template image, with the eyes kept
as pupils since a template image is alpha only. A test pins its ink coverage to
a band, because a wire drawn too heavy reads as a blob and one drawn too light
disappears, and neither fails loudly.

The app icon artwork is full-bleed square on purpose. macOS 26 masks a legacy
`.icns` into its own rounded-rectangle, insets it and adds the shadow — checked
on this machine by asking `NSWorkspace.icon(forFile:)` for a throwaway bundle,
not assumed from the icon's own corners.

## Permissions

- **None** for capturing history or for the global shortcut. The hotkey goes
  through Carbon's `RegisterEventHotKey`, which needs no grant.
- **Accessibility**, only to paste into the frontmost app — Clippy synthesises
  ⌘V. It asks the first time you paste something. Decline it and Clippy falls
  back to copying, which you then paste yourself. That fallback is also
  available deliberately: turn off "Paste automatically" in Settings.

## Layout

```
Sources/ClippyCore/    models, storage, pasteboard, search — testable, no UI
Sources/Clippy/        app shell, panel, SwiftUI views, platform glue
Tests/ClippyCoreTests/ Swift Testing
```

`ClippyCore` is a plain SwiftPM library with no window-server dependency, so
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

SwiftData at `~/Library/Application Support/com.psoldunov.clippy/clippy.store`.
Image payloads use `@Attribute(.externalStorage)`, so large blobs land beside the
database rather than inside a row. The picker holds only lightweight summaries
plus a small thumbnail; a full payload is read only when an entry is pasted.
