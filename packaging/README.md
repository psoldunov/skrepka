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

## `gnome-extension/`

The release tarball carries `gnome-extension/` at its root. `install.sh` copies
its four reviewed source files into the user extension directory:

```text
$XDG_DATA_HOME/gnome-shell/extensions/skrepka@dev.soldunov/
```

GNOME/Mutter exposes neither Wayland data-control protocol to an ordinary
client. The extension therefore runs inside Shell, listens to Mutter's
server-side clipboard selection and submits supported representations to the
local daemon through `dev.soldunov.Skrepka1.Submit`. It has no UI, store,
subprocess, direct network access or capture policy; the daemon still owns
privacy markers, exclusions, size validation, de-duplication and retention.

A running Wayland Shell does not discover a directory added after login. On a
first install, the installer adds the UUID to GNOME's `enabled-extensions`
setting, so it becomes active automatically at the next login, and tells the
user to log out once when GNOME is already running. An upgrade that Shell
already knows is disabled, replaced and re-enabled live. An extension the user
disabled stays disabled. Uninstall disables it before removing its one named
directory. All of this works at user scope; nothing is written under `/usr`.

KDE, Sway, other data-control compositors and X11 use the native clipboard
backends and ignore this directory.

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
curl -fsSL <same url> | bash -s -- --version v0.3.0   a specific release
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
  the private `libgtk4-layer-shell` in `~/.local/lib/skrepka` (see above). The
  GNOME extension goes to
  `~/.local/share/gnome-shell/extensions/skrepka@dev.soldunov`. `--uninstall`
  removes exactly those files and directories.
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

## `.deb` and `.rpm`: `nfpm.yaml` and `scripts/build-packages.sh`

The same build as the release tarball, as a system package for Ubuntu 24.04 and
newer, Debian 13 and newer, and Fedora 39 and newer. Those floors are the
tarball's own: glibc 2.38 and GTK 4.12. Debian 12, on glibc 2.36, refuses the
`.deb` rather than installing binaries that cannot start. The `.rpm` names its
libraries by soname, so it should also resolve on openSUSE Tumbleweed — not
tried.

On Ubuntu or Debian:

```
sudo apt install ./skrepka-linux-x86_64.deb
```

On Fedora:

```
sudo dnf install ./skrepka-linux-x86_64.rpm
```

`scripts/build-deck.sh` runs `scripts/build-packages.sh` once the tarballs are
packed. It compiles nothing. It lays the stage out under `build/deck/pkgroot`
the way a system install wants it, and nFPM — `goreleaser/nfpm`, pinned, in
Docker — packs that tree as `nfpm.yaml` maps it. The package version is asked of
the staged `skrepkad --version`, so a package can only claim the version of the
build inside it. Run `scripts/build-packages.sh` alone to try a change to
`nfpm.yaml` without another build.

| File | Goes to |
| --- | --- |
| `skrepkad`, `skrepka`, `skrepka-gui` | `/usr/bin` |
| `libgtk4-layer-shell.so.0` | `/usr/lib/skrepka` — `$ORIGIN/../lib/skrepka` from `/usr/bin`, the rpath the binary already carries |
| the user unit | `/usr/lib/systemd/user/skrepkad.service`, `ExecStart=/usr/bin/skrepkad` |
| the D-Bus activation file | `/usr/share/dbus-1/services`, `Exec=/usr/bin/skrepkad` |
| the launcher entry and the icons | `/usr/share/applications`, `/usr/share/icons/hicolor` |
| the autostart entry | `/etc/xdg/autostart`, a conffile |
| the GNOME extension | `/usr/share/gnome-shell/extensions/skrepka@dev.soldunov` |

**No maintainer scripts.** Nothing runs as root at install time and nothing is
enabled for every user. At login the autostart entry starts `skrepka-gui`, and
its first call on the session bus starts `skrepkad` through the D-Bus activation
file and the user unit, as after `install.sh`. Right after installing, before
that first login, start "Skrepka" from the launcher. dbus-daemon notices a new
service file on its own; dbus-broker, Fedora's bus, rereads its directories
when asked to reload — which `install.sh` does and a package cannot do for every
running session — so there the first start may need
`systemctl --user start skrepkad.service`, or a log out and back in. That last
case has not been tried on a live Fedora session.

**Launch at login** in Settings reads the system entry when the user has none,
and turns it off the way the Autostart spec says a user turns off a system
entry: a copy with `Hidden=true` in `~/.config/autostart`. The system file is
never edited.

**GNOME** installs the extension for every user but enables none. Log out and
back in once, so Shell discovers it, then run
`gnome-extensions enable skrepka@dev.soldunov`.

