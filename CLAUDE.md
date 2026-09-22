# Skrepka

A clipboard-history manager for macOS 26 and Linux. On the Mac: menu-bar
daemon, no Dock icon, a global hotkey opens a Liquid Glass picker panel over
the frontmost app. On Linux: the `skrepkad` daemon, the `skrepka` CLI, and
`skrepka-gui` — tray icon, picker and Settings in one GTK 4 process. Paired
machines on either platform sync over the local network.

Linux is supported on KDE Plasma (tested on a real Steam Deck), GNOME, sway and
X11 — but GNOME, sway and X11 have only ever run in headless containers. Keep
that distinction in anything you write about them.

## Build and run

```
scripts/setup.sh      # resolve dependencies, warm the debug build
scripts/run.sh        # build, bundle, sign, launch
scripts/bundle.sh     # build build/Skrepka.app only
scripts/notarize.sh   # build, sign, notarize, staple — for builds you send out
scripts/doctor.sh     # the quality gate — run after every change
scripts/make-icon.sh  # redraw AppIcon.icns from scripts/make-icon.swift
scripts/regenerate-wayland-protocols.sh  # regenerate Sources/CWaylandProtocols from its XML
scripts/setup-linux.sh  # build skrepkad, skrepka and skrepka-gui, install into ~/.local — Linux only
```

The Linux side has its own gate and its own entry points, and neither is
reachable from a Mac without the container:

```
scripts/linux.sh <command>   # run anything inside the Linux build image
scripts/doctor-linux.sh      # the Linux quality gate
scripts/build-deck.sh        # the x86_64 release tarball + .sha256 for a GitHub release
scripts/screenshot-settings.sh  # the Settings window and the picker under headless sway
scripts/kde-image.sh         # a headless Plasma 6.4.3 image built from SteamOS 3.8's packages
scripts/kde.sh <command>     # run, screenshot, type or click inside that Plasma session
scripts/kde-smoke.sh         # tray, shortcut, picker and click-away checks against a tarball
scripts/gnome-image.sh       # an Ubuntu 26.04 / GNOME 50 headless test image
scripts/gnome.sh <command>   # run, screenshot, type, click or eval inside GNOME
scripts/gnome-smoke.sh       # install, capture, tray, shortcut, picker and paste checks
```

The KDE image is the Steam Deck's Desktop Mode without a Deck: the same KWin,
plasmashell, kglobalacceld and portals, down to the package release. Run
`SKREPKA_TARBALL=build/deck/skrepka-linux-x86_64.tar.gz scripts/kde-smoke.sh`
after `scripts/build-deck.sh` before asking anyone to try a build on real
hardware. It renders without a GPU, so blur and other OpenGL-only effects are
missing from its screenshots.

The GNOME image is Ubuntu 26.04 LTS's GNOME 50 session: Mutter runs headless,
Ubuntu's AppIndicator extension hosts the tray, and GNOME's portal backends
handle global shortcuts and remote desktop. It uses Mesa llvmpipe under
OrbStack's amd64 Rosetta translation, so GPU-only Shell effects are not
representative, but application surfaces, focus, shortcuts and portal consent
are exercised through the real compositor.

`install.sh`, at the repository root, is the release installer — what a user
runs, with `curl … | bash`, to download the x86_64 tarball from a GitHub
release, check its SHA-256 and install it. It owns every rule about where files
go, how the unit is enabled and what `--uninstall` removes.
`scripts/setup-linux.sh` is the developer's path: it builds from a checkout and
hands the result to `install.sh --from-dir`, so the two cannot drift. Change
file placement in `install.sh`, building in `setup-linux.sh`.

Together they are the no-root install path for the Linux daemon
(`skrepkad`) and its CLI (`skrepka`): binaries into `~/.local/bin`, a systemd
**user** unit into `~/.config/systemd/user`, a D-Bus activation file so any
client starts the daemon on demand, the GNOME Wayland capture extension into
`~/.local/share/gnome-shell/extensions`, and — when the build has it — the GTK4
desktop app (`skrepka-gui`: tray icon, picker and Settings in one process) with
its launcher and autostart entries, the macOS app icon in the hicolor theme and,
from the Deck tarball, a private `libgtk4-layer-shell` in `~/.local/lib/skrepka`. A user
unit rather than a system one because the daemon needs the session bus and the
Wayland or X11 display, and a system unit has neither. `--uninstall` reverses it and deliberately
leaves the history database and the device key alone — deleting the key
un-pairs the machine from every peer, which is not something an uninstall
should do silently.

