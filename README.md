# Skrepka (SKRYEP-kuh)

A clipboard-history manager for macOS and Linux. Press one shortcut anywhere and
a picker opens over whatever app you are in, without taking focus away from it;
choose an entry and it lands where you were typing. Machines you pair share
their history over the local network — a Mac and a Linux box included — with no
account, no server and no relay.

![The Skrepka picker on macOS: a Liquid Glass panel over the macOS 26 desktop,
listing a photo, a link, code, a colour and a masked password, each with the
app it was copied from and a ⌘N shortcut](docs/images/picker.png)

![The Skrepka picker on KDE Plasma: the same kind of list over a Dolphin window,
with a photo selected, an Alt+N shortcut on each row and the Skrepka paperclip
in the system tray](docs/images/kde-picker.png)

- **On a Mac** it lives in the menu bar with no Dock icon, and ⌘⇧V opens a
  Liquid Glass picker.
- **On Linux** a small daemon keeps the history, a tray app opens the picker on
  Meta+Shift+V, and the `skrepka` command reaches the same history from a
  terminal.

On both:

- Text, rich text, URLs, files and images, with inline image previews — a copy
  of several files stays one row and pastes back as all of them
- Type to filter; ↑↓ to move; ↩ to paste into the app you were using
- A key for each of the first nine rows, a plain-text paste, and pins — pinned
  entries never age out
- Anything a password manager marks as not for history is never recorded
- Retention by item count and age, both configurable
- Optional sync with devices you pair, over the local network only — a copied
  file arrives on the other machine as the file, not as a path to it

## Where it runs

| Platform | How it has been tested |
| --- | --- |
| **macOS 26**, Apple silicon or one of the four Intel Macs that run it | Daily use on Apple silicon Macs; releases are universal builds that include Intel |
| **KDE Plasma 6** on Wayland | A Steam Deck OLED in Desktop Mode (SteamOS 3.8, Plasma 6.4.3), and a headless Plasma 6.4.3 session built from SteamOS 3.8's own packages |
| **GNOME 46–50** on Wayland | **In a container only.** See below |
| **sway** and other wlroots compositors | In a container only: a headless sway 1.9 in the Linux build image |
| **X11** sessions | In a container only: Xvfb in the Linux build image, with no window manager |

