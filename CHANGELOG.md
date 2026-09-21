# Changelog

Every released version, newest first. Dates are the day the release was
published. Each heading links to the tag it was cut from; the
[releases page](https://github.com/psoldunov/skrepka/releases) carries the same
notes alongside the notarized `Skrepka.zip` for that version and, from 0.2.0,
the Linux tarballs with their checksums.

Skrepka has no in-app updater, so `brew upgrade --cask skrepka` — or a fresh
download — is the whole update path on a Mac. On Linux, re-running `install.sh`
is.

## [0.2.1](https://github.com/psoldunov/skrepka/releases/tag/v0.2.1) — 2026-09-21

Linux gets a desktop app: a tray icon, the clipboard picker on a global
shortcut, and Settings, in one program. It also fixes the daemon going deaf
after its first answer, which left 0.2.0's Settings window and every later
`skrepka` command timing out.

### Added

- **`skrepka-gui`, one desktop app for Linux.** It holds the tray icon, the
  global shortcut, the picker and the Settings window in a single GTK4
  application, `dev.soldunov.Skrepka.App`. It replaces `skrepka-settings` and
  its "Skrepka Settings" launcher entry. It takes one option at most:
  - no option opens the picker;
  - `--picker` opens the picker, or closes it when it is open;
  - `--settings` opens Settings;
  - `--background` starts in the tray and shows nothing, which is what the
    autostart entry runs at login;
  - `--quit` quits the app. `skrepkad` keeps running and keeps recording.

  A second launch hands its option to the copy that is already running and
  exits, so the launcher, the tray and a shortcut never start two apps.
- **A clipboard picker on Linux.** It has the macOS layout: a search field,
  rows with a kind tile or an image thumbnail, a subtitle (type, size, lines,
  dimensions, how long ago), a pin glyph, Alt+1 to Alt+9 badges, the accent
  colour on the selection, key hints in the footer, a gear that opens Settings,
  and empty states with the paperclip mark. It follows the desktop's dark or
  light setting and its accent colour, read from the appearance portal. Search
  runs in the daemon over the whole text of every entry, not the first line.
  - **Return copies the entry to the clipboard and closes the picker.** You
    paste with Ctrl+V; Skrepka does not synthesise the keystroke
    ([D-11](docs/linux-sync/open-questions.md#d-11)). Alt+Return copies the
    rich form and Alt+Shift+Return plain text.
  - Alt+1 to Alt+9 choose that row, Alt+P pins or unpins, and Alt+Backspace or
    Alt+Delete deletes. Home, End, Page Up and Page Down move the selection,
    and Esc closes. Right-clicking a row offers Pin or Unpin, Copy as Plain
    Text and Delete.
  - The pointer selects a row only after it moves, so a picker that opens under
    a resting pointer does not steal the selection.
  - On KWin and sway it opens as a wlr-layer-shell overlay, which leaves the app
    underneath its caret. Where there is no layer-shell it falls back to an
    undecorated window kept above the others, centred on the pointer's monitor,
    with the keyboard grabbed. That fallback is for X11 sessions, which SteamOS
    before 3.8.10 uses in Desktop Mode. It has only been seen to map under Xvfb.
- **A global shortcut, Meta+Shift+V.** The app asks for it through the
  `org.freedesktop.portal.GlobalShortcuts` portal, mirroring ⌘⇧V on the Mac.
  The desktop asks you to confirm or change it the first time. Where there is no
  such portal, bind `skrepka-gui --picker` as a custom shortcut in the desktop's
  keyboard settings.
- **A tray icon.** A left click opens the picker, or closes it. The menu reads
  Open Skrepka, Clear History…, Settings… and Quit Skrepka. Clear History asks
  first and keeps pinned entries. When the daemon cannot be started, a row
  saying so sits at the top.
- **The daemon starts when something needs it.** The installer adds a D-Bus
  activation file, so any client call starts `skrepkad` through its systemd unit.
  The app also starts the daemon itself when the call finds it missing, by asking
  systemd for `skrepkad.service`, and shows the tray problem row when that fails.
- **`skrepka pin`, `unpin`, `delete`, `clear` and `copy --plain`.** They cover
  the same actions as the picker: `pin <n|hash>`, `unpin <n|hash>`,
  `delete <n|hash>`, `clear` for every unpinned entry and `clear --all` for
  every entry, and `copy --plain <n|hash>` for the plain-text form. The daemon's
  D-Bus interface is version 3, with `Search`, `CopyAs`, `SetPinned`, `Delete`,
  `Clear` and `Preview` members and the row fields the picker draws.
- **`install.sh` installs the app.** It adds `skrepka-gui`, a "Skrepka" launcher
  entry with a Settings action, an autostart entry that runs `--background`, the
  app icon at the hicolor sizes, a monochrome tray icon that follows the panel's
  text colour, and the D-Bus activation file. It removes the old
  `skrepka-settings` files, quits a running app before upgrading, and starts the
  app in the tray when it runs inside a graphical session. `--uninstall` removes
  all of it and still leaves your history and this device's sync identity.

### Changed

- **Settings opens from the tray, the picker's gear or the launcher's Settings
  action.** Its contents are the Sync pane 0.2.0 shipped, unchanged. It runs
  inside the app instead of as its own process.
- **`skrepka doctor` and the journal say why Avahi refused to publish.** A
  daemon that only reported `avahi refused EntryGroupNew` gave no way forward.
  The message now names the D-Bus error and, for the usual cause, says what to
  change. See the note under Fixed.

### Fixed

- **Universal Clipboard relays are no longer recorded as new copies.** A file or
  screenshot copied on one Mac no longer appears again when Universal Clipboard
  stages it on another Mac, and Sync no longer carries that relay back to the
  sender. The first sync startup also removes relays earlier builds left in
  history; peers discard and tombstone relays sent by older builds.
- **The picker returns to the top after it closes.** Reopening it no longer starts
  at the previous scroll position and then jumps while it resets the rows.
- **`skrepkad` answered one D-Bus call and then none.** The D-Bus library's send
  waits for a reply to every message it writes, including the method return the
  daemon sends back. That wait sat inside the connection's read loop, so the loop
  never read a second message. The first client got its answer; the Settings
  window and a second `skrepka` command then timed out. This affected 0.2.0.
  Replies are now written without waiting for anything.

### Known limitations

- **The tray, the shortcut and the picker have not been run on real KDE Plasma.**
  They are tested under a headless sway and against fake portals and a fake
  tray watcher on a private bus. The first Steam Deck session is still to come.
- **`could not publish the service: avahi refused EntryGroupNew…` means
  avahi-daemon is refusing services from user programs.** Its source refuses
  `EntryGroupNew` for exactly three reasons: `disable-user-service-publishing=yes`,
  too many clients, or too many objects for one client. On a daemon that has just
  started it is the first. Other devices cannot see this one while it lasts, so a
  Mac cannot dial it. The Linux device can still see and dial the Mac. To fix it,
  set `disable-user-service-publishing=no` under `[publish]` in
  `/etc/avahi/avahi-daemon.conf`, then run `sudo systemctl restart avahi-daemon`.
  On a Steam Deck `sudo` needs a password set with `passwd`. Whether an edit under
  `/etc` survives a SteamOS update is unverified.
- **`Failed to set thread priority for worker thread: pqc=… errno=13` in the
  journal is harmless.** Swift's libdispatch tries to lower a worker thread's nice
  value to imitate a quality-of-service class, and an unprivileged user service
  is not allowed to (`EACCES`). It happens once per process in any Swift program
  that uses Dispatch on Linux and changes nothing. It is left showing because
  `LIBDISPATCH_LOG=NO`, the switch that would hide it, hides libdispatch's
  assertion messages too.
- **Thumbnails of copied image files are not drawn.** An image copied as pixels
  gets its thumbnail. A file copied from a file manager still shows a kind tile.
- **Retention and exclusion settings are macOS only.** The Linux Settings window
  has the Sync pane and nothing else.

## [0.2.0](https://github.com/psoldunov/skrepka/releases/tag/v0.2.0) — 2026-09-18

Skrepka runs on Linux — as a preview — and a Linux box can share clipboard
history with a Mac.

### Added

- **A Linux daemon and CLI, as a preview.** `skrepkad` keeps clipboard history
  on Linux the way the Mac app does. It is a systemd user service. It records
  what you copy and skips anything a password manager marks secret with
  `x-kde-passwordManagerHint`, which KeePassXC and `wl-copy --sensitive` set.
  It syncs with paired devices over the same protocol as the Mac, with the same
  TLS 1.3 pinning and the same on-screen code. `skrepka` drives it from a
  terminal: `list`, `copy`, `pair`, `peers`, `sync`, `unpair` and `doctor`.
  - It reads and writes the clipboard on Wayland, through the wlroots and `ext`
    data-control protocols, and on X11.
  - The wlroots and X11 backends are tested against a headless Sway and Xvfb,
    not only in unit tests.
  - There is no Linux picker yet. `skrepka copy` puts an entry back on the
    clipboard.
- **A Settings window on Linux.** `skrepka-settings` is a GTK4 window, listed in
  the launcher as "Skrepka Settings", and mirrors the Mac's Sync pane:
  - this device's name and code;
  - the "Allow new devices to pair" switch;
  - every paired and sighted device, with Pair…, Unpair, Sync Now and a
    per-device live-clipboard switch;
  - a pairing dialog that works in both directions.

  It needs GTK 4.12 or newer.
- **One command installs Skrepka on Linux.** In a terminal on the machine
  itself — Konsole in the Steam Deck's Desktop Mode, for one — run:

  ```sh
  curl -fsSL https://raw.githubusercontent.com/psoldunov/skrepka/master/install.sh | bash
  ```

  This downloads the x86_64 build from the latest release, checks it against
  the published SHA-256 and installs it under `~/.local`. It also installs a
  systemd user unit and a launcher entry, and starts the daemon. It needs no
  root, and SteamOS's read-only system is left untouched. `--version` pins a
  release, and `--uninstall` removes everything except your history and this
  device's sync identity. Building from a checkout is now
  `scripts/setup-linux.sh`.

### Fixed

- **An image that arrives from a paired device shows as a picture.** A synced
  screenshot drew as a kind symbol on a text-height row, because no thumbnail
  crosses the wire and none was drawn on arrival. Skrepka now renders one from
  the bytes that came with it, off the main thread, for rows learned whole and
  rows filled in by a later fetch. A rich-text or link clipping that happens to
  carry a PNG still draws no picture, the same as it does locally.
- **A live push no longer echoes back.** With three devices, a push could
  return to its sender as a fresh copy and overwrite a newer clipboard with
  older content. Three changes close that loop:
  - A Mac writes a received push for this Mac only, so Universal Clipboard
    never relays it to another Mac.
  - A Linux daemon recognises its own write when the compositor or X server
    reports it back.
  - A hash a peer just sent is refused until something else is copied, with no
    time limit.

### Known limitations

- **Linux has not been run on real hardware yet.** Everything above is tested
  in containers against headless compositors. The first session on a Steam Deck
  — KDE Plasma on Wayland — is still to come. Treat Mac-to-Linux sync as a
  preview and [report](https://github.com/psoldunov/skrepka/issues) what
  breaks.
- **The Linux daemon has sync on unless it is started with `--no-sync`.** It
  advertises itself on the local network from the first run. A new device still
  cannot pair without the pairing window opened and the code confirmed on both
  screens.
- **The Linux build is x86_64 only.** On other architectures, clone the
  repository and run `scripts/setup-linux.sh` to build from source.

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