**Do not mix it with `install.sh`.** A copy in `~/.local` shadows the package's:
`~/.local/bin` comes first on `$PATH`, and the user unit and D-Bus directories
under `~/.config` and `~/.local/share` override the system ones. Run
`install.sh --uninstall` first. History and the device key live in
`~/.local/share/skrepka` either way, and neither route removes them.

## COPR: `copr/skrepka.spec`

A Fedora package published on [COPR](https://copr.fedorainfracloud.org) as
`psoldunov/skrepka`, so that `dnf upgrade` delivers each release:

```
sudo dnf copr enable psoldunov/skrepka
sudo dnf install skrepka
```

It is the release tarball again, repackaged rather than rebuilt, as the flake
does it. Fedora packages Swift 6.3 only from Fedora 44 on, and a source build
would have to vendor every SwiftPM dependency, because COPR builds have no
network. COPR does not hold packages to Fedora's packaging guidelines, which
ask for a build from source. It asks for a license Fedora accepts, and MIT is
one. The project builds for Fedora 43, 44 and 45 and rawhide,
x86_64 only, and follows Fedora's branching, so the next release gets a chroot
of its own when it branches from rawhide.

The layout is the `.deb` and `.rpm` table above, file for file, with the same
two paths rewritten, and one difference: **no private `libgtk4-layer-shell`**.
Fedora 43 and newer ship `gtk4-layer-shell` 1.3.0, the version the tarball
bundles, so the package depends on it. The binary's `$ORIGIN/../lib/skrepka`
rpath then points at a directory that does not exist, and the loader moves on
to `/usr/lib64`. Every library dependency is generated by rpm from the ELF
headers. The exception is `libXtst`, a weak dependency, because the binary
loads it with `dlopen`. Like the `.deb` and `.rpm`, it has no scriptlets: the
first login after installing starts it, as described above, and on GNOME the
extension still has to be enabled once.

The package has the same name as the GitHub release's `.rpm`, and its release
number carries Fedora's dist tag, so `0.3.0-1.fc44` sorts above that package's
`0.3.0-1`. Enabling the COPR repository therefore upgrades a GitHub install in
place and removes its private library. `scripts/test-copr.sh` checks exactly
that.

Three scripts, sharing `scripts/lib/copr.sh`:

- **`scripts/pin-release.sh <version> [tarball]`** sets the spec's `Version`,
  resets `Release` to 1, and rewrites its one `%changelog` entry. rpmbuild
  takes the build's timestamps from that entry's date, so they do not change
  from one build to the next. Pinning the version already pinned changes
  nothing.
- **`scripts/test-copr.sh`**, which needs no account and publishes nothing, does
  the following:
  - builds the source RPM, then rebuilds a binary one from it, the way COPR
    does, and runs `rpmlint` on both;
  - installs the result in clean Fedora 43, 44 and 45 and rawhide containers;
  - checks that the binaries run and that `skrepka-gui` loads Fedora's
    `gtk4-layer-shell`;
  - checks that the unit and the D-Bus file point at `/usr/bin`;
  - upgrades the GitHub `.rpm` to the new package in one container.

  `SKREPKA_TARBALL=build/deck/skrepka-linux-x86_64.tar.gz` tests an unreleased
  build.
- **`scripts/publish-copr.sh <version> [--dry-run]`** first checks three things:
  - the spec pins that version;
  - the spec is committed;
  - the published tarball matches its `.sha256`.

  Then it builds the same source RPM and uploads it with `copr-cli`, and waits
  until every chroot has built. It uploads a source RPM rather than pointing
  COPR at the spec's URL for two reasons:
  - the file that was tested is the file that is published;
  - a release tagged before its spec existed, like 0.3.0, can still be
    published.

  The cost is uploading about 95 MB per release. The first run creates the
  project.

The test and the publish script run rpmbuild in a Fedora container. Under
OrbStack's Rosetta translation of amd64, Fedora 44's `tar` fails every
extraction with "Function not implemented". rpmbuild unpacks the tarball with
`tar`, so the builds run in Fedora 43, and the other Fedoras only install the
result, which works under translation. `SKREPKA_COPR_BUILD_IMAGE` overrides the build image on a host
without that problem.

### Publishing to COPR: one-time setup

1. **A Fedora Account.** Create one at
   [accounts.fedoraproject.org](https://accounts.fedoraproject.org); its user
   name is the COPR user name and the first half of the project's name.
2. **Log in to COPR once** at
   [copr.fedorainfracloud.org](https://copr.fedorainfracloud.org), which
   creates the COPR user.
3. **An API token.** Copy the `[copr-cli]` block that
   [copr.fedorainfracloud.org/api](https://copr.fedorainfracloud.org/api/)
   shows into `~/.config/copr`, then `chmod 600 ~/.config/copr` — anyone who
   can read the file can publish as you. The token expires, and the block's
   `# expiration date` comment says when. After that date `publish-copr.sh`
   stops with a message saying so, and the same page issues a new token.
   `SKREPKA_COPR_CONFIG` points at another file.
4. **Try it:** `scripts/publish-copr.sh <version> --dry-run` checks the token
   with `copr-cli whoami`, builds the source RPM, and prints what a real run
   would create and upload.

Nothing is installed on the Mac: `copr-cli` runs in a Fedora container with the
token file mounted read-only.

## Pacstall: `pacstall/skrepka-deb.pacscript`

A pacscript for [Pacstall](https://pacstall.dev), the AUR-style package helper
for Ubuntu and Debian, published in its repository,
[`pacstall/pacstall-programs`](https://github.com/pacstall/pacstall-programs):

```sh
pacstall -I skrepka-deb
pacstall -Up                # upgrade it, with everything else Pacstall installed
```

It is a `-deb` pacscript: it names the release's own `.deb`, pinned by version
and SHA-256, and Pacstall installs that file with apt, unchanged. Pacstall
repacks a `.deb` only when the pacscript adds dependencies, and this one adds
none. So the layout, the dependencies and the private `libgtk4-layer-shell` are
the `.deb` table's above, and there is no third copy of the layout to keep in
step with `nfpm.yaml` and the spec. A `-bin` pacscript, one that laid out the
tarball itself, would have been that third copy. The package it installs is
`skrepka`, the same name as the GitHub `.deb`, so either replaces the other.

The pacscript sets no `incompatible`. Ubuntu 22.04 and Debian 12, the two
releases Pacstall still supports whose glibc is older than the build's 2.38,
are refused by the `.deb`'s own `libc6 (>= 2.38)` and `libgtk-4-1 (>= 4.12)`,
when apt cannot satisfy them. Pacstall's reviewers asked for it that way: an
old glibc is a dependency the package states, not a property of the release,
and a jammy or bookworm that backports both would install it.

The same review dropped the pacscript's header comment, so the file says
nothing about where it comes from; this section does. Its `url` is
single-quoted, as the reviewers asked and as pacstall-programs' other `-deb`
pacscripts write it.

Pacstall's own updater, Pacup, finds new versions through Repology, and no
repository Repology reads carries Skrepka, so each release opens its own
update. The pacscript here is the source of truth, and the copy in
pacstall-programs follows it. Three scripts, sharing `scripts/lib/pacstall.sh`:

- **`scripts/pin-release.sh`** sets `pkgver` and the `.deb`'s `sha256sums`,
  from the `.deb` beside the tarball it is given, and drops any `pkgrel`.
- **`scripts/test-pacstall.sh`**, which publishes nothing:
  - runs shfmt and shellcheck on the pacscript with pacstall-programs' options;
  - installs Pacstall with its own installer in clean Ubuntu 26.04 and Debian
    13 containers, as a sudo user, the way pacstall-programs' CI does;
  - installs the pacscript with `pacstall -PI`, checks that the binaries run,
    that every library resolves — `libgtk4-layer-shell` from `/usr/lib/skrepka`
    — and that the unit and the D-Bus file point at `/usr/bin`, then removes it
    with `pacstall -PR`;
  - checks that apt refuses it on Ubuntu 22.04, on the `.deb`'s
    `libc6 (>= 2.38)`.

  `SKREPKA_DEB=build/deck/skrepka-linux-x86_64.deb` tests an unreleased build
  through a `file://` source. Pacstall sources a pacscript inside bubblewrap,
  and under OrbStack's Rosetta translation of amd64 Debian 13's bubblewrap
  0.12 cannot mount anything — "Function not implemented", like Fedora 44's
  `tar` above — where Ubuntu's 0.11 can. Only where a probe of bwrap fails that
  way does the test install with `--nosandbox`, and its result line says so.
- **`scripts/publish-pacstall.sh <version> [--dry-run]`** checks that the
  pacscript pins that version, is committed, and names the published `.deb`'s
  hash. Then it:
  - branches from pacstall-programs' master in its own clone under
    `build/pacstall`;
  - copies the pacscript in and runs what their pre-commit hook runs — shfmt,
    shellcheck, and their `scripts/srcinfo.sh` for the `.SRCINFO`, `packagelist`
    and `srclist` — in a Debian container;
  - commits, pushes to your fork of pacstall-programs, created on the first
    run, and opens the pull request: ``add: `skrepka-deb` `` the first time,
    ``upd(skrepka-deb): `old` -> `new` `` after that, the titles their wiki
    asks for.

  A second run for the same version replaces its branch and updates its pull
  request. It needs `gh` logged in; nothing else is set up.

Their CI then installs the pull request's pacscript on Ubuntu's latest LTS,
devel and rolling releases and Debian stable, testing and unstable, and a
Pacstall maintainer merges it. Until then `pacstall -I skrepka-deb` installs the
previous version.

## Nix: `flake.nix` and `nix/`

A flake for x86_64-linux that repackages the release tarball rather than
building from source. nixpkgs carried Swift 5.10 until 2026-09-16, and nothing
has built a SwiftPM package of this size with its Swift 6.2 yet; revisit a
source build once that has a track record.

`nix/package.nix` fetches `skrepka-linux-x86_64.tar.gz` for the version and
hash it names, and:

- links the binaries against nixpkgs' libraries with `autoPatchelfHook`, using
  nixpkgs' `gtk4-layer-shell` rather than the bundled copy;
- wraps `skrepka-gui` with `wrapGAppsHook4`, and sets `SKREPKA_GUI_EXECUTABLE`
  so Settings writes `skrepka-gui` into a fresh autostart entry rather than a
  store path that garbage collection deletes;
- installs the unit, the D-Bus activation file and the launcher entry with
  absolute store paths, the icons, and the GNOME extension under
  `share/gnome-shell/extensions` with `passthru.extensionUuid`;
- keeps the autostart entry in `share/skrepka/autostart` rather than
  `etc/xdg/autostart`. A profile's `etc/xdg` is on `$XDG_CONFIG_DIRS` on NixOS,
  so an entry there would start the app for anyone who installs the package,
  whatever a module's `autostart` says; the modules put it where it belongs.

The flake exposes `packages.x86_64-linux.default` (also `skrepka`), `apps` for
`skrepka-gui`, `skrepka` and `skrepkad`, `overlays.default`, and two modules,
each `programs.skrepka.enable`:

- **`nixosModules.default`** installs the package system-wide — launcher, icons
  and the GNOME extension — adds it to `services.dbus.packages` and
  `systemd.packages`, and has `skrepkad` wanted by every user's
  `default.target`. `programs.skrepka.autostart` (on by default) puts the
  autostart entry in `/etc/xdg/autostart`, where Settings reads it as the
  system entry and each user can hide it.
- **`homeManagerModules.default`**, for Nix on any distribution, a Steam Deck
  included. It installs the package, the D-Bus activation file into
  `~/.local/share/dbus-1/services` and the user unit into
  `~/.config/systemd/user`, enabled. `programs.skrepka.autostart` (on by default)
  writes the autostart entry once, if there is none, as an ordinary file
  pointing at the profile's `skrepka-gui`, so the Settings switch can still hide
  it; off, nothing starts the app at login. `programs.skrepka.gnomeExtension` links the extension into
  `~/.local/share/gnome-shell/extensions`; enable it once, as above. Anyone who
  manages GNOME through Home Manager can instead list
  `config.programs.skrepka.package` in `programs.gnome-shell.extensions` — that
  option replaces the whole enabled-extensions list, which is why this module
  does not set it for you.

Each release, after `scripts/build-deck.sh`, run
`scripts/pin-release.sh <version> build/deck/skrepka-linux-x86_64.tar.gz`
and commit what it changes. It pins the COPR spec as well, below. The tarball
carries nothing from `nix/` or `copr/`, so that commit changes no byte of the
release, and it is the one to tag.

## Publishing a release

1. **Bump the version:** `Info.plist` (`CFBundleShortVersionString` and
   `CFBundleVersion`), `Sources/SkrepkaDaemon/DaemonVersion.swift` —
   `DaemonVersionTests` fails the gate when the two disagree — the `CHANGELOG.md`
   heading, the `--version` examples in `README.md`, `install.sh` and this file,
   `SECURITY.md`, the bug-report placeholder and the smoke tests' default
   release.
2. **Build:** `scripts/notarize.sh` for the macOS zip and disk image in
   `build/`, then `scripts/build-deck.sh`, on a Mac with OrbStack or Docker, for
   the Linux assets in `build/deck/`.
3. **Pin Nix, COPR and Pacstall:** `scripts/pin-release.sh`, as above, and
   commit.
4. **Smoke-test:** `SKREPKA_TARBALL=build/deck/skrepka-linux-x86_64.tar.gz
   scripts/kde-smoke.sh`, `SKREPKA_TARBALL=… scripts/test-copr.sh`, and
   `SKREPKA_DEB=build/deck/skrepka-linux-x86_64.deb scripts/test-pacstall.sh`,
   which installs the `.deb` in clean containers too.
5. **Publish:** tag the commit, create the GitHub release with the twelve
   assets below and `scripts/release-notes.sh <version>` as its notes — the
   changelog section, unwrapped, because a release renders every newline as a
   line break — and bump the version and the `skrepka-macos-universal.zip`
   SHA-256 in `Casks/skrepka.rb` in
   [`psoldunov/homebrew-tap`](https://github.com/psoldunov/homebrew-tap).
6. **COPR:** once the release is public, `scripts/publish-copr.sh <version>`.
   It needs the tag and the published tarball, and waits until every Fedora has
   built — a few minutes. To check the repository itself afterwards, in a
   container: `dnf -y install dnf5-plugins && dnf -y copr enable
   psoldunov/skrepka && dnf -y install skrepka`.
7. **Pacstall:** once the release is public, `scripts/publish-pacstall.sh
   <version>`. It opens the update's pull request in pacstall-programs; their
   CI and a maintainer take it from there.

Attach the release's assets under exactly these names:

- `skrepka-macos-universal.dmg` — the notarized, universal macOS app on a
  notarized disk image, beside a link to `/Applications`.
- `skrepka-macos-universal.zip` — the same app, zipped; what the Homebrew cask
  installs. Up to 0.2.1 this was `Skrepka.zip`.
- `skrepka-linux-x86_64.tar.gz` — what `install.sh` installs: the daemon, the
  CLI, the desktop app, the GNOME extension, everything under `packaging/` and
  `install.sh` itself.
- `skrepka-linux-x86_64-tools.tar.gz` — the probes and the palette demo, for
  hardware bring-up only. It unpacks into the same directory name, so untarring
  both side by side merges them.
- `skrepka-linux-x86_64.deb` and `skrepka-linux-x86_64.rpm` — the same build as
  system packages.
- a `.sha256` beside each of the above.

The two tarballs are split because every binary carries its own static Swift
runtime, Foundation and ICU data, and all six in one tarball came to 256 MB.
Debug info is stripped with the symbol table kept, so crash backtraces still
name functions. The release tarball comes to about 95 MB.

`install.sh` downloads through `/releases/latest/download/`, which only
resolves a name that is the same in every release, so no asset name carries a
version — the packages' included, so their download links are stable too.

## Why `install.sh` is still the SteamOS path

Recorded as D-10 in `docs/linux-sync/open-questions.md`. SteamOS's root
filesystem is read-only, `steamos-readonly disable` is undone by the next
atomic OS update, and with systemd-sysext extensions merged `/usr` stays
read-only even after disabling it — so a `.deb` or `.rpm` has nowhere to land
there, or on any other atomic desktop. `/home` survives OS updates, which is why
the installer writes only there, and it doubles as the no-root install path for
any distribution. The packages are for the distributions whose `/usr` is
writable.

## Why not Flatpak

Flatpak is SteamOS's own answer to a read-only root, and it stays out because a
sandbox cannot watch the clipboard on most of the desktops Skrepka targets.
Flatpak tags a sandboxed app's Wayland connection with a security context, and
compositors refuse privileged protocols to such connections. Checked on
2026-09-22 against each compositor's source (OQ-4 in
`docs/linux-sync/open-questions.md`):

- **KDE Plasma 6.4 to 6.7** — the Deck runs 6.4.3 — refuse a sandboxed client
  nothing Skrepka needs: KWin's `allowInterface()` hides only
  `wp_security_context_manager_v1` itself from it.
- **KDE Plasma 6.8** adds `ext_data_control_manager_v1` to the interfaces a
  sandboxed client may not bind, and that is the only data-control protocol its
  KWin implements. A Flatpak on Plasma 6.8 cannot see a single copy.
- **sway** refuses a sandboxed client both data-control managers, layer-shell
  and the virtual keyboard: no capture, no picker, no paste.
- **GNOME** implements no data-control at all. Capture there is the Shell
  extension, which has to be installed outside the sandbox.

So a Flatpak would work on the Deck today and stop recording the day SteamOS
moves to Plasma 6.8. Flathub's `org.freedesktop.Sdk.Extension.swift6` now ships
Swift 6.3.3, so building one from source is no longer the obstacle; the
compositors are.
