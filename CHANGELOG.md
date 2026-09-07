# Changelog

Every released version, newest first. Dates are the day the release was
published. Each heading links to the tag it was cut from; the
[releases page](https://github.com/psoldunov/skrepka/releases) carries the same
notes alongside the notarized `Skrepka.zip` for that version.

Skrepka has no in-app updater, so `brew upgrade --cask skrepka` — or a fresh
download — is the whole update path.

## [0.1.4](https://github.com/psoldunov/skrepka/releases/tag/v0.1.4) — 2026-09-07

Your clipboard follows you to your other Mac, over the local network and
nowhere else.

### Added

- **Clipboard history syncs between devices you have paired.** Settings gains a
  Sync pane: one switch to share history, one to open a pairing window, and the
  list of devices this Mac trusts and can see. Paired devices exchange history
  every half minute, "Sync Now" is there for impatience, and each device has a
  live-clipboard switch of its own that pushes what you copy across the moment
  you copy it. There is no account, no server and no relay — Skrepka finds the
  other machine on the local network with Bonjour and talks to it directly.
- **Pairing is a code you compare on both screens.** Both machines show the same
  sixteen hex digits, grouped `A3F2-91BC-D4E7-0182` in a face where `0` and `O`
  differ, and neither pairs until a person confirms on both ends. That
  comparison is the whole man-in-the-middle defence: TLS proves the two ends
  share a tunnel and says nothing about which machine is on the far end, so
  nothing is pre-selected and the button says what it confirms. Devices are
  identified afterwards by a pinned self-signed certificate; a device that
  cannot present the certificate you approved is refused, not re-asked.
- **Everything crosses inside TLS 1.3, and only to a device on the pinned
  list.** The port that serves history accepts approved certificates and nothing
  else. Accepting *new* devices is a second, separate listener that runs only
  while you have asked for it, and it closes itself — on the first pairing that
  succeeds, and on a five-minute expiry — so the window every attack on first
  contact needs is not left standing open because you got distracted.
- **Concealed content never leaves the machine.** A password your manager marked
  `org.nspasteboard.ConcealedType` is filtered out of both paths that could emit
  it — the index a peer browses and the payload it can fetch — so a peer is not
  even told the hash. Entries from apps on your exclusion list, and anything
  carrying a privacy marker, never reached storage to begin with and so cannot
  sync either.
- **Unpairing forgets the device.** Its certificate is dropped, its
  live-clipboard choice goes with it rather than lingering in preferences to
  re-apply if that machine ever pairs again, and anything already synced stays
  where it is.

### Changed

- **Skrepka now uses the network, and says so.** macOS asks for Local Network
  access the first time you switch sharing on, and Skrepka asks once: the
  bring-up stops after discovery, which is the one call that waits for your
  answer rather than failing on it, and publishing and dialling resume by
  themselves the moment you allow it. Decline it and the Sync pane says so with
  a button straight to the right System Settings pane. The whole feature is off
  until you turn it on, and [SECURITY.md](SECURITY.md)'s threat model has been
  rewritten around it.
- **Launch at Login reads launchd rather than a stored copy of it.** The switch
  was a preference that was reconciled only when you clicked it, so it went
  stale after a toggle in System Settings, after an approval granted there, and
  after the app was moved out of `/Applications` — and the card could show
  "Waiting for your approval" above a switch reading off. The preference is
  gone; `SMAppService` is the only authority.

### Fixed

- **Settings and the welcome window take focus, and stay in front until you
  dismiss them.** Skrepka has no Dock icon and never becomes the active app, so
  both windows opened without keyboard focus and the first click elsewhere
  buried them — with no Cmd-Tab entry to dig them back out and, for the welcome
  window, no way to reopen it at all. Both are now non-activating panels that
  float, take key while Skrepka is inactive, and stay visible in Mission
  Control. Alerts and the exclusion-list file picker were lifted with them, so a
  dialog opened from Settings can no longer draw behind the window that asked
  for it.
- **The first-run window opens centred.** It was placed before its content had
  been measured, and grew from that corner — 229pt off centre on the test
  display.
- **The Settings tab bar no longer crowds the traffic lights**, and switching to
  Status no longer redraws every card 17pt narrower. Under legacy scrollers a
  pane tall enough to scroll was laid out beside its scrollbar; the gutter is
  now reserved in every pane, which keeps the scrollbar for anyone who asked for
  one.
- **A copied file is asked about once rather than twice.** Two overlapping
  file-system round trips per captured file are microseconds on a local disk and
  a doubled stall on a path under a mount that has stopped responding — which is
  the case the whole detail pass exists for. It is also an atomic snapshot: the
  two old lookups could disagree about a file deleted between them.
- **A schema migration and the stamp recording it now land together or not at
  all.** A crash between the two left a database carrying the new column and
  still reading the old version, and every subsequent open threw on re-running
  the migration. A store nobody can reopen is worse than an upgrade that never
  happened.

### Known limitations

- **A live-pushed item over 256 KB reaches the other machine's history but not
  its clipboard.** It is in the picker on the far side and pastes normally; it
  simply does not land on the system pasteboard by itself. Below 256 KB — which
  is every text, link and small image — live push carries the bytes inline and
  the clipboard follows.
- **Sync is between machines running Skrepka on your local network.** Two
  devices that cannot see each other over Bonjour cannot pair or exchange
  anything, and there is no relay to fall back on.

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
