# Packaging

How Skrepka's Linux daemon, CLI and desktop app get onto a machine. macOS is packaged as a signed
`.app` by `scripts/bundle.sh` and `scripts/notarize.sh`; none of that applies
here.

## `systemd/skrepkad.service`

A systemd **user** unit for `skrepkad`, the clipboard daemon.

A user unit rather than a system one because the daemon needs the session D-Bus
and `$WAYLAND_DISPLAY` or `$DISPLAY`, none of which a system unit has, and
because installing one needs no root. It is ordered `After=` and declared
`PartOf=graphical-session.target` so it comes up behind the compositor and goes
down with the session, and installed `WantedBy=default.target` so it starts at
login even on a session that never reaches `graphical-session.target`. The file
itself carries the reasoning for every directive, including the ones
deliberately left out.

Verified with `systemd-analyze --user verify` against systemd 255 — Ubuntu
24.04, the oldest of the three targets; Fedora 42+ and SteamOS 3.8 are newer.

Useful commands once installed:

```
systemctl --user status skrepkad.service
systemctl --user restart skrepkad.service
journalctl --user -u skrepkad.service -f
```

## `dbus/dev.soldunov.Skrepka.service`

D-Bus activation for the daemon. With it in the session bus's services
directory, `~/.local/share/dbus-1/services`, the bus starts `skrepkad` whenever
a client calls `dev.soldunov.Skrepka` and nothing owns the name — the tray app
at login, the Settings window, `skrepka list` after a `systemctl --user stop`.
`SystemdService=skrepkad.service` routes that start through the user unit, so
the daemon keeps the unit's restart policy and journal, and dbus-broker — which
SteamOS and Arch run, and which activates only through systemd — can activate
it at all. `install.sh` rewrites `Exec=` to the absolute installed path the
D-Bus specification asks for, and asks the bus to reload its configuration so
the file takes effect without a new login.

## `desktop/dev.soldunov.Skrepka.App.desktop` and `autostart/`

The launcher entry for `skrepka-gui`, the desktop app: the tray icon, the
clipboard picker and the Settings window, in one process. It is the only
launcher entry — Settings is reached from the tray menu, the picker's gear
button, and the entry's own "Settings" action (a launcher's right-click menu),
not from a second entry. Its file name is the app's GApplication ID,
`dev.soldunov.Skrepka.App`, because that is how a Wayland desktop matches the
Settings window to its name and icon. `Icon=` names the app icon below.

`autostart/dev.soldunov.Skrepka.App.desktop` goes to `~/.config/autostart` and
runs `skrepka-gui --background` at login, so the tray icon and the picker's
shortcut are there without opening anything.

`install.sh` rewrites every `Exec=` line in both to the absolute installed path,
because `~/.local/bin` is not on every desktop session's `$PATH`, quoting it as
the Desktop Entry specification's Exec rules require. It then starts the app in
the tray when it runs inside a graphical session, and quits a running one before
replacing its binary.

## `icons/hicolor/`

The app icon is the macOS one: `AppIcon.icns`, the icon `scripts/make-icon.sh`
draws, extracted with `iconutil` and — for the 22, 24, 48 and 96 pixel sizes
the icon set lacks — scaled from its 1024-pixel image with `sips`. PNGs rather
than a script run at build time because the drawing is Core Graphics and runs on
a Mac only; regenerate them there when the icon changes.

`scalable/status/skrepka-tray.svg` is the tray icon: the mark alone, traced from
`scripts/paperclip.svg`, monochrome like the macOS menu bar icon. It colours
itself with KDE's `ColorScheme-Text` stylesheet, which Plasma replaces with the
panel's text colour, so it reads on dark and light panels alike. The tray also
publishes the mark as pixels, drawn by `MarkRenderer`, for a host that does not
find the icon by name.

`install.sh` installs them into `~/.local/share/icons/hicolor` and refreshes an
existing `icon-theme.cache` there, but never creates one.

## The layer-shell library

`skrepka-gui` links `libgtk4-layer-shell` dynamically, and SteamOS does not
ship it. The release tarball therefore bundles it in `lib/`, and the binary is
linked with two rpaths: `$ORIGIN/../lib`, so it runs in place from the untarred
tarball, and `$ORIGIN/../lib/skrepka`, so an installed copy in `~/.local/bin`
finds a private copy in `~/.local/lib/skrepka/`. The installer copies the
bundled library there, dereferenced into one regular file named
`libgtk4-layer-shell.so.0`, only when the build it installs has a `lib/` beside
`bin/`. The directory is computed from `$XDG_BIN_HOME`, not `$HOME`, because the
rpath is relative to the binary. GTK 4 itself is not bundled and has to come
from the host.

Building it from source needs the development files for GTK 4.12 or newer and
gtk4-layer-shell; `skrepkad` and `skrepka` do not. 4.12 is the oldest GTK with
every call the window makes — `gtk_css_provider_load_from_string` and
`gtk_list_box_remove_all` are the newest of them — and the build image carries
4.14. `scripts/setup-linux.sh` builds the app only when
`pkg-config --exists 'gtk4 >= 4.12' gtk4-layer-shell-0` succeeds, and a headless
install with just the daemon and the CLI is a complete one. A binary built
elsewhere, including the one in the release tarball, needs GTK 4.12 or newer on
the machine it runs on: an older one fails at launch with a missing symbol.

## `install.sh` and `scripts/setup-linux.sh`