**GNOME is implemented, not validated.** The implementation is complete —
capture through a small GNOME Shell extension, the tray icon, the shortcut, the
picker and automatic paste — but it has never run on a real machine. Its only
end-to-end test is `scripts/gnome-smoke.sh`, which runs a headless Ubuntu 26.04
/ GNOME 50 session inside a Docker container, rendered in software and under
x86 emulation on a Mac — not a GNOME desktop anyone actually uses. In three
runs of it on 2026-09-22, installing, capture, the tray icon and the picker
passed every time; the global shortcut passed once in three, and automatic
paste did not pass at all — Skrepka fell back to leaving the entry copied and
asking for Ctrl+V. Whether that is the container or GNOME is not yet known. If
you run Skrepka on GNOME, a [bug
report](https://github.com/psoldunov/skrepka/issues/new/choose) saying whether
it works is worth having either way.

The same caution applies, less loudly, to sway and X11: their code paths are
tested against real protocol traffic, but only headless. Hyprland, which
Skrepka treats like sway, has not been tried at all.

About the screenshots: the Mac ones are the app on macOS 26 at 2× on a real
display. The KDE ones come from the headless Plasma session, also drawn at 2×;
KWin composites there without a GPU, so blur and other OpenGL-only effects are
missing from them. The history in both was copied for the picture; the photo
in it is by [Evgenii Zolotarev](https://unsplash.com/@qester) on
[Unsplash](https://unsplash.com/photos/a-bridge-over-a-frozen-river-with-a-building-in-the-background-yESKxiijQ3w).

## Install

### macOS

```sh
brew install --cask psoldunov/tap/skrepka
```

Or download `skrepka-macos-universal.dmg` from the
[latest release](https://github.com/psoldunov/skrepka/releases/latest), open
it, and drag Skrepka onto Applications. `skrepka-macos-universal.zip` holds the
same app, to unzip instead.

Either way the build is universal and notarized, so it opens on first launch
with no Gatekeeper detour. It needs macOS 26.0 or later.

The cask lives in
[`psoldunov/homebrew-tap`](https://github.com/psoldunov/homebrew-tap). Skrepka
has no in-app updater, so `brew upgrade --cask skrepka` is the whole update
path — and `brew uninstall --zap --cask skrepka` is the one that takes the
clipboard history with it.

### Linux

On an x86_64 machine with systemd and a Wayland or X11 session — a Steam Deck
in Desktop Mode included — run this in a terminal on the machine itself:

```sh
curl -fsSL https://raw.githubusercontent.com/psoldunov/skrepka/master/install.sh | bash
```

It downloads the build from the latest release and checks it against the
published SHA-256. Then it installs the daemon (`skrepkad`), the CLI (`skrepka`)
and the desktop app (`skrepka-gui`, with a "Skrepka" launcher entry) under
`~/.local`, and starts the daemon as a systemd user service. It needs no root.
Run inside a graphical session, it starts the app in the tray.

- The release binaries need glibc 2.38 or newer, and the app needs GTK 4.12 or
  newer from the host. The installer refuses a machine whose glibc is too old
  before it writes anything; a GTK that is too old shows up only when the app
  starts, as a missing symbol.
- `bash -s -- --version v0.3.0` after the pipe pins a release.
- `bash -s -- --uninstall` removes everything except your history and this
  device's sync identity.
- Re-running the line is the whole update path.

That line runs `install.sh` from `master`. To run only what you have checked,
install from the release itself — its tarball carries its own `install.sh`,
which installs the build beside it and downloads nothing:

```sh
base=https://github.com/psoldunov/skrepka/releases/latest/download
curl -fLO "$base/skrepka-linux-x86_64.tar.gz"
curl -fLO "$base/skrepka-linux-x86_64.tar.gz.sha256"
sha256sum -c skrepka-linux-x86_64.tar.gz.sha256
tar xzf skrepka-linux-x86_64.tar.gz && cd skrepka-linux-x86_64 && ./install.sh
```

The checksum is published beside the tarball, so it catches a damaged download
rather than a replaced release; [SECURITY.md](SECURITY.md) says what that does
and does not cover.

**On GNOME** the installer also adds a small Shell extension, because GNOME
does not let an ordinary program watch the clipboard. A first install needs one
log out and back in so Shell discovers it; it is already enabled for that next
login. GNOME Shell shows tray icons only through the AppIndicator extension —
Ubuntu enables it by default, many other distributions do not install it — so
without it there is no tray icon, and the shortcut and the launcher entry are
the way in.

#### On Fedora, from COPR

On Fedora 43 or newer, the same build installs from a COPR repository, and
`dnf upgrade` keeps it current:

```sh
sudo dnf copr enable psoldunov/skrepka
sudo dnf install skrepka
```

Log out and back in once, or start "Skrepka" from the launcher. On GNOME, after
that login, run `gnome-extensions enable skrepka@dev.soldunov`: the package
installs the Shell extension for every user but cannot enable it for you. It
replaces the GitHub release's `.rpm`, below, if that is installed; if you used
`install.sh` before, run it with `--uninstall` first — its copy in `~/.local`
would shadow the package's.

#### As a `.deb` or an `.rpm`

On Ubuntu 24.04 or newer, Debian 13 or newer, or Fedora 39 or newer, the same
build installs system-wide as a package:

On Ubuntu or Debian:

```sh
curl -fLO https://github.com/psoldunov/skrepka/releases/latest/download/skrepka-linux-x86_64.deb
sudo apt install ./skrepka-linux-x86_64.deb
```

On Fedora:

```sh
curl -fLO https://github.com/psoldunov/skrepka/releases/latest/download/skrepka-linux-x86_64.rpm
sudo dnf install ./skrepka-linux-x86_64.rpm
```

Log out and back in once, or start "Skrepka" from the launcher. On GNOME, after
that login, run `gnome-extensions enable skrepka@dev.soldunov`: a package
installs the Shell extension for every user but cannot enable it for you. These
come from no package repository — on Fedora 43 and newer, COPR above is one —
so updating is installing the next release's package over this one. If you
used `install.sh` before, run it with
`--uninstall` first — its copy in `~/.local` would shadow the package's. The
packages leave SteamOS and other read-only systems to `install.sh`;
[packaging/README.md](packaging/README.md) says why, and why there is no
Flatpak.

#### With Nix

The repository is a flake for x86_64-linux. Its Home Manager module works on
any distribution, a Steam Deck included; NixOS has a module of its own:

```nix
# flake inputs
inputs.skrepka.url = "github:psoldunov/skrepka";

# Home Manager
imports = [ inputs.skrepka.homeManagerModules.default ];
programs.skrepka.enable = true;

# or NixOS
imports = [ inputs.skrepka.nixosModules.default ];
programs.skrepka.enable = true;
```

To try it without installing, run the daemon in one terminal with
`nix run github:psoldunov/skrepka#skrepkad` and the app with
`nix run github:psoldunov/skrepka`; the modules are what start both at login.
The flake repackages each release's tarball rather than building from source;
[packaging/README.md](packaging/README.md) has the details, and the modules'
options.

To build from a checkout instead, on any architecture, see
[Build and run](#build-and-run).

[CHANGELOG.md](CHANGELOG.md) says what each version changed, on both platforms.

## Using it

### On a Mac

⌘⇧V opens the picker over the frontmost app. ⌘1–⌘9 paste that row outright,
⇧⌘↩ pastes as plain text, ⌘P pins, and Esc closes. The menu bar icon has Open
Skrepka, Clear History… (pinned entries stay), Settings… and Quit Skrepka.

Per-app exclusions live in Settings → Privacy, on top of automatically skipping
anything a password manager marks transient. Entries a password manager marks
concealed are kept, but masked everywhere they are shown, and never synced.

![Skrepka's Settings window on macOS, General pane: the ⇧⌘V shortcut, Paste
automatically and Launch at login](docs/images/macos-settings.png)

### On Linux

The desktop app is one program with three parts:

- **The picker.** The global shortcut Meta+Shift+V opens it over whatever you
  are working in. Type to search, arrows to move, Return to paste the entry
  into the window you were using, as on the Mac: Skrepka puts it on the
  clipboard, closes, and presses Ctrl+V for you — through XTest on X11, a
  virtual keyboard on sway and other wlroots compositors, and the Remote
  Desktop portal on KDE and GNOME, which asks once for permission. Terminals
  want Ctrl+Shift+V, so there, and wherever the desktop refuses, the entry
  stays copied for you to paste. Settings → General turns automatic paste off.
  Alt+1 to Alt+9 choose a row, Alt+Shift+Return pastes plain text, Alt+P pins,
  and Alt+Backspace deletes. The desktop asks you to confirm the shortcut the
  first time; where it has no global-shortcuts portal, bind
  `skrepka-gui --picker` as a custom shortcut in its keyboard settings.
- **The tray icon.** A left click opens the picker. The menu has Open Skrepka,
  Clear History… (pinned entries stay), Settings… and Quit Skrepka.
- **Settings.** Open it from the tray, from the gear in the picker, or from the
  launcher's Settings action. General, History, Privacy, Sync and Status panes:
  among them automatic paste, retention, pairing, which devices push live, and
  how large a copy of files may be and still sync.

![Skrepka's Settings window on KDE Plasma, General pane: the Meta+Shift+V
shortcut, Paste automatically and Launch at login](docs/images/kde-settings.png)

The app starts `skrepkad` when it is not running, and so does any `skrepka`
command, through a D-Bus activation file the installer adds. Quitting the app
leaves the daemon recording. `skrepka list`, `pin`, `unpin`, `delete`, `clear`
and `copy --plain` do from a terminal what the picker does, and
`skrepka config` reads and changes the settings.

Wayland does not say which app copied something, so there is no per-app
exclusion list on Linux. Anything a password manager marks secret — KeePassXC,
`wl-copy --sensitive` and the others that follow KDE's convention — is never
recorded.

Two journal lines look worse than they are. `avahi refuses to publish, so
skrepkad publishes this device itself` is expected on SteamOS, whose avahi is
built to publish nothing: `skrepkad` answers for its own service instead, and
`skrepka doctor` names it as the responder. Only if that fails too does
`doctor` report the device as not published; allowing user services in avahi —
`disable-user-service-publishing=no` under `[publish]` in
`/etc/avahi/avahi-daemon.conf`, then `sudo systemctl restart avahi-daemon` — is
the other way out. `Failed to set thread priority for worker thread … errno=13`
is harmless: a Swift runtime message about a scheduling hint an unprivileged
service may not set.

## Sync

On a Mac it is off until you turn it on, in Settings → Sync → Share clipboard
history. On Linux it is on from the start, though nothing is shared until you
pair; Settings → Sync or `skrepka config set sync.enabled off` turns it off.

To pair two machines, switch on "Allow new devices to pair" on one and press
Pair… for it on the other — a Mac with a Mac, a Mac with a Linux box, or two
Linux boxes. Each shows the same sixteen hex digits — `A3F2-91BC-D4E7-0182` —
and neither trusts the other until a person confirms the codes match on both
screens. That comparison is the man-in-the-middle defence: TLS proves the two
ends share a tunnel and nothing about who is on the far end.

After that, paired devices exchange history every half minute over TLS 1.3,
pinned to the self-signed certificate each one approved. "Sync Now" is there
for impatience, and each device has a live-clipboard switch that pushes what
you copy across immediately. Copied files travel with the copy, up to a limit
each device sets for itself — Settings → Sync → Sync files up to, 32 MB unless
you lower it. Unpair and Skrepka forgets the certificate and the choice; what
already synced stays.

Concealed content never leaves the machine — it is filtered out of both the
index a peer browses and the payload it can fetch, so a peer is not even told
the hash. Anything excluded by app, or carrying a privacy marker, never reached
storage in the first place.

There is no relay, so two devices that cannot see each other over Bonjour or
Avahi cannot pair or exchange anything.

## Permissions

### macOS

- **None** for capturing history or for the global shortcut. The hotkey goes
  through Carbon's `RegisterEventHotKey`, which needs no grant.
- **Accessibility**, only to paste into the frontmost app — Skrepka synthesises
  ⌘V. It asks the first time you paste something. Decline it and Skrepka falls
  back to copying, which you then paste yourself. That fallback is also
  available deliberately: turn off "Paste automatically" in Settings.
- **Local Network**, only for sync, and only once you switch sharing on. It is
  what lets Skrepka find and reach the devices you have paired with. Decline it
  and everything else works exactly as before; the Sync pane says what happened
  and offers a button to the right System Settings pane.

### Linux

- **No root**, ever. Everything installs under `~/.local` and runs as you.
- **The global shortcut** goes through the desktop's GlobalShortcuts portal,
  which asks you to confirm Meta+Shift+V the first time the app starts.
- **Automatic paste** goes through the Remote Desktop portal on KDE and GNOME,
  which asks once for permission to control the keyboard. XTest on X11 and the
  virtual keyboard on wlroots compositors ask nothing.
- **Sync** needs avahi-daemon for discovery, which most desktop distributions
  run already. Where avahi refuses to publish — SteamOS's does — `skrepkad`
  answers for its own service itself.

## Storage

On a Mac, history is a SwiftData store at
`~/Library/Application Support/dev.soldunov.skrepka/skrepka.store`. Image
payloads use `@Attribute(.externalStorage)`, so large blobs land beside the
database rather than inside a row. The picker holds only lightweight summaries
plus a small thumbnail; a full payload is read only when an entry is pasted.

Sync keeps the record of each paired device — its name, its pinned certificate
fingerprint and its live-clipboard choice — in the same store. This device's own
private key lives in the login Keychain under the service
`dev.soldunov.skrepka.sync`, never synchronised to iCloud, so the identity stays
on the Mac that created it.

On Linux, history is SQLite at `~/.local/share/skrepka/skrepka.sqlite3`, and this
device's sync identity is the file `device.key` beside it — the directory
`0700`, the key `0600`, both created by the daemon itself. Settings live in
`~/.config/skrepka/config.json`. Uninstalling leaves the history and the key in
place: deleting `device.key` un-pairs the machine from every peer, which is not
something an uninstall should do silently.

## Build and run

### macOS

```sh
scripts/run.sh        # build, bundle, sign, launch
scripts/bundle.sh     # produce build/Skrepka.app only
scripts/notarize.sh   # build, sign, notarize, staple — the .zip and .dmg you send out
scripts/doctor.sh     # the quality gate
scripts/make-icon.sh  # redraw Sources/Skrepka/Resources/AppIcon.icns
```

Xcode 26 to build. Launch with `scripts/run.sh` rather than running the binary
directly. TCC attributes permissions to the responsible process, so a
shell-launched binary inherits the terminal's grants instead of exercising the
real permission path.

#### Architecture

`scripts/bundle.sh` builds for the machine it runs on. `SKREPKA_UNIVERSAL=1`
builds an arm64 + x86_64 binary instead:

```sh
SKREPKA_UNIVERSAL=1 scripts/bundle.sh
```

`scripts/notarize.sh` sets it, because that is the build that goes to other
people. macOS 26 is the last release to support Intel, and four models still run
it — the 2019 Mac Pro, the 2019 16-inch MacBook Pro, the 2020 13-inch MacBook
Pro with four Thunderbolt 3 ports, and the 2020 27-inch iMac. An arm64-only
`.app` does not launch on any of them.

The universal build costs roughly twice the compile work and doubles the
executable — 2.3 MB to 4.7 MB, measured on this release build. The local edit
loop pays neither.

#### Signing

`scripts/bundle.sh` signs with a Developer ID identity, overridable via
`SKREPKA_SIGN_IDENTITY`. This is not cosmetic: an ad-hoc signature pins the
designated requirement to the binary's cdhash, which changes on every source
edit, so macOS treats each rebuild as a new app and drops the Accessibility
grant. A Developer ID requirement names only the bundle id and team, so the
grant survives rebuilds. Without an identity the script falls back to ad-hoc and
warns.

#### Icon

One mark, drawn once: a swirl paperclip, one continuous wire through three
U-turns with a semicircular cap on each free end. Its coordinate table lives in
`PaperclipMark.swift` (`Sources/SkrepkaCore/Branding/`), and
`scripts/paperclip.svg` is the same artwork in SVG form — the design source the
table was transcribed from. The source art cuts both free ends square; the caps
are the one change. The table is written in portable path types, so Core
Graphics draws it on a Mac and Cairo draws it on Linux.

Everything that shows the mark draws that path:

- **`AppIcon.icns`** — `scripts/make-icon.swift` renders the vectors once per
  iconset size and `scripts/make-icon.sh` packs them. The script is *compiled*
  rather than interpreted, with the branding sources linked in beside it, so
  the icon cannot drift from the app. Palettes are `paper` (off-white tile,
  near-black clip — ships) and `carbon` (off-black tile, chrome clip); pass one
  by name, or `--preview <dir>` to write both at 1024 and 64 px.
- **The menu bar** — `StatusItemIcon` in `SkrepkaCore`, the same path flattened
  into an 18pt template image. A test pins its ink coverage to a band, because
  a mark drawn too heavy reads as a blob and one drawn too light disappears,
  and neither fails loudly. The wire is drawn at its own weight and not
  boldened: the three nested wires leave gaps narrower than the wire, and
  thickening it closes them.
- **In-app** — `PaperclipMark`, a SwiftUI `Shape` in `Sources/Skrepka/Branding/`,
  on the Welcome header, the Settings identity row and the empty picker. The
  permission rows keep the system `doc.on.clipboard` symbol: they label the
  clipboard, not Skrepka.
- **Linux** — `MarkRenderer` in `Sources/SkrepkaLinuxUI/Branding/` draws the
  same table with Cairo. The app icon in
  [`packaging/icons/`](packaging/README.md#iconshicolor) is the Mac's, taken
  from `AppIcon.icns`, and the tray's `skrepka-tray.svg` is traced from
  `scripts/paperclip.svg`.

The app icon artwork is full-bleed square on purpose. macOS 26 masks a legacy
`.icns` into its own rounded-rectangle, insets it and adds the shadow — checked
on this machine by asking `NSWorkspace.icon(forFile:)` for a throwaway bundle,
not assumed from the icon's own corners.

### Linux

On a Linux machine with a Swift 6.3 toolchain:

```sh
scripts/setup-linux.sh               # build in release, then install into ~/.local
scripts/setup-linux.sh --uninstall   # the same as ./install.sh --uninstall
```

It builds the desktop app only where the GTK 4.12 and gtk4-layer-shell
development packages are installed; the daemon and the CLI alone are a complete
install. [packaging/README.md](packaging/README.md) covers where every file
goes and why.

From a Mac, with OrbStack or Docker, the Linux side runs in containers:

```sh
scripts/linux.sh <command>   # run anything inside the Linux build image
scripts/doctor-linux.sh      # the Linux quality gate
scripts/build-deck.sh        # the x86_64 release tarball + .sha256 for a GitHub release
scripts/kde-smoke.sh         # tray, shortcut, picker and click-away in headless Plasma 6.4.3
scripts/gnome-smoke.sh       # install, capture, tray, shortcut, picker and paste in headless GNOME 50
```

`scripts/kde-image.sh` and `scripts/gnome-image.sh` build the two desktop
images first; `scripts/kde.sh` and `scripts/gnome.sh` run, screenshot, type
into and click inside them.

## Layout

```
Sources/SkrepkaCore/            models, storage, clipboard reading, search — both platforms, no UI
Sources/SkrepkaSync/            sync protocol, wire codec, merge engine, TLS transport — both platforms
Sources/Skrepka/                the Mac app: menu bar, picker panel, SwiftUI views, platform glue
Sources/SkrepkaLinuxPlatform/   Linux clipboard backends, discovery and paste
Sources/SkrepkaDaemon/          skrepkad and the D-Bus service it offers
Sources/SkrepkaIPC/             the D-Bus interface the daemon, the CLI and the app share
Sources/SkrepkaCLI/             the skrepka command
Sources/SkrepkaLinuxUI/         skrepka-gui: the GTK 4 picker, tray and Settings
gnome-extension/                the GNOME Shell extension that forwards clipboard changes
packaging/                      systemd unit, D-Bus activation, launcher entries, icons
Tests/                          Swift Testing, one suite directory per library
```

`SkrepkaCore` and `SkrepkaSync` are plain SwiftPM libraries with no
window-server dependency, so `swift test` runs in well under a second.
`SkrepkaSync` deliberately does not depend on `SkrepkaCore`: it owns the wire
format and the merge rules, and reaches storage through a protocol the app
target conforms to. The Mac app target holds only what cannot run without a
live window.

## Quality gate

`scripts/doctor.sh` runs format check, lint, build with warnings as errors,
tests, and a dead-code scan, and is the definition of done. `--fast` skips tests
and the dead-code scan; a pre-commit hook uses that. `scripts/doctor-linux.sh`
is its Linux counterpart, and takes the same `--fast`.

Install the two external tools once:

```sh
brew install swiftlint periphery
```

Doctor skips either one with a warning if it is missing rather than failing.

Note: Periphery's upstream repository was archived in August 2026 and Homebrew
disables the formula in 2027. It is kept because nothing else finds an
unreferenced type across modules; expect to drop it eventually.

## Contributing

Bug reports and feature requests go through the
[issue templates](https://github.com/psoldunov/skrepka/issues/new/choose).
[CONTRIBUTING.md](CONTRIBUTING.md) covers what you need to build Skrepka, where
code goes, and what a pull request should carry — the short version being that
a green quality gate is the definition of done.

Found a vulnerability? Do not open a public issue.
[SECURITY.md](SECURITY.md) has the private route, and the threat model that
says what counts as one for a clipboard manager.

Everyone taking part is expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

## License

MIT — see [LICENSE](LICENSE).
