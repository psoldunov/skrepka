# Changelog

Every released version, newest first. Dates are the day the release was
published. Each heading links to the tag it was cut from; the
[releases page](https://github.com/psoldunov/skrepka/releases) carries the same
notes alongside the notarized `Skrepka.zip` for that version.

Skrepka has no in-app updater, so `brew upgrade --cask skrepka` — or a fresh
download — is the whole update path.

## [0.1.3](https://github.com/psoldunov/skrepka/releases/tag/v0.1.3) — 2026-09-06

A copy of several files is one row that knows it holds several files.

### Added

- **A copied picture is called an Image.** A screenshot copied in Finder
  arrives as a `public.file-url` like any other file, so the row read "File"
  beside the picture it was already showing. The kind is now read from the
  file's content type in the same pass that already asks the file system about
  it, and a picture saved without an extension — which reports the generic
  `public.data` and cannot be named that way — is corrected once a thumbnail
  has been drawn out of it. It stays a file-system entry throughout, so no
  stored row loses its identity over the change.
- **A copy of several files is drawn as a stack of their own icons.** The first
  three files are layered front to back, each showing the file's own picture
  where one can be decoded and its `NSWorkspace` icon otherwise — the app's
  artwork, the folder, the PDF, rather than a repeated grey glyph. The row
  keeps a count badge beside the stack, so three layers say "several" whether
  the copy held three files or thirty. All three icons render or none do:
  dropping one that failed would promote the second file to the front and
  picture the wrong file as the leader, so the fallback is the single preview
  the row had before.

### Fixed

- **A copy of several files is no longer stored as one of them.** Only the
  first pasteboard item was ever read, so a three-file copy kept one file URL
  and took its name from Finder's text flavour, which lists the display names
  of the whole selection. The row ran all three names together, reported "3
  lines" it did not have, showed the first file's dimensions, and pasted one
  file. Capture now reads every item's file URL — the shape `NSPasteboard.h`
  names as the replacement for the deprecated `NSFilenamesPboardType` — and the
  entry keeps the whole list beside its payload. It is named from the files it
  holds, identified by the whole set so two selections sharing a first file
  stay two rows, measured across every file, and pasted back as one item per
  file.
- **Naming a large selection is bounded, pasting it is not.** Both file-system
  passes share one time budget and the names stop at a hundred; a selection
  past that ceiling is still counted and still pasted in full, only unnamed
  past the hundredth. Reading the URLs themselves is uncapped — 20,000 of them
  measure 172 ms, inside the poller's cadence — because a row that pastes fewer
  files than it claims is the defect this release fixes.

## [0.1.2](https://github.com/psoldunov/skrepka/releases/tag/v0.1.2) — 2026-09-05

Copied files say what they are and how big they are.

### Added

- **Rows show the size of what was copied.** A file reports the file system's
  answer, an application bundle reports everything inside it — the number
  Finder shows for it too — and an image copied as pasteboard bytes reports its
  richest representation rather than the sum of every format the app put on the
  pasteboard. Sizes use decimal units, so a row and Get Info agree about the
  same file, and they follow the machine's locale. Text, rich text and links
  get no size: the row already says how many lines they are.
- **A copied folder is measured by walking it**, bounded at 250 ms. Past that
  the size is left off entirely rather than shown short — "412 MB" under a
  folder holding 60 GB is worse than no number at all. Symbolic links are
  counted at neither end, and children the file system will not describe are
  skipped rather than failing the measurement.

### Fixed

- **A copied folder is no longer indistinguishable from a copied file.** Finder
  writes one `public.file-url` whether you copied a document, a folder or an
  application, so every such row read "File" and wore a document icon. Folders
  now carry a folder icon and a "Folder" label. Application bundles and
  document packages stay one item with their preview intact, the way Finder
  shows them.
- **Folders recorded before this release correct themselves.** Files and
  folders share a hash domain, so an old entry collapses onto today's capture
  instead of appearing twice, and copying it again fixes the stored kind —
  the same repeat-copy path that already backfills a missing thumbnail.

### Documentation

- Contributing guide, code of conduct, security policy, and issue and pull
  request templates.
- A phase-by-phase plan for a Linux port and LAN clipboard sync, under
  [`docs/linux-sync/`](docs/linux-sync/).

## [0.1.1](https://github.com/psoldunov/skrepka/releases/tag/v0.1.1) — 2026-09-05

The bundle identifier moves from `com.psoldunov.skrepka` to
`dev.soldunov.skrepka`. Nothing else changes.

### Changed

- **Bundle identifier is now `dev.soldunov.skrepka`.** macOS keys per-app state
  to the bundle identifier and this release ships no migration, so upgrading
  from 0.1.0 starts over: history is not carried across, settings reset to
  defaults, Accessibility has to be granted again, and Launch at Login is
  orphaned. The old store stays on disk at
  `~/Library/Application Support/com.psoldunov.skrepka/` — copy it over the new
  folder before first launch to carry the history across, or delete it once you
  are sure you do not want it, since it is the whole history in the clear. The
  dead "Skrepka" entries under System Settings → Privacy & Security →
  Accessibility and under General → Login Items & Extensions can be removed.

## [0.1.0](https://github.com/psoldunov/skrepka/releases/tag/v0.1.0) — 2026-09-05

First release. A clipboard-history manager for macOS 26 that lives in the menu
bar with no Dock icon; ⌘⇧V opens a Liquid Glass picker over whatever app you
are in, without taking focus away from it.

### Added

- Text, rich text, URLs, files and images, with inline image previews.
- Type to filter; ↑↓ to move; ↩ to paste into the app you were using. ⌘1–⌘9
  paste that row outright, ⇧⌘↩ pastes as plain text, ⌘P pins.
- Pinned entries never age out.
- Per-app exclusions, on top of automatically skipping anything a password
  manager marks transient or concealed.
- Retention by item count and age, both configurable.
- No permission is needed to capture history, and none for the global shortcut.
  Accessibility is asked for once, only so Skrepka can synthesise ⌘V into the
  frontmost app; decline it and pasting falls back to copying, which you then
  paste yourself.