`scripts/bundle.sh` signs without a secure timestamp, which is fine locally and
fatal for distribution: the notary service rejects it, and the signature dies
when the Developer ID certificate expires. `scripts/notarize.sh` sets
`SKREPKA_NOTARIZE=1`, which turns the timestamp on and makes an ad-hoc fallback
a hard error.

Notarization credentials come from `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID` and
`APPLE_API_ISSUER` — an App Store Connect API key, the same three variables the
Ensemblr repo's `forge.config.ts` reads, so one `.p8` covers both projects and
CI needs no keychain. Set all three or none; a partial set is an error rather
than a silent fallback. With none set it falls back to a notarytool keychain
profile, `xcrun notarytool store-credentials skrepka`, which wants an
app-specific password instead.

`notarize.sh` reads those three from `.env` in the repository root by itself —
copy `.env.example`, or point `SKREPKA_ENV_FILE` at another repo's `.env`
instead of duplicating a key path. The file is parsed as `KEY=VALUE` data, never
sourced, so nothing in it executes; anything already in the environment wins
over it.

Either way the credential is checked before anything is built — the universal
build and the timestamped signature are minutes of work to spend on a missing
`.p8`.

`scripts/bundle.sh` builds for the host architecture alone.
`SKREPKA_UNIVERSAL=1` builds arm64 + x86_64 instead, and `notarize.sh` sets it:
four Intel Macs still run macOS 26, and an arm64-only `.app` will not launch on
one. The script verifies with `lipo -archs` that every requested slice landed
before it signs.

`bundle.sh` and `notarize.sh` reveal what they built in Finder when they finish.
Set `SKREPKA_REVEAL=0` to suppress it — `run.sh` does, because it launches the
app, and `notarize.sh` does for its inner `bundle.sh` call, because that `.app`
has no ticket yet.

The app icon, the menu bar mark and the in-app artwork are all one drawing,
split across four files in `Sources/SkrepkaCore/Branding/`:

- `PaperclipMark.swift` — the artwork. The coordinate table, transcribed from
  `scripts/paperclip.svg`. **This is the file to edit to change the mark.**
- `MarkPath.swift` — the portable path types the table is written in, plus
  `MarkPath+Bounds.swift` for the bounding box both renderers fit against.
  Platform-free, so Linux can draw the same mark with Cairo (OQ-12).
- `PaperclipPath.swift` — the Core Graphics renderer, and nothing else. Fenced
  with `#if canImport(CoreGraphics)`.

`make-icon.sh` *compiles* `make-icon.swift` with all four branding source files linked in beside it,
so plain `swift scripts/make-icon.swift` no longer works — it takes one file.
Change the mark in one place.

Every script that runs Swift on the Mac pins `DEVELOPER_DIR` to
`/Applications/Xcode.app/Contents/Developer`. The Linux ones — `linux.sh`,
`linux-image.sh`, `doctor-linux.sh`, `build-deck.sh`, `setup-linux.sh`,
`install.sh` — do not:
their Swift runs inside the build image or on a Linux host, with no Xcode to pin.
Do not build with a bare `swift build`: `xcode-select -p` points at
CommandLineTools, whose toolchain ships no `libSwiftDataMacros.dylib`, so `@Model`
in `Sources/SkrepkaCore/Store/` fails to expand. Mixing the two toolchains also
invalidates `.build/` and forces a full rebuild every time you switch.

`scripts/doctor.sh` is the definition of done. Launch with `scripts/run.sh`, not
by executing the binary: TCC attributes permissions to the responsible process,
so a shell-launched binary inherits the terminal's grants instead of exercising
the real permission path.

## Layout

- `Sources/SkrepkaCore/` — models, storage, pasteboard, search. Testable, no UI.
  Compiles on both platforms.
- `Sources/SkrepkaSync/` — sync protocol, wire codec, merge engine, TLS. Both
  platforms.
- `Sources/Skrepka/` — the Mac app: shell, panel, SwiftUI views, platform glue.
- `Sources/SkrepkaLinuxPlatform/`, `SkrepkaDaemon/`, `SkrepkaIPC/`,
  `SkrepkaCLI/`, `SkrepkaLinuxUI/` — the Linux clipboard backends, `skrepkad`,
  its D-Bus interface, `skrepka`, and `skrepka-gui`.
- `gnome-extension/` — the GNOME Shell extension that forwards clipboard
  changes to `skrepkad`.
- `Tests/` — Swift Testing, one suite directory per library.

## Rules

@.claude/rules/verify-against-docs.md
@.claude/rules/swift-conventions.md
