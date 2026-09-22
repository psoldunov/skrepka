#!/usr/bin/env bash
#
# Builds the x86_64 Linux release assets a GitHub release carries:
#
#   build/deck/skrepka-linux-x86_64.tar.gz        what install.sh installs:
#                                                 skrepkad, skrepka, skrepka-gui,
#                                                 the unit, the launcher and
#                                                 autostart entries, the icons,
#                                                 the D-Bus activation file,
#                                                 GNOME Shell extension,
#                                                 install.sh
#   build/deck/skrepka-linux-x86_64-tools.tar.gz  the probes, picker demo, and
#                                                 Settings demo for bring-up
#   build/deck/skrepka-linux-x86_64.deb           the same payload as a .deb and
#   build/deck/skrepka-linux-x86_64.rpm           an .rpm, laid out under /usr by
#                                                 scripts/build-packages.sh
#   a .sha256 beside each                         what install.sh checks
#
# The Steam Deck is the machine they are built for. Runs in the amd64 variant of
# the build image because Swift on Linux is not a cross compiler and the Deck's
# Zen 2 is not aarch64.
#
#   scripts/build-deck.sh                       full build + tarballs + checksums
#
# Every command that runs in the image goes through scripts/linux.sh with
# SKREPKA_LINUX_ARCH=amd64, so the image tag, the --platform, the bind mount,
# the host-user mapping and the TTY decision are that script's and nowhere
# else. The image is skrepka-linux:6.3-amd64, the tag scripts/linux-image.sh
# gives the amd64 variant on every host, and this script builds it when the
# tag is missing. Under emulation on an arm64 host that first build takes a few
# minutes; subsequent runs reuse the cached image and only pay for what changed
# in the Swift sources.
#
# Everything lands in .build-linux-x86_64/ (a dedicated scratch, never shared
# with .build or .build-linux) and build/deck/. Both are covered by the
# repository's .gitignore.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO="$(pwd)"
SWIFT_VERSION="${SKREPKA_SWIFT_VERSION:-6.3}"
IMAGE="skrepka-linux:${SWIFT_VERSION}-amd64"
SCRATCH=".build-linux-x86_64"
STAGE_ROOT="build/deck"
STAGE_NAME="skrepka-linux-x86_64"
STAGE="${STAGE_ROOT}/${STAGE_NAME}"
TARBALL="${STAGE_ROOT}/${STAGE_NAME}.tar.gz"
# The tools tarball unpacks into a directory of the same name, so untarring it
# beside the release adds the probes to the same bin/ the session doc runs
# them from.
TOOLS_ROOT="${STAGE_ROOT}/tools"
TOOLS_STAGE="${TOOLS_ROOT}/${STAGE_NAME}"
TOOLS_TARBALL="${STAGE_ROOT}/${STAGE_NAME}-tools.tar.gz"

# The Deck is x86_64, so both scripts this one calls are told amd64. An
# SKREPKA_LINUX_IMAGE exported for scripts/linux.sh names the host's own image
# and would win over the amd64 tag in both of them — building and then running
# a native image as if it were the Deck's — so it goes no further than here.
export SKREPKA_LINUX_ARCH=amd64
unset SKREPKA_LINUX_IMAGE

bold() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1" >&2; }

if ! docker info > /dev/null 2>&1; then
	echo "docker is not reachable." >&2
	echo "OrbStack exposes its socket at ~/.orbstack/run/docker.sock; under a" >&2
	echo "sandbox that path has to be granted before this script can run." >&2
	exit 1
fi

# --------------------------------------------------------------------------
# Package.resolved is tracked and belongs to the macOS resolution
# --------------------------------------------------------------------------