Two scripts, because installing a release and building from a checkout are
different jobs.

**`install.sh`**, at the root of the repository, installs a released build. It
needs no toolchain, only `curl`:

```
curl -fsSL https://raw.githubusercontent.com/psoldunov/skrepka/master/install.sh | bash
curl -fsSL <same url> | bash -s -- --version v0.2.0   a specific release
curl -fsSL <same url> | bash -s -- --uninstall        stop, disable, and remove
./install.sh                     inside an untarred release: install that one
./install.sh --tarball FILE      a release tarball already on disk
./install.sh --from-dir DIR      a staged build (what setup-linux.sh passes)
```

- **Download and check.** It downloads `skrepka-linux-x86_64.tar.gz` from the
  latest GitHub release, or the one `--version` names, and checks it against
  the `.sha256` published beside it.
  - That checksum comes from the same release, so it catches a damaged
    download, not a replaced release. The tarball is not signed.
  - A mismatch installs nothing.
  - `SKREPKA_RELEASE_BASE_URL` points the download somewhere else, such as a
    fork or a local test server.
- **Refusals.** Release builds are x86_64, and any other machine is refused
  before anything is written. So is a machine where `skrepkad --version` will
  not run, for example because its glibc is older than the build's.
- **Where the files go.** `skrepkad` and `skrepka` land in `~/.local/bin`, and
  the D-Bus activation file in `~/.local/share/dbus-1/services`. `skrepka-gui`
  goes beside the binaries when the build has it, with its launcher entry in
  `~/.local/share/applications`, its autostart entry in `~/.config/autostart`,
  its icons in `~/.local/share/icons/hicolor`, plus, from the release tarball,
  the private `libgtk4-layer-shell` in `~/.local/lib/skrepka` (see above).
  `--uninstall` removes exactly those files, and the private directory if it is
  then empty.
- **The 0.2.0 Settings window.** 0.2.0 installed Settings as its own program,
  `skrepka-settings`, with its own "Skrepka Settings" launcher entry.
  `skrepka-gui` replaces both, so installing — and uninstalling — removes those
  two files if they are there.
- **The unit.** It installs the unit into `~/.config/systemd/user` and runs
  `systemctl --user daemon-reload && systemctl --user enable --now
  skrepkad.service`, then `try-restart` so an upgrade replaces a running
  daemon. That happens only when there is a user manager to talk to. In a
  container, over ssh without lingering, or on a non-systemd distribution it
  says so and prints the two commands to run by hand.
- **XDG variables.** `$XDG_BIN_HOME`, `$XDG_CONFIG_HOME` and `$XDG_DATA_HOME`
  are honoured when they hold an absolute path. When `$XDG_BIN_HOME` moves the
  binaries, the unit's `ExecStart=` is rewritten to match.
- **Piped safely.** The whole script is one `main` function called on its last
  line, so a download cut off halfway runs nothing.

**`scripts/setup-linux.sh`** is the developer's path, from a checkout on the
Linux machine itself, with a Swift 6.3 toolchain on `PATH`:

```
scripts/setup-linux.sh               build in release and install
scripts/setup-linux.sh --uninstall   the same as ./install.sh --uninstall
```

It builds `skrepkad`, `skrepka` and, when the GTK packages above are present,
`skrepka-gui`. It stages them in the layout the release tarball uses and
hands that directory to `install.sh --from-dir`. That way both routes install,
upgrade and uninstall through the same code, and only one script decides where
files go.

Neither script touches `~/.local/share/skrepka`. The history database
(`skrepka.sqlite3`) and the device's sync identity (`device.key`) live there,
and the daemon creates them itself with the modes they need — 0700 on the
directory, 0600 on the key. An installer that pre-creates them at the wrong
mode is an exposure, not a convenience. `--uninstall` leaves them in place for
the same reason and prints where they are: deleting `device.key` un-pairs the
machine from every peer it has synced with.

## Publishing a release

`scripts/build-deck.sh`, on a Mac with OrbStack or Docker, writes four files to
`build/deck/`. Attach all four to the GitHub release, under exactly these names:

- `skrepka-linux-x86_64.tar.gz` — what `install.sh` installs: the daemon, the
  CLI, the desktop app, everything under `packaging/` and `install.sh` itself.
- `skrepka-linux-x86_64-tools.tar.gz` — the probes and the palette demo, for
  hardware bring-up only. It unpacks into the same directory name, so untarring
  both side by side merges them.
- a `.sha256` beside each.

The two are split because every binary carries its own static Swift runtime,
Foundation and ICU data, and all six in one tarball came to 256 MB. Debug info
is stripped with the symbol table kept, so crash backtraces still name
functions. The release tarball comes to about 95 MB.

`install.sh` downloads through `/releases/latest/download/`, which only
resolves a name that is the same in every release, so no asset name carries a
version.

## Why an installer and not a `.deb` or an `.rpm`

Recorded as D-10 in `docs/linux-sync/open-questions.md`. SteamOS's root
filesystem is read-only, `steamos-readonly disable` is undone by the next
atomic OS update, and with systemd-sysext extensions merged `/usr` stays
read-only even after disabling it — so a distribution package has nowhere to
land. `/home` survives OS updates, which is why the installer writes only
there. Flatpak, the SteamOS-native answer, stays out: a sandboxed client is
refused the Wayland data-control globals the clipboard needs. None of this is
Deck-specific, though — the same script is the no-root install path for any
distribution.
