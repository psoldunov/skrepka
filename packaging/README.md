# Packaging

How Skrepka's Linux daemon gets onto a machine. macOS is packaged as a signed
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

## `desktop/dev.soldunov.Skrepka.Settings.desktop`

The launcher entry for `skrepka-settings`, the GTK4 window that pairs and
manages synced devices. The repository copy says `Exec=skrepka-settings` and
`Icon=edit-paste`, a stock freedesktop icon until Phase 8 draws a real one.
`scripts/install.sh` rewrites the `Exec=` line to the absolute installed path,
because `~/.local/bin` is not on every desktop session's `$PATH`, quoting it as
the Desktop Entry specification's Exec rules require.

`skrepka-settings` links `libgtk4-layer-shell` dynamically, and SteamOS does not
ship it. The Deck tarball therefore bundles it in `lib/`, and the binary is
linked with two rpaths: `$ORIGIN/../lib`, so it runs in place from the untarred
tarball, and `$ORIGIN/../lib/skrepka`, so an installed copy in `~/.local/bin`
finds a private copy in `~/.local/lib/skrepka/`. The installer copies the
bundled library there, dereferenced into one regular file named
`libgtk4-layer-shell.so.0`, only when the build directory has a `../lib` beside
it. The directory is computed from `$XDG_BIN_HOME`, not `$HOME`, because the
rpath is relative to the binary. GTK 4 itself is not bundled and has to come
from the host.

Building it from source needs the development files for GTK 4.12 or newer and
gtk4-layer-shell; `skrepkad` and `skrepka` do not. 4.12 is the oldest GTK with
every call the window makes — `gtk_css_provider_load_from_string` and
`gtk_list_box_remove_all` are the newest of them — and the build image carries
4.14. `scripts/install.sh` builds the window only when
`pkg-config --exists 'gtk4 >= 4.12' gtk4-layer-shell-0` succeeds, and a headless
install with just the daemon and the CLI is a complete one. A binary built
elsewhere, including the one in the Deck tarball, needs GTK 4.12 or newer on the
machine it runs on: an older one fails at launch with a missing symbol.

## `scripts/install.sh`

The installer. From a checkout or piped from `curl`:

```
scripts/install.sh                     build this checkout and install
scripts/install.sh --from-build DIR    install binaries already built in DIR
scripts/install.sh --uninstall         stop, disable, and remove
curl -fsSL https://raw.githubusercontent.com/psoldunov/skrepka/master/scripts/install.sh | bash
```

It builds `skrepkad` and `skrepka` in release, installs them into
`~/.local/bin`, and installs `skrepka-settings` beside them — with its launcher
entry in `~/.local/share/applications` and, from a tarball that bundles one, the
private `libgtk4-layer-shell` in `~/.local/lib/skrepka` — when the build has it
(see above). `--uninstall` removes exactly those files and the private directory
if it is then empty. It installs the unit into `~/.config/systemd/user`, and runs
`systemctl --user daemon-reload && systemctl --user enable --now
skrepkad.service` — but only when there is a user manager to talk to. In a
container, over ssh without lingering, or on a non-systemd distribution it says
so and prints the two commands to run by hand. `$XDG_BIN_HOME`,
`$XDG_CONFIG_HOME` and `$XDG_DATA_HOME` are honoured when they hold an absolute
path; when `$XDG_BIN_HOME` moves the binaries, the unit's `ExecStart=` is
rewritten to match.

It never touches `~/.local/share/skrepka`. The history database
(`skrepka.sqlite3`) and the device's sync identity (`device.key`) live there,
and the daemon creates them itself with the modes they need — 0700 on the
directory, 0600 on the key. An installer that pre-creates them at the wrong
mode is an exposure, not a convenience. `--uninstall` leaves them in place for
the same reason and prints where they are: deleting `device.key` un-pairs the
machine from every peer it has synced with.

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