# The Linux manifest resolves a genuinely smaller graph: it drops
# KeyboardShortcuts (the macOS app target's only dependency) and adds dbus,
# swift-algorithms, swift-nio-extras and their friends. SwiftPM rewrites
# Package.resolved to match whichever graph it just resolved, so every Linux
# run stages the file with a different `originHash` and set of pins — which
# scripts/doctor-linux.sh already handles by saving and restoring it, and
# which this script has to do too or a build-deck run leaves the tree dirty
# in a way `git diff` would notice.
RESOLVED_BACKUP=""
if [[ -f Package.resolved ]]; then
	RESOLVED_BACKUP="$(mktemp)"
	cp Package.resolved "${RESOLVED_BACKUP}"
	trap 'if [[ -n "${RESOLVED_BACKUP}" ]]; then cp "${RESOLVED_BACKUP}" Package.resolved; rm -f "${RESOLVED_BACKUP}"; fi' EXIT
fi

# --------------------------------------------------------------------------
# Image
# --------------------------------------------------------------------------

if ! docker image inspect "${IMAGE}" > /dev/null 2>&1; then
	bold "Building ${IMAGE}"
	scripts/linux-image.sh
fi

# No docker flags from here on. scripts/linux.sh decides `-it` per call, from
# that call's own stdout, and that matters below: the calls whose output is
# captured or redirected into a file get no pty, so their bytes arrive intact.
# One decision made once for the whole script got this wrong from a terminal —
# the pty turned LF into CRLF throughout the runtime report, and GNU tar
# refused to write an archive to it at all.

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------

# Each product on its own line, on purpose. `swift build --product A --product
# B` accepts the repeated flag, builds only the LAST one and exits 0 — the
# same trap docs/linux-sync/open-questions.md records under OQ-13 and the
# reason scripts/setup-linux.sh calls swift build once per product. --static-swift-stdlib
# links the Swift standard library into each binary so the Deck needs no Swift
# runtime installed; libc, gtk-4 and the rest still come from the target box.
#
# Split in two because every binary carries its own static copy of the Swift
# runtime, Foundation and ICU data — about 100 MB each before compression. The
# release tarball holds only what install.sh installs; the bring-up tools ride
# in a second one that only a hardware session downloads.
INSTALLED_PRODUCTS=(
	skrepkad
	skrepka
	skrepka-gui
)
TOOL_PRODUCTS=(
	skrepka-clip-probe
	skrepka-sync-probe
	skrepka-palette-demo
	skrepka-settings-demo
)
PRODUCTS=("${INSTALLED_PRODUCTS[@]}" "${TOOL_PRODUCTS[@]}")

for product in "${PRODUCTS[@]}"; do
	bold "Building ${product} (release, static Swift stdlib, amd64)"
	scripts/linux.sh \
		swift build -c release \
		--static-swift-stdlib \
		--scratch-path "${SCRATCH}" \
		--product "${product}"
done

# `--show-bin-path` also compiles the "default target" when nothing else says
# what to build, so the flag combination has to match one of the invocations
# above or SwiftPM does a second, unrelated build to answer the question.
BIN_PATH="$(scripts/linux.sh swift build -c release \
	--static-swift-stdlib \
	--scratch-path "${SCRATCH}" \
	--show-bin-path)"

for product in "${PRODUCTS[@]}"; do
	if [[ ! -x "${BIN_PATH}/${product}" ]]; then
		echo "error: ${BIN_PATH}/${product} is missing or not executable" >&2
		exit 1
	fi
done

# --------------------------------------------------------------------------
# Runtime probe: which system libs are needed, and how new
# --------------------------------------------------------------------------

REPORT="${STAGE_ROOT}/runtime-report.txt"
rm -rf "${STAGE_ROOT}"
mkdir -p "${STAGE}/bin" "${STAGE}/packaging" "${STAGE}/lib" "${TOOLS_STAGE}/bin"

