# Steam Deck bring-up: first hardware session

**Amended 2026-09-22:** the first session ran on 2026-09-21, against 0.2.1;
its findings and fixes are in
[phase-7-linux-gui.md](phase-7-linux-gui.md#first-steam-deck-session-2026-09-21).
The checklist below stays the template for the next one.

**Status, 2026-09-18: deferred.** The owner put Linux hardware testing on hold
the day this checklist was written. It is ready to run as it stands. Since 0.2.0
the Deck installs straight from a GitHub release, so no ssh and no copy from
the Mac are needed. When testing resumes and master has moved past the latest
release, cut a release first (or see section 1's fallback) so the Deck gets
whatever landed in between.

The Deck OLED is the [D-10](open-questions.md#d-10) test rig. Everything Skrepka
built on Linux so far — Phase 5's clipboard backends, Phase 6's daemon and CLI,
Phase 7's desktop app (tray, picker, shortcut and Settings) — has only been
exercised inside a container against a headless sway. This is the checklist for the first run on a real KDE Plasma 6.4
session, with a real Mac at the other end.

Two hours if nothing blocks, an afternoon if something does.

## Read this first — two things that could stop the session

**Pairing needs Avahi.** The daemon turns a peer into an address through
`AvahiDiscovery.resolve(peer)`
([`Sources/SkrepkaDaemon/Daemon+Actions.swift`](../../Sources/SkrepkaDaemon/Daemon+Actions.swift)),
and there is **no connect-by-address fallback**. Valve's own
[list of SteamOS services](https://github.com/ValveSoftware/SteamOS/wiki/List-of-SteamOS-services)
has `avahi-daemon.service` enabled, so this should hold. Step 0.4 confirms it.
If it does not, stop at section 3 and record it: the fix is an `--address`
flag on `skrepka pair`, a code change of an hour or two.

**The binaries need glibc 2.38 or newer.** That floor comes from the Swift
runtime linked into them, and `runtime-report.txt` records it per binary.
SteamOS 3.0 shipped glibc 2.33. Newer releases are reported to carry 2.41, but
that is **unverified**, so step 0.5 checks it. If the Deck's glibc is older,
nothing will start. The fix then is building in an older image, not anything
on the Deck.

### Two journal lines you may meet

Neither stops the session on its own. Both are worth recognising before the
first `journalctl`.

- **`avahi refuses to publish, so skrepkad publishes this device itself`** is
  expected on a Deck, and not a problem. SteamOS's avahi is built to publish
  nothing — `disable-publishing=yes` and `disable-user-service-publishing=yes`
  in `/etc/avahi/avahi-daemon.conf`, found in the first session — so skrepkad
  answers mDNS for its own service instead, and logs `answering mDNS` once per
  network interface. `skrepka doctor` names the responder as "avahi for
  browsing, skrepkad for publishing". Nothing under `/etc` needs changing. Check
  it from the Mac with `dns-sd -B _skrepka._tcp local`: the Deck should be
  listed.
- **`Failed to set thread priority for worker thread: pqc=… errno=13`** is
  benign. Swift's libdispatch (`_dispatch_worker_thread` in `src/queue.c`) tries
  to renice a worker thread to imitate a quality-of-service class, and an
  unprivileged user unit may not lower its nice value (`EACCES`). It appears once
  per process in any Swift program that uses Dispatch on Linux and changes no
  behaviour. It is left in place because `LIBDISPATCH_LOG=NO` would also hide
  libdispatch's assertion messages. Do not record it as a finding.

## 0. Deck prep — 20 minutes

The Deck's storage root is read-only and the session is not the graphical shell
you install into. All of these run from Desktop Mode's Konsole.

1. Hold **Steam → Power → Switch to Desktop**. In Desktop Mode, open Konsole.
2. Nothing to do for the install itself: it needs no password, no `sudo` and
   no ssh.
3. *Optional.* Enable ssh, only if you want to drive section 3 from the Mac's
   terminal: `passwd` to set a user password, `sudo systemctl enable --now
   sshd`, then `ip -4 addr | grep inet` for the address.
   - **Pass:** `ss -ltn | grep :22` shows a listener.
4. Check Avahi is running: `systemctl is-active avahi-daemon`.
   - **Pass:** it prints `active`.
   - **Fail:** anything else — `inactive`, `failed`. Stop at step 3 of section
     3 and record the state.
5. Check glibc, then the libraries: `ldd --version | head -1`, then
   `ldconfig -p | grep <soname>` for each `.so` line in
   `runtime-report.txt` — it ships inside the tarball, so do this after
   section 1's download. `libgtk4-layer-shell.so.0` is expected to be missing,
   because the tarball bundles it.
   - **Pass:** glibc is 2.38 or newer, and every other soname resolves to a path.

## 1. Download and install — 5 minutes

All on the Deck, in Konsole. The tarballs are downloaded and kept, rather
than installed with the one-line `curl … | bash`, for two reasons:
- Sections 2 and 4 run the probe and the palette demo, which ship in the
  release's second asset, `skrepka-linux-x86_64-tools.tar.gz`.
- Step 0.5 reads the `runtime-report.txt` in the main one.

Both unpack into `skrepka-linux-x86_64/`, so every `./bin/…` below runs from
that one directory.

1. Download both tarballs and their checksums, and check them:

   ```
   base=https://github.com/psoldunov/skrepka/releases/latest/download
   for f in skrepka-linux-x86_64.tar.gz skrepka-linux-x86_64-tools.tar.gz; do
     curl -fLO "$base/$f" && curl -fLO "$base/$f.sha256"
   done
   sha256sum -c skrepka-linux-x86_64.tar.gz.sha256 skrepka-linux-x86_64-tools.tar.gz.sha256
   ```

   - **Pass:** both lines end in `OK`.
2. `tar xzf skrepka-linux-x86_64.tar.gz && tar xzf skrepka-linux-x86_64-tools.tar.gz && cd skrepka-linux-x86_64 && ./install.sh`.
   Run from inside the untarred directory, `install.sh` installs that build and
   downloads nothing.
   - **Pass:** it prints the daemon's version and exits without an `error:`
     line. It ends by listing `skrepka --help` and the two `systemctl` /
     `journalctl` commands.
   - A yellow `⚠ … is not on your $PATH` is expected on a fresh Deck; follow
     what it prints.
   - It also installs the desktop app, `skrepka-gui`, with a private copy of
     `libgtk4-layer-shell` in `~/.local/lib/skrepka`, a "Skrepka" launcher entry
     with a Settings action, an autostart entry, the app icon, the tray icon and
     a D-Bus activation file for the daemon. There is no separate "Skrepka
     Settings" launcher any more. Sections 4 and 5 use the app.
   - Inside Desktop Mode's graphical session it starts the app in the tray as
     its last step.
   - A yellow `⚠ … cannot find:` line means a shared library the app needs is
     missing; record it.
   - **Fail:** `skrepkad from this build cannot run on this machine` means the
     glibc floor in "Read this first" is not met. Record the loader's message
     it prints.
3. `systemctl --user status skrepkad` shows `active (running)`.
   - **Pass:** the status is `active`; the journal has no repeated
     `on-failure` restarts.
4. Look at the system tray in Desktop Mode's panel.
   - **Pass:** a Skrepka paperclip icon is there, drawn in the panel's text
     colour, and a right click shows Open Skrepka, Clear History…, Settings… and
     Quit Skrepka. There is no problem row at the top.
   - **Finding, not a failure:** no icon — what the first session saw, although
     the same build shows its icon in the Plasma 6.4.3 container
     (`scripts/kde-smoke.sh`). Record the output of `skrepka-gui --status` (its
     `tray:` line says whether the StatusNotifierWatcher accepted the icon) and
     `journalctl --user -t skrepka-gui -b`.

**When master is ahead of the latest release,** build on the Mac with
`scripts/build-deck.sh` and carry both tarballs in `build/deck/` over any way
you like: a USB stick, a file share, or `scp` if you enabled ssh in
0.3. Then continue from step 2. `./install.sh --tarball FILE` also installs a
tarball without untarring it first, checking `FILE.sha256` when it sits beside
it.

## 2. Clipboard probe on Plasma 6.4 — 15 minutes

This is the first live run of `ExtDataControlBinding` against KWin —
[OQ-4](open-questions.md#oq-4). The daemon does not run this probe; the
standalone `skrepka-clip-probe` binary does. Stop `skrepkad` for this section
so both binaries do not fight over the clipboard. Quit the app first: with the
D-Bus activation file installed, the app or any `skrepka` command starts the
daemon again on its next call.

1. `skrepka-gui --quit`, then `systemctl --user stop skrepkad`.
2. `./bin/skrepka-clip-probe report` — prints the session and the backend it
   picked.
   - **Pass:** `backend:  Wayland (ext-data-control-v1)`. Plasma 6.4 advertises
     both protocols and `SessionProbe` prefers this one.
   - **Finding, not a failure:** `backend:  Wayland (wlr-data-control,
     deprecated)` means KWin did not offer `ext` on this build. Record it.
   - **Fail:** `backend:  none` with a `problem:` line. That is Phase 5's
     "cannot reach the clipboard on KDE" case, and it blocks everything else.
3. `./bin/skrepka-clip-probe watch &`, then copy something in Firefox / Dolphin /
   Konsole in turn.
   - **Pass:** each copy prints a line naming its MIME types and payload size.
4. `./bin/skrepka-clip-probe copy "hello from skrepka"` — puts the string on
   the clipboard and stays in the foreground, printing `serving … targets — ^C
   to release the selection`. On Wayland the bytes live in the process that
   offered them, so it has to keep running for a paste to work.
   - **Pass:** while it runs, any other app can paste `hello from skrepka` with
     Ctrl+V. Then press Ctrl+C.
5. `kill %1` to stop the watcher, then `systemctl --user start skrepkad` and
   start the app again with `skrepka-gui --background`.

## 3. Daemon and pairing with the Mac — 30 minutes

The Mac side runs Skrepka.app from `scripts/run.sh`. If you enabled ssh in
step 0.3, driving the Deck from the Mac keeps both terminals visible — all but
step 5, which cuts the network and the ssh session with it. Konsole on the Deck
works just as well.

1. On the Mac: `scripts/run.sh`. Confirm the menu-bar icon is present.
2. On the Deck: `skrepka doctor`, then `skrepka peers`.
   - **Pass:** `doctor`'s `peers` line reads `0 paired, 1 in sight` once the
     Mac has advertised itself (allow ~10 s), and `peers` lists the Mac under
     `ON THE NETWORK`.
   - **Fail (nothing in sight):** check `journalctl --user -u skrepkad -f` for
     `avahi` errors. This is the Avahi blocker from the top note. If the line is
     `could not publish the service: avahi refused EntryGroupNew…`, see "Two
     journal lines you may meet" above.
3. On the Deck: `skrepka pair`, which opens the Deck to pairing for a while.
   On the Mac: Settings → Sync → the Deck's row → **Pair…**. Compare the code
   on both screens. It is 16 characters in groups of four. Confirm on both.
   - **Pass:** the codes match, the Deck prints `Paired.`, and the Mac's row
     shows the Deck as paired.
4. Walk all nine items of the Phase 6 "Done when" list
   ([phase-6-linux-daemon.md](phase-6-linux-daemon.md#done-when)), marking
   each pass or fail under its number there:
   1. **Discover and pair with matching codes** — steps 2 and 3 above.
   2. **History both ways, pins and deletes included.** Copy on the Mac and
      find it in `skrepka list`; copy in Kate and find it in the Mac's history.
      Then pin one entry on the Mac and delete another there. **Pass:** the
      pinned one is marked `*` in `skrepka list` and the deleted one is gone.
      Then do the reverse from the Deck with `skrepka pin <n>` and
      `skrepka delete <n>`, and look for the pin and the deletion in the Mac's
      history.
   3. **Live push both ways, on by default.** The copies in item 2 arrive
      within a few seconds without anyone running `skrepka sync`.
   4. **Retention stays local.** On the Mac, open Settings → History and set
      **Keep at most** below the number of entries the Deck holds (100 is the
      smallest choice; **Discard after** works too), so the Mac drops its
      oldest. **Pass:** `skrepka list --limit 1000` on the Deck still shows
      them. Put the setting back afterwards.
   5. **Concealed content does not cross.** Copy a password from a password
      manager on the Mac. **Pass:** it never appears in `skrepka list`.
   6. **A network cut resumes rather than corrupts** — step 5 below. The cut
      is made by hand and not timed to land mid-transfer, so record this item
      as partly covered.
   7. **`systemctl --user restart skrepkad` reconnects without re-pairing.**
      **Pass:** `skrepka peers` still lists the Mac as paired, and a copy on
      either side still arrives on the other.
   8. **`skrepka doctor` tells the truth when something is wrong** — step 5
      below breaks the network on purpose and reads `doctor` while it is
      broken.
   9. **The daemon survives the compositor restarting under it.** Switch to
      Game Mode, then back to Desktop Mode as in step 0.1 — the KWin session
      ends and a new one starts — and touch nothing else. **Pass:** a copy in
      Kate reaches `skrepka list`, and `skrepka doctor` names a backend. A
      `restarts` line in `doctor` means the daemon survived and rebuilt its
      session. Without one, `systemctl --user status skrepkad` shows whether
      systemd started a new daemon instead. Record which happened.
5. Break the network on purpose. Do this step from the Deck's own Konsole, not
   over ssh, because it cuts the ssh session. Turn the Deck's Wi-Fi off (it has
   no Ethernet port without a dock), copy something on each side, and run
   `skrepka doctor`. Wait 30 s, then turn Wi-Fi back on.
   - **Pass, while offline:** `doctor` has a `PROBLEMS` section that says so.
     The daemon has two lines that fit, and which one appears depends on how
     Avahi reacts to losing its interface, which is unverified: `Paired but
     not on the network right now: <fingerprint>`, or `This device is not
     published on the local network…`.
   - **Pass, after:** both copies are present on both sides within ~15 s of
     Wi-Fi returning, with no `skrepka sync` and no re-pairing.

## 4. Picker, shortcut and tray on KWin — 30 minutes

Phase 7's real picker, against the daemon's real history. The app must be
running (`skrepka-gui --background` if section 2 left it quit) and `skrepkad`
with it. Copy a few things first, in Kate and Firefox, so the picker has rows.

1. Open Kate and start typing a sentence; leave the caret in the middle of a
   word.
2. Press **Meta+Shift+V**. The first time the app starts, Plasma shows a
   "Global Shortcuts Requested" dialog for Skrepka — accept Meta+Shift+V. The
   shortcut runs through `org.freedesktop.portal.GlobalShortcuts`, id
   `show-picker`. 0.2.1 never got this far: see the first session's findings in
   [phase-7-linux-gui.md](phase-7-linux-gui.md#first-steam-deck-session-2026-09-21).
   - **Pass:** the picker appears centred across the screen with its top 18% of
     the way down, over Kate, in the desktop's dark or light setting and accent
     colour, with a shadow that fades out. Kate loses keyboard focus but keeps
     its caret and its text. `skrepka-gui --status` reads `shortcut: bound to
     Meta+Shift+V`.
   - **Fail:** no dialog and no picker. Record `skrepka-gui --status` — its
     `shortcut:` and `app ID:` lines say what the portal answered — and run
     `skrepka-gui --picker` in Konsole to see whether the picker itself works.
   - **Fallback, not a failure:** if Plasma has no working portal, bind
     `skrepka-gui --picker` as a custom shortcut in System Settings → Keyboard →
     Shortcuts, and record that.
3. Type `br` without clicking first.
   - **Pass:** the first keystroke lands in the search field, and the rows
     narrow to entries containing it — anywhere in their text, not only the first
     line.
4. Press Down, Down, then Return.
   - **Pass:** the picker closes, and Kate has keyboard focus back with its text
     unchanged. The chosen entry is now on the clipboard: Ctrl+V pastes it into
     Kate. Skrepka does not paste for you
     ([D-11](open-questions.md#d-11)).
5. Reopen the picker and check the rest of the keys: Alt+1 chooses the first
   row, Alt+P pins the selected row, Alt+Backspace deletes it, Alt+Shift+Return
   copies plain text, and Esc closes. Right-click a row for Pin, Copy as Plain
   Text and Delete.
   - **Pass:** each does what it says. A pinned row shows the pin glyph and sorts
     first.
   - Then click anywhere outside the picker, and separately switch to Kate with
     Alt+Tab while it is open. **Pass:** either closes it, as on the Mac. The
     click itself does not reach the window under it.
6. Click the tray icon.
   - **Pass:** the picker opens, and a second click closes it.
7. Open the picker and click the gear.
   - **Pass:** the Settings window opens. Section 5 uses it.
8. Check the empty and image states: copy a screenshot, and look at its row.
   Then copy a PNG or JPEG file in Dolphin — a phone photo taken upright, if
   there is one.
   - **Pass:** both rows show a thumbnail. The Dolphin copy's row says Image and
     gives the picture's size, and the photo is the right way up. A `.webp`
     says Image with the picture symbol in place of the picture, because
     SteamOS's GdkPixbuf has no WebP loader; a `.heic` stays a File.

### Alternative: the palette demo

The tools tarball still ships `skrepka-palette-demo`, a hand-driven bring-up
binary — canned rows, no history store, no hotkey — that opens a
`PaletteWindow` against whatever session is running and prints every key
command to stdout. It isolates the layer-shell question from the portal and the
daemon, so it is the thing to run if steps 2 to 4 fail and you want to know
which layer broke. See its file for what it is not.

1. Open a text editor (Kate) and start typing a sentence; leave the caret in
   the middle of a word.
2. In another Konsole tab, `./bin/skrepka-palette-demo`.
   - **Pass:** it prints `layer-shell available: true`, and the palette
     appears centred over Kate. Kate loses keyboard focus but keeps its caret
     and its text.
   - **Fail:** `layer-shell available: false`, then an error saying the desktop
     does not offer wlr-layer-shell. KWin's layer-shell support was inferred
     from reading its source, so a live rejection here is the finding to record.
3. Type `br` into the palette (do not click first) — the first keystroke
   should land in the search field.
   - **Pass:** the palette's terminal prints `query: br`.
4. Press Down, Down, Return.
   - **Pass:** the terminal prints `command: moveSelection(by: 1)` twice, then
     a `command: choose(…)` line naming the rich style. The palette closes, and
     Kate gets keyboard focus back with its text unchanged. The demo has canned
     rows and writes nothing to the clipboard. Under
     [D-11](open-questions.md#d-11) the real picker does, as in the steps above,
     and you paste with Ctrl+V.
5. Reopen and hit Escape.
   - **Pass:** `command: dismiss`, palette closes.

## 5. Settings window on KWin — 20 minutes

Settings is the GTK4 window for pairing, unpairing and managing the devices
Skrepka shares history with. It lives inside `skrepka-gui` and talks to the
running `skrepkad`, so the app and the daemon must both be up if section 2 left
them stopped. It picks up where section 3 ended: the Mac is paired.

1. Open Settings from the tray menu (**Settings…**), from the picker's gear, or
   from the launcher entry's Settings action. `skrepka-gui --settings` in
   Konsole does the same.
   - **Pass:** the window opens, shows this device's name and code, and lists
     the Mac as paired. Opening it a second way raises the same window rather
     than opening another.
2. Unpair the Mac from the window: click **Unpair** on its row, then **Unpair**
   again in the "Forget <name>?" dialog. Then, on the Mac, forget the Deck too.
   - **Pass:** the Mac stays in the window's one "Devices" list, now with the
     subtitle "On this network — <fingerprint>", and the Mac's Settings → Sync
     no longer lists the Deck as paired.
3. Deck dials. On the Mac, turn on "Allow new devices to pair". On the Deck,
   click **Pair…** on the Mac's row. Compare the code on both screens and
   click **Codes Match — Pair** on both.
   - **Pass:** the codes match and both sides show the other as paired.
4. Mac dials. Forget on both sides again. Turn on "Allow new devices to pair"
   on the Deck, then click **Pair…** on the Deck's row in the Mac's Settings →
   Sync. Do not touch the Deck's window.
   - **Pass:** the Deck's window shows the pairing dialog on its own; the codes
     match and you click **Codes Match — Pair** on the Deck and confirm on the
     Mac; both sides show paired; and the Deck's "Allow new devices to pair"
     switch turns itself off after the pairing.
5. Live clipboard switch. In the window, turn the live clipboard off for the
   Mac. Copy something in Kate.
   - **Pass:** the Mac's clipboard does not change immediately, and the entry
     appears in the Mac's history on the next half-minute exchange (about 30 s).
     Turn the switch back on afterwards.
6. Press **Sync Now**.
   - **Pass:** the window shows a confirmation banner, e.g. "Asked 1 peer to
     sync."
7. With the window still open, `systemctl --user stop skrepkad`. Do not start it
   again by hand.
   - **Pass:** the app or the bus starts the daemon again on the next call, so
     the window recovers by itself without being reopened, and
     `systemctl --user status skrepkad` shows `active (running)` again. A brief
     "The Skrepka daemon is not running." in between is fine.
   - **Finding:** the window stays on that message, or the tray's problem row
     appears and stays. Record the row's text and `journalctl --user -u skrepkad`
     for the same minute. Then start the daemon by hand.

## 6. Record findings — 10 minutes

Everything above answers an open question or moves a phase closer to done.
Write results into these files, in this order:

1. **[`open-questions.md`](open-questions.md)** — the outcome of OQ-4
   (KDE `ext-data-control-manager-v1`) and, if Avahi is missing, a new open
   question for the pairing fallback. If Avahi is present, note it as
   confirmed under D-10.
2. **[`phase-6-linux-daemon.md`](phase-6-linux-daemon.md)** — the "Done when"
   list, item by item, with the actual behaviour observed.
3. **[`phase-7-linux-gui.md`](phase-7-linux-gui.md)** — replace "**Not
   demonstrated: KDE.**" with the actual result of section 4, and update D-4's
   provisional exit condition to settled or reverted. Put the shortcut, tray and
   Settings results (sections 3 to 5) in the same file, next to the picker
   result.
4. Attach the `runtime-report.txt` from the tarball to whichever finding
   depends on it — a Deck-side glibc mismatch belongs beside the finding it
   caused, not on its own.

Do not commit `steam-deck-session.md` edits with the outcomes inside. This
file is the checklist template; findings go in the files above.
