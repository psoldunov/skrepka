# Steam Deck bring-up: first hardware session

**Status, 2026-09-18: deferred.** The owner put Linux hardware testing on hold
the day this checklist was written. It is ready to run as it stands. When
testing resumes, rebuild the tarball first (`scripts/build-deck.sh`) so it
carries whatever landed in between.

The Deck OLED is the [D-10](open-questions.md#d-10) test rig. Everything Skrepka
built on Linux so far — Phase 5's clipboard backends, Phase 6's daemon and CLI,
Phase 7's palette and Settings window — has only been exercised inside a container against a
headless sway. This is the checklist for the first run on a real KDE Plasma 6.4
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

## 0. Deck prep — 20 minutes

The Deck's storage root is read-only and the session is not the graphical shell
you install into. All of these run from Desktop Mode's Konsole.

1. Hold **Steam → Power → Switch to Desktop**. In Desktop Mode, open Konsole.
2. Set a user password so `sudo` and `sshd` work: `passwd`.
   - **Pass:** `passwd: password updated successfully`.
3. Enable ssh for the copy step:
   `sudo systemctl enable --now sshd`, then `ip -4 addr | grep inet` for the
   address to scp to.
   - **Pass:** `ss -ltn | grep :22` shows a listener.
4. Check Avahi is running: `systemctl is-active avahi-daemon`.
   - **Pass:** it prints `active`.
   - **Fail:** anything else — `inactive`, `failed`. Stop at step 3 of section
     3 and record the state.
5. Check glibc, then the libraries: `ldd --version | head -1`, then
   `ldconfig -p | grep <soname>` for each `.so` line in the tarball's
   `runtime-report.txt`. `libgtk4-layer-shell.so.0` is expected to be missing,
   because the tarball bundles it.
   - **Pass:** glibc is 2.38 or newer, and every other soname resolves to a path.

## 1. Copy and install — 5 minutes

From the Mac, in the Skrepka worktree that produced the tarball:

1. `scripts/build-deck.sh` — produces `build/deck/skrepka-linux-x86_64.tar.gz`
   and `build/deck/runtime-report.txt`. See the report before copying;
   `runtime-report.txt` is the only source of truth for which glibc floor the
   tarball assumes.
2. `scp build/deck/skrepka-linux-x86_64.tar.gz deck@<deck-ip>:~/`.
3. On the Deck:
   `tar xzf skrepka-linux-x86_64.tar.gz && cd skrepka-linux-x86_64 && ./scripts/install.sh --from-build ./bin`.
   - **Pass:** it exits without an `error:` line and ends by listing
     `skrepka --help` and the two `systemctl` / `journalctl` commands. A yellow
     `⚠ … is not on your $PATH` is expected on a fresh Deck; follow what it
     prints. It also installs `skrepka-settings` with a private copy of
     `libgtk4-layer-shell` in `~/.local/lib/skrepka` and a "Skrepka Settings"
     launcher entry, which section 5 uses. A yellow `⚠ … cannot find:` line
     means a shared library the Settings window needs is missing; record it.
4. `systemctl --user status skrepkad` shows `active (running)`.
   - **Pass:** the status is `active`; the journal has no repeated
     `on-failure` restarts.

## 2. Clipboard probe on Plasma 6.4 — 15 minutes

This is the first live run of `ExtDataControlBinding` against KWin —
[OQ-4](open-questions.md#oq-4). The daemon does not run this probe; the
standalone `skrepka-clip-probe` binary does. Stop `skrepkad` for this section
so both binaries do not fight over the clipboard.

1. `systemctl --user stop skrepkad`.
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
5. `kill %1` to stop the watcher, then `systemctl --user start skrepkad`.

## 3. Daemon and pairing with the Mac — 30 minutes

The Mac side runs Skrepka.app from `scripts/run.sh`. Do this section over ssh
from the Mac so both terminals are visible — all but step 5, which cuts the
network and the ssh session with it.

1. On the Mac: `scripts/run.sh`. Confirm the menu-bar icon is present.
2. On the Deck: `skrepka doctor`, then `skrepka peers`.
   - **Pass:** `doctor`'s `peers` line reads `0 paired, 1 in sight` once the
     Mac has advertised itself (allow ~10 s), and `peers` lists the Mac under
     `ON THE NETWORK`.
   - **Fail (nothing in sight):** check `journalctl --user -u skrepkad -f` for
     `avahi` errors. This is the Avahi blocker from the top note.
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
      The CLI has no pin or delete verb, so this half runs Mac → Deck only;
      record it that way.
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

## 4. Palette on KWin — 20 minutes

Phase 7 step 1 validation. `skrepka-palette-demo` is a hand-driven bring-up
binary — canned rows, no history store, no hotkey — that opens a
`PaletteWindow` against whatever session is running and prints every key
command to stdout. See its file for what it is not.

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
     [D-11](open-questions.md#d-11) the real picker will, and you will paste
     with Ctrl+V.
5. Reopen and hit Escape.
   - **Pass:** `command: dismiss`, palette closes.

## 5. Settings window on KWin — 20 minutes

`skrepka-settings` is the GTK4 window for pairing, unpairing and managing the
devices Skrepka shares history with. It talks to the running `skrepkad`, so
start the daemon again first if section 2 left it stopped. It picks up where
section 3 ended: the Mac is paired.

1. Launch "Skrepka Settings" from the application launcher, or run
   `skrepka-settings` in Konsole (`./bin/skrepka-settings` from the untarred
   tarball also works).
   - **Pass:** the window opens, shows this device's name and code, and lists
     the Mac as paired.
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
7. `systemctl --user stop skrepkad`, then, with the window still open,
   `systemctl --user start skrepkad`.
   - **Pass, while stopped:** within a few seconds the window says "The Skrepka
     daemon is not running." and "Start it with: systemctl --user start
     skrepkad".
   - **Pass, after:** it recovers without being reopened.

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
   provisional exit condition to settled or reverted. Put the Settings window
   results from section 5 in the same file, next to the palette result.
4. Attach the `runtime-report.txt` from the tarball to whichever finding
   depends on it — a Deck-side glibc mismatch belongs beside the finding it
   caused, not on its own.

Do not commit `steam-deck-session.md` edits with the outcomes inside. This
file is the checklist template; findings go in the files above.