# `readelf -h` names the ELF class and machine — under emulation this is the
# check that catches a silently-broken toolchain that produced arm64 slices
# anyway. It is used rather than `file` because the base swift image ships
# binutils but not the `file` package, and adding one apt line for a header
# read is not worth the layer. `ldd` names every .so the loader will hunt for
# on the Deck, and `objdump -T` filtered for GLIBC_ symbols names the *floor*
# glibc version the binary requires — GLIBC_2.38 for all six on 2026-09-18.
# Whether the Deck's glibc meets it is not something this script can know;
# step 0.5 of docs/linux-sync/steam-deck-session.md checks it on the Deck.
# All three run inside the container so no amd64 tool is expected on the host.
{
	echo "# Skrepka x86_64 release — runtime probe"
	echo "# Image:   ${IMAGE}"
	echo "# Swift:   $(scripts/linux.sh swift --version 2>&1 | head -1)"
	echo "# Date:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo
	for product in "${PRODUCTS[@]}"; do
		echo "## ${product}"
		echo "### elf header"
		scripts/linux.sh bash -lc \
			"readelf -h '${BIN_PATH}/${product}' | grep -E 'Class|Machine|Type'"
		echo
		echo "### ldd"
		scripts/linux.sh ldd "${BIN_PATH}/${product}" || true
		echo
		echo "### highest GLIBC_ symbol version"
		scripts/linux.sh bash -lc \
			"objdump -T '${BIN_PATH}/${product}' | grep -oE 'GLIBC_[0-9.]+' | sort -V | uniq -c | tail -5" \
			|| true
		echo
	done
} > "${REPORT}"

bold "Runtime probe written to ${REPORT}"

# --------------------------------------------------------------------------
# gtk4-layer-shell runtime bundling
# --------------------------------------------------------------------------

# SteamOS 3.8 does not ship gtk4-layer-shell — it is an optional Arch package
# (extra/gtk4-layer-shell) that no default install advertises — so the
# palette demo and the desktop app would fail at load time with
# "libgtk4-layer-shell.so.0: cannot open shared object file". The image built
# the .so from source under /usr/lib/x86_64-linux-gnu/, and shipping it beside
# the binaries with rpath $ORIGIN/../lib is the smallest thing that works
# without asking the user to unlock the read-only root. skrepka-gui also
# carries a second rpath, $ORIGIN/../lib/skrepka, for the installed copy:
# install.sh finds the bundled library in lib/ beside bin/ and copies it
# there.
#
# GTK itself is not bundled: gtk-4 is a plain KDE dependency on SteamOS
# through Plasma's GTK integration and any KDE spin has it, so the loader
# finds libgtk-4.so.1 in the default search path. It has to be 4.12 or newer,
# the oldest with every call skrepka-gui and the palette demo make, and a
# missing symbol surfaces at launch rather than in ldd. gtk4-layer-shell is the
# one library the target box may lack.
#
# The container copies them straight into the stage through the bind mount,
# as the host user, so no bytes cross docker's stdout at all. `cp -P` keeps the
# two symlinks as the relative symlinks they are.
LIBDIR_IN_IMAGE=/usr/lib/x86_64-linux-gnu
scripts/linux.sh cp -P \
	"${LIBDIR_IN_IMAGE}/libgtk4-layer-shell.so" \
	"${LIBDIR_IN_IMAGE}/libgtk4-layer-shell.so.0" \
	"${LIBDIR_IN_IMAGE}/libgtk4-layer-shell.so.1.3.0" \
	"${REPO}/${STAGE}/lib/"

# --------------------------------------------------------------------------
# Stage: binaries, install.sh, packaging, report
# --------------------------------------------------------------------------

for product in "${INSTALLED_PRODUCTS[@]}"; do
	cp "${BIN_PATH}/${product}" "${STAGE}/bin/${product}"
	chmod 0755 "${STAGE}/bin/${product}"
done
for product in "${TOOL_PRODUCTS[@]}"; do
	cp "${BIN_PATH}/${product}" "${TOOLS_STAGE}/bin/${product}"
	chmod 0755 "${TOOLS_STAGE}/bin/${product}"
done
# The palette demo finds gtk4-layer-shell through $ORIGIN/../lib as well, and
# the tools tarball has to work unpacked on its own.
cp -RP "${STAGE}/lib" "${TOOLS_STAGE}/lib"

