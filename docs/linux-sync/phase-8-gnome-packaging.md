# Phase 8 — GNOME support, packaging, and the installer

**A week of work, plus review latency nobody controls.**

## Goal

A package that installs on Ubuntu and Fedora, starts under systemd, pairs with
the Mac from a clean install — and works on GNOME. Plus a **user-scope
installer** for every machine a package cannot reach, which includes the one
this project actually tests on.

## Preconditions

- Phase 7 done, or deliberately skipped in favour of the CLI.
- [D-5](open-questions.md#d-5) is settled: **ship the extension, kept as thin as
  possible.** GNOME is the most common Linux desktop and excluding it excludes
  most of the audience, so the second JavaScript codebase and its review queue
  are an accepted standing cost rather than an open question.
- [OQ-3](open-questions.md#oq-3) answered if the portal path is being
  reconsidered at all.
- [D-10](open-questions.md#d-10) is settled, and it splits this phase's
  verification in two. **The GNOME half is built now and tested later**: the
  extension gets written, kept thin and submitted on schedule, but no GNOME row
  of the test matrix below can be run until GNOME hardware exists. **The
  installer half is testable today**, on the Steam Deck, which is an immutable
  distribution and therefore the strictest case the installer will meet.

## Why GNOME needs its own phase

GNOME/Mutter implements **neither** `ext-data-control-v1` nor
`wlr-data-control`. This was verified directly rather than inferred: Mutter's
`src/meson.build` on `main` enumerates its Wayland protocols, and it contains
zero occurrences of `data-control`. There is no external-client path, and no
amount of Phase 5 work changes that.

Three answers exist and real clipboard managers use all three:

1. **Run inside gnome-shell.** GPaste's privileged backend talks to Mutter's
   server-side selection tracker directly, reachable only from inside the
   gnome-shell process. Its own source notes this sees every selection change
   globally with no focus gating — unlike a plain `GdkClipboard` client, which
   *is* focus-gated on Wayland.
2. **Ship a GNOME Shell extension.** CopyQ does this. A second codebase, plus
   extensions.gnome.org review.
3. **Fall back to XWayland** (`QT_QPA_PLATFORM=xcb`), which CopyQ documents as
   lossy.

There is a fourth, uglier path: `org.freedesktop.portal.Clipboard` exists and
`xdg-desktop-portal-gnome` implements it, but the interface cannot open its own
session — it only extends a **RemoteDesktop** or **InputCapture** session. So
clipboard monitoring through the portal means holding an open remote-desktop
grant, and probably a persistent screen-sharing indicator
([OQ-3](open-questions.md#oq-3)). Assume it does until someone checks.

**Option 2 is the decision** ([D-5](open-questions.md#d-5)), with option 3 as
the documented fallback for anyone who will not install an extension.

**"Thin" needs enforcing rather than intending.** Anything that ends up in
`extension.js` and could have lived in the daemon is a future GNOME release's
breakage, bought voluntarily. The line: the extension forwards selection changes
over D-Bus and accepts set-selection calls back. Everything else — capture
rules, privacy markers, de-duplication, retention — stays in `SkrepkaCore`.

## Deliverables

```
gnome-extension/
  metadata.json
  extension.js
  dbus.js                       # client for dev.soldunov.Skrepka
  README.md

packaging/
  debian/{control,rules,changelog,skrepka.install}
  rpm/skrepka.spec
  systemd/skrepkad.service      # from Phase 6
  install.sh                    # the user-scope installer, curl-able
  uninstall.sh
  desktop/dev.soldunov.Skrepka.desktop
  desktop/dev.soldunov.Skrepka.Settings.desktop
  README.md                     # why not Flatpak — see below
```

## Work

### 0. The user-scope installer

`packaging/install.sh`, fetched with `curl` and run without `sudo`. It writes
only inside `$HOME` and it is the only way a build reaches an immutable
distribution.

**Why it exists.** SteamOS — the test rig ([D-10](open-questions.md#d-10)), and
the same shape as Fedora Silverblue, Bazzite and every other atomic desktop —
has a read-only root. `steamos-readonly disable` is undone by the next atomic
update, and with systemd-sysext extensions merged `/usr` stays read-only even
after disabling it. `.deb` and `.rpm` have nowhere to land there. `/home`
survives updates, so `$HOME` is the whole target.

It is **not Deck-specific and must not be written as if it were**. It is the
no-root install path for any distribution, including the ones nobody packages
for, and after Phase 6 a headless daemon plus a CLI in `~/.local` is a
legitimate way to ship.

**Where things go**, following the XDG base directories and systemd's
`file-hierarchy(7)` — and reusing `SessionPaths` from
[Phase 6](phase-6-linux-daemon.md) rather than restating its rules in shell:

| What | Path |
|---|---|
| `skrepkad`, `skrepka`, the GUI if Phase 7 shipped | `~/.local/bin/` |
| Desktop entries | `$XDG_DATA_HOME/applications/`, default `~/.local/share/applications/` |
| Icons | `$XDG_DATA_HOME/icons/hicolor/…/apps/`, from the same `scripts/paperclip.svg` the Mac icon comes from |
| systemd user unit | `$XDG_CONFIG_HOME/systemd/user/skrepkad.service` |
| History, keys | whatever `SessionPaths` already decided — the installer never invents a data path |

Desktop entries are the deliverable the packages and the installer share: one
for the picker, one for Settings, `NoDisplay=true` on anything that should not
appear in the launcher. Run `update-desktop-database` against the user
applications directory afterwards, and `gtk-update-icon-cache` against the icon
theme directory, so the entries appear without a re-login.

**Autostart is the systemd user unit, not an `~/.config/autostart` entry.**
Picking both is how an app ends up running twice. `systemctl --user enable --now
skrepkad` after install, and say so in the output.

Rules the script has to follow:

- **Re-runnable.** Running it again upgrades in place and never duplicates a
  unit, an entry or a PATH line. Upgrade must preserve history and pairings —
  the same requirement the package upgrade row of the test matrix carries.
- **Architecture from `uname -m`**, mapping to the release asset. `x86_64` and
  `aarch64`; anything else exits with a message rather than downloading
  something that will not run.
- **Verify what it downloaded** against a published checksum before it is made
  executable, and support pinning a version rather than always taking latest. A
  `curl | sh` that cannot be pinned or verified is not something to ask users to
  run, and the same script must work when downloaded and read first.
- **Never edit dotfiles silently.** `~/.local/bin` is on `PATH` on most
  distributions; Arch's `filesystem` package appends it from `/etc/profile`,
  which an Arch-derived SteamOS *probably* inherits — unverified on the device,
  and a shell that never sources `/etc/profile` misses it either way. So check
  `PATH` and *print* the line to add; do not append to `.bashrc` on the user's
  behalf.
- **Never touch anything outside `$HOME`**, never call `sudo`, and never call a
  package manager. On an immutable distribution all three fail, and on a normal
  one they are somebody else's job.
- **Check runtime libraries and report**, rather than installing them. GTK4 and
  its stack cannot be installed into `$HOME`, so if the GUI's dependencies are
  missing the installer says which and installs the daemon and CLI anyway. This
  is the case for building the **headless static build** (musl, Static Linux
  SDK) as the installer's default payload: it is the half that is guaranteed to
  run on a machine whose system libraries nobody controls.
- **`uninstall.sh` removes what it wrote and leaves the database**, matching the
  uninstall row of the test matrix.

### 1. The extension

JavaScript, talking to the Phase 6 D-Bus interface. It uses Mutter's
server-side selection tracker from inside the gnome-shell process and forwards
each change to `skrepkad`, and it accepts a set-selection call in the other
direction so live push works on GNOME too.

Keep it as thin as it can possibly be. Everything that can live in the daemon
should: the extension is the part that has to be reviewed by strangers,
re-approved on every GNOME release, and debugged through `journalctl`. Capture
rules, privacy markers and de-duplication all stay in `SkrepkaCore` where they
are tested.

The D-Bus interface is versioned from its first commit, because the extension
ships through a review queue and will lag the daemon by weeks.

**It must degrade honestly.** If the extension is not installed, `skrepka
doctor` says so and the Settings UI says so, with the remedy. Silently capturing
nothing is the failure mode that generates a bug report for every user.

**Written now, run later.** There is no GNOME machine
([D-10](open-questions.md#d-10), [OQ-3](open-questions.md#oq-3)), so this
extension gets built against the documented Shell and D-Bus interfaces and
submitted, and the first time it meets a live gnome-shell may well be a
reviewer's. Two consequences worth accepting deliberately rather than
discovering: keep the D-Bus surface small enough that a reviewer's failure
report is actionable without a session to reproduce in, and treat the
honest-degradation path as the shipping behaviour for GNOME users in the
meantime — it is the one thing here that is testable without GNOME, because it
is a `DiagnosticsProblem` like any other.

### 2. Packaging

`.deb` and `.rpm`. Both install `skrepkad`, `skrepka`, the GUI if Phase 7
shipped, the systemd user unit, and a desktop entry.

**Flatpak is out, and the reason belongs in `packaging/README.md` rather than
being rediscovered.** Sway's `is_privileged()` lists both
`wlr_data_control_manager_v1` and `ext_data_control_manager_v1`, and its global
filter returns them only for clients with no security context — the comment in
its source says so outright: *restrict usage of privileged protocols to
unsandboxed clients.* Flatpak sets a security context. A GNOME Shell extension
cannot register from a sandbox either.

Whether KWin applies the same filter is [OQ-4](open-questions.md#oq-4) — its
`wayland_server.cpp` registers `DataControlDeviceManagerV1Interface`
unconditionally, but the `Display` global filter was not traced. It does not
change the decision; it changes how the decision is explained. **There is now a
KWin session to check it on** ([D-10](open-questions.md#d-10)), and doing so
while writing `packaging/README.md` is twenty minutes well spent.

Ruling Flatpak out matters more on an **immutable distribution**, not less:
there, Flatpak is the sanctioned way to install anything, so "we do not ship a
Flatpak" is the whole reason `install.sh` exists. `packaging/README.md` should
say that in the same breath, because the next person to ask "why not just
Flatpak it" will be looking at a Steam Deck when they ask.

**AppImage** works for the binary alone and cannot carry the extension.
**The Static Linux SDK** (musl, fully static) suits `skrepkad` and is unusable
for a GTK GUI, which needs glibc, GL and D-Bus. If a headless-only package is
ever wanted, that is the tool for it — and after Phase 6 a headless-only package
is a real product.

### 3. Dependencies, declared properly

The package must declare what it needs, per distribution: `libwayland-client`,
`libX11`/`libXfixes`, `avahi-daemon` (recommended, not required — the embedded
responder is the fallback), GTK4 and its stack if the GUI is included. A missing
runtime library should be a package-manager error at install time, not a linker
error at first launch.

## Tests

The test here is installation, on clean machines, and it should be scripted
against a throwaway `orb create` machine per distribution — see
[the Linux environment](README.md#the-linux-environment). Run the matrix on
`arm64` *and* on `amd64`: the OrbStack buildx builder offers both, and a
packaging bug that only shows on x86_64 is one that only shows for users.

| Check | On |
|---|---|
| package installs, no unmet dependencies | Ubuntu LTS, Fedora current |
| `systemctl --user enable --now skrepkad` starts it | both |
| `skrepka doctor --json` reports a healthy session | both, under KDE, Sway and X11 — **GNOME deferred** |
| pairing from a clean install reaches "paired" | both |
| uninstall removes the unit and leaves the database | both |
| upgrade over a previous version keeps history and pairings | both |

That last row is the one that will be skipped and should not be. A clipboard
manager that loses its history on upgrade loses its users.

The installer gets its own matrix, and the Steam Deck is where it runs
([D-10](open-questions.md#d-10)) — an immutable root is the case that finds the
bugs a throwaway `orb create` machine will not:

| Check | Asserts |
|---|---|
| `install.sh` on a clean `$HOME`, no `sudo` | binaries, entries, icons and unit land where the table above says |
| the picker and Settings appear in the launcher without a re-login | `update-desktop-database` and the icon cache were run |
| `systemctl --user enable --now skrepkad`, then reboot | the daemon comes back on its own |
| **an OS update, then relaunch** | nothing was written outside `$HOME`, so nothing was wiped |
| `install.sh` run twice | upgrades in place, one unit, one entry, history and pairings intact |
| a mangled download | rejected against the checksum, nothing made executable |
| `uninstall.sh` | removes what it wrote, leaves the database |

The OS-update row is the one that only this rig can run, and it is the whole
argument for the installer. If anything Skrepka wrote lives outside `$HOME`, an
atomic update deletes it and the app comes back broken.

**Deferred to GNOME hardware:** every GNOME row — the extension loading, the
D-Bus round trip through it, and `skrepka doctor` reporting its absence against
a live session. Write them into the matrix as deferred rather than dropping
them; a test that was never run is different from a test that does not exist.

## Done when

- A package installs on Ubuntu and on Fedora.
- The daemon starts under systemd on both.
- A fresh machine pairs with the Mac from a clean install.
- `install.sh`, fetched with `curl` and run without `sudo`, gets a working
  Skrepka onto the Steam Deck: binaries in `~/.local/bin`, entries in the
  launcher, daemon under `systemctl --user`, and all of it still there after an
  OS update.
- The GNOME extension is submitted, and its absence is reported honestly in the
  meantime. Its live verification is explicitly deferred, and recorded as
  deferred rather than quietly left out.

## Risks

**extensions.gnome.org review is calendar time, not effort.** Budget it as such
and do not put anything on the critical path behind it. The extension being
"submitted" is a legitimate definition of done for this phase; "approved" is not
something the project controls.

**A GNOME release breaks the extension.** It will, eventually — that is the
standing cost of option 2 and it is what [D-5](open-questions.md#d-5) is really
asking about. Keeping the extension thin is the only mitigation that works.

**Two package formats, twice the maintenance.** Real, and the reason the
headless static build is worth remembering: if `.deb` and `.rpm` become a
burden, a single static `skrepkad` plus the CLI is a defensible product that one
person can maintain — and `install.sh` is already the delivery mechanism for
exactly that.

**The installer quietly becomes the only channel.** It is easier to maintain
than two package formats, it works everywhere, and the project's own test rig
uses it — three good reasons to let `.deb` and `.rpm` rot. Decide that
deliberately if it happens. A `curl | sh` install is a worse default for users
who have a package manager: nothing tells them an update exists, and nothing
removes it cleanly if they never find `uninstall.sh`.

**Shipping a shell script that runs unreviewed.** `curl … | sh` is the install
UX users expect and it is also the one that gets a project blamed for somebody
else's supply-chain incident. The mitigations are cheap and all of them belong
in step 0: a pinnable version, a published checksum, a script that reads
correctly when downloaded first, and no `sudo` anywhere in it.