# Debug info off, symbols kept. A release build on Linux carries full DWARF,
# which is about a third of each binary; --strip-debug drops that and leaves the
# symbol table, so a crash backtrace still names its functions. Stripped in the
# amd64 container, whose binutils understand the x86_64 ELF on any host.
bold "Stripping debug info"
scripts/linux.sh strip --strip-debug "${STAGE}/bin/"* "${TOOLS_STAGE}/bin/"*

# The stage is the payload layout install.sh documents: bin/, lib/ and
# packaging/ side by side. install.sh ships at its top, where it recognises the
# directory it sits in as a payload, so an untarred release installs with
# ./install.sh and no download — and piped from curl, the same script downloads
# this tarball and installs from it the same way.
cp "${REPO}/install.sh" "${STAGE}/install.sh"
chmod 0755 "${STAGE}/install.sh"
# The directories install.sh reads, whole: the unit, the D-Bus activation file,
# the launcher and autostart entries, and the icons. packaging/README.md is the
# one file in there install.sh does not read, and it goes too — it explains the
# rest to whoever opens the tarball. The Shell extension sits at payload root
# because GNOME installs its contents as one directory named by metadata UUID.
for directory in systemd dbus desktop autostart icons; do
	cp -R "${REPO}/packaging/${directory}" "${STAGE}/packaging/${directory}"
done
cp "${REPO}/packaging/README.md" "${STAGE}/packaging/README.md"
cp -R "${REPO}/gnome-extension" "${STAGE}/gnome-extension"
# In the tarball as well as beside it: the Deck session reads it on the Deck.
cp "${REPORT}" "${STAGE}/runtime-report.txt"

cat > "${STAGE}/README.txt" << 'DOCS'
Skrepka — Linux x86_64 release
==============================

The quickest install needs none of this: in a terminal on the machine itself
(Konsole, in the Deck's Desktop Mode), run

    curl -fsSL https://raw.githubusercontent.com/psoldunov/skrepka/master/install.sh | bash

which downloads this same tarball from the latest release, checks it and
installs it. What follows is for installing from the tarball by hand.

What is in this tarball
-----------------------

  bin/skrepkad                the clipboard-history daemon
  bin/skrepka                 the CLI
  bin/skrepka-gui             the desktop app: the tray icon, the clipboard
                              picker and Settings (pairing and devices)
  lib/libgtk4-layer-shell.so* the layer-shell library the picker needs at
                              runtime, in case the host does not have one
  install.sh                  the installer
  packaging/                  the systemd USER unit, the D-Bus activation file,
                              the launcher and autostart entries and the icons
                              install.sh writes — see packaging/README.md
  gnome-extension/            captures native Wayland copies inside GNOME Shell;
                              installed and enabled automatically for GNOME
  runtime-report.txt          the shared libraries and glibc version each binary
                              needs, recorded when it was built

The probes and the palette demo are a separate asset,
skrepka-linux-x86_64-tools.tar.gz. Untar it in the same place as this one and
they land in this bin/.

Installing from the tarball
---------------------------

    tar xzf skrepka-linux-x86_64.tar.gz
    cd skrepka-linux-x86_64
    ./install.sh

./install.sh --uninstall reverses it.

The installer places skrepkad, skrepka and skrepka-gui into ~/.local/bin, the
systemd user unit into ~/.config/systemd/user, a private copy of
libgtk4-layer-shell into ~/.local/lib/skrepka, a launcher entry named
"Skrepka" into ~/.local/share/applications, the app's icons into
~/.local/share/icons, an autostart entry into ~/.config/autostart, a GNOME
capture extension into ~/.local/share/gnome-shell/extensions, and a D-Bus
activation file into ~/.local/share/dbus-1/services so the daemon starts
whenever anything asks for it. Those are the defaults: an absolute
XDG_BIN_HOME, XDG_CONFIG_HOME or XDG_DATA_HOME moves its part to wherever it
points. Nothing needs root.

Running the desktop app
-----------------------

    ./bin/skrepka-gui

Runs in place from the untarred tarball and opens the clipboard picker; the
tray icon stays. Once installed it starts with your session, and the
application launcher's "Skrepka" opens the picker. Settings is in the tray
menu and behind the picker's gear button. It needs the host's GTK to be 4.12
or newer.
DOCS

cat > "${TOOLS_STAGE}/TOOLS.txt" << 'DOCS'
Skrepka — Linux x86_64 bring-up tools
=====================================

Not needed to use Skrepka. These are for testing it on new hardware, as
docs/linux-sync/steam-deck-session.md does.

  bin/skrepka-clip-probe      a headless clipboard probe (Phase 5 bring-up)
  bin/skrepka-sync-probe      a headless sync peer (Phase 6 smoke test)
  bin/skrepka-palette-demo    a hand-driven picker smoke test
                              (Phase 7 step 1 validation)
  bin/skrepka-settings-demo   Settings against a fake daemon for screenshots
  lib/libgtk4-layer-shell.so* what the palette demo needs, if the host lacks it

Untar it next to skrepka-linux-x86_64.tar.gz: both unpack into
skrepka-linux-x86_64/, so the tools land beside the release's own binaries.

Running the palette demo
------------------------

    ./bin/skrepka-palette-demo

The binary is linked with rpath $ORIGIN/../lib, so libgtk4-layer-shell is
found beside it without exporting anything. gtk-4 itself has to come from
the host — SteamOS Plasma sessions carry it. If the demo prints
"could not open display" and exits, no Wayland display is advertised in
$WAYLAND_DISPLAY; launch it from Desktop Mode after logging in.
DOCS

# --------------------------------------------------------------------------
# Pack
# --------------------------------------------------------------------------

# `--sort=name` and a deterministic `--mtime` would be nice for reproducible
# tarballs; GNU tar has --sort but BSD tar (macOS) does not, and this script
# runs on both. COPYFILE_DISABLE and --no-xattrs keep macOS's AppleDouble
# `._` files and extended attributes out of it: GNU tar on the Deck would
# otherwise unpack the first as junk files and warn about the second.
COPYFILE_DISABLE=1 tar --no-xattrs -czf "${TARBALL}" -C "${STAGE_ROOT}" "${STAGE_NAME}"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "${TOOLS_TARBALL}" -C "${TOOLS_ROOT}" "${STAGE_NAME}"

# The checksum install.sh downloads beside the tarball, in `sha256sum` format
# with the bare asset name, so it can also be checked by hand with
# `sha256sum -c` from the directory both were downloaded into.
write_checksum() {
	local name
	name="$(basename "$1")"
	if command -v sha256sum > /dev/null 2>&1; then
		(cd "${STAGE_ROOT}" && sha256sum "${name}") > "$1.sha256"
	else
		(cd "${STAGE_ROOT}" && shasum -a 256 "${name}") > "$1.sha256"
	fi
}
write_checksum "${TARBALL}"
write_checksum "${TOOLS_TARBALL}"

green "✓ ${TARBALL} ($(du -h "${TARBALL}" | awk '{print $1}'))"
green "✓ ${TOOLS_TARBALL} ($(du -h "${TOOLS_TARBALL}" | awk '{print $1}'))"
green "✓ a .sha256 beside each"

# --------------------------------------------------------------------------
# The .deb and the .rpm, from the stage just packed
# --------------------------------------------------------------------------

# Its own script, because it builds nothing: it lays the stage out under /usr
# and hands that tree to nFPM, and re-running it alone is how a change to
# packaging/nfpm.yaml is tried without another twenty-minute build.
scripts/build-packages.sh

echo
echo "Runtime report:  ${REPORT}"
echo "Stage:           ${STAGE}"
echo
echo "Attach all eight files to the GitHub release. Then, on the Deck, in Konsole:"
echo "  curl -fsSL https://raw.githubusercontent.com/psoldunov/skrepka/master/install.sh | bash"
echo
echo "Before the release is published, copy the tarball over any way you like and"
echo "run ./install.sh from inside it once untarred."
