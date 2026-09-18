#!/usr/bin/env bash
#
# Builds an x86_64 release tarball for the Steam Deck — Skrepka's Linux
# executables, their systemd user unit and the installer that lands them under
# $HOME. Runs inside the amd64 variant of the build image because Swift on
# Linux is not a cross compiler and the Deck's Zen 2 is not aarch64.
#
#   scripts/build-deck.sh                       full build + tarball
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
# reason scripts/install.sh calls swift build twice. --static-swift-stdlib
# links the Swift standard library into each binary so the Deck needs no Swift
# runtime installed; libc, gtk-4 and the rest still come from the target box.
PRODUCTS=(
	skrepkad
	skrepka
	skrepka-clip-probe
	skrepka-sync-probe
	skrepka-palette-demo
)

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
mkdir -p "${STAGE}/bin" "${STAGE}/scripts" "${STAGE}/packaging/systemd" "${STAGE}/lib"

# `readelf -h` names the ELF class and machine — under emulation this is the
# check that catches a silently-broken toolchain that produced arm64 slices
# anyway. It is used rather than `file` because the base swift image ships
# binutils but not the `file` package, and adding one apt line for a header
# read is not worth the layer. `ldd` names every .so the loader will hunt for
# on the Deck, and `objdump -T` filtered for GLIBC_ symbols names the *floor*
# glibc version the binary requires — GLIBC_2.38 for all five on 2026-09-18.
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
# palette demo would fail at load time with "libgtk4-layer-shell.so.0: cannot
# open shared object file". The image built the .so from source under
# /usr/lib/x86_64-linux-gnu/, and shipping it beside the binary with rpath
# $ORIGIN/../lib is the smallest thing that works without asking the user to
# unlock the read-only root.
#
# GTK itself is not bundled: gtk-4 is a plain KDE dependency on SteamOS
# through Plasma's GTK integration and any KDE spin has it, so the loader
# finds libgtk-4.so.1 in the default search path. gtk4-layer-shell is the
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
# Stage: binaries, install.sh, unit, marker Package.swift
# --------------------------------------------------------------------------

for product in "${PRODUCTS[@]}"; do
	cp "${BIN_PATH}/${product}" "${STAGE}/bin/${product}"
	chmod 0755 "${STAGE}/bin/${product}"
done

# install.sh looks for ${dirname($script)}/../Package.swift and
# ${dirname($script)}/../packaging/systemd/skrepkad.service to recognise a
# checkout; shipping the two makes the tarball self-contained without asking
# the script to grow another mode.
cp "${REPO}/scripts/install.sh" "${STAGE}/scripts/install.sh"
chmod 0755 "${STAGE}/scripts/install.sh"
cp "${REPO}/packaging/systemd/skrepkad.service" "${STAGE}/packaging/systemd/skrepkad.service"
cp "${REPO}/Package.swift" "${STAGE}/Package.swift"

cat > "${STAGE}/README.txt" << 'DOCS'
Skrepka — Linux x86_64 release
==============================

What is in this tarball
-----------------------

  bin/skrepkad                the clipboard-history daemon
  bin/skrepka                 the CLI
  bin/skrepka-clip-probe      a headless clipboard probe (Phase 5 bring-up)
  bin/skrepka-sync-probe      a headless sync peer (Phase 6 smoke test)
  bin/skrepka-palette-demo    a hand-driven picker smoke test
                              (Phase 7 step 1 validation)
  lib/libgtk4-layer-shell.so* the layer-shell library the palette demo needs
                              at runtime, in case the host does not have one
  scripts/install.sh          the installer
  packaging/systemd/skrepkad.service   the systemd USER unit install.sh writes
  Package.swift               a marker install.sh looks for; not built

Installing on the Steam Deck
----------------------------

    tar xzf skrepka-linux-x86_64.tar.gz
    cd skrepka-linux-x86_64
    ./scripts/install.sh --from-build ./bin

The installer places skrepkad and skrepka into ~/.local/bin, and the systemd
user unit into ~/.config/systemd/user. Nothing is written outside $HOME and
nothing needs root.

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
# runs on both. A plain tar is enough for a hand-carried release.
tar czf "${TARBALL}" -C "${STAGE_ROOT}" "${STAGE_NAME}"

SIZE=$(du -h "${TARBALL}" | awk '{print $1}')
green "✓ ${TARBALL} (${SIZE})"
echo
echo "Runtime report:  ${REPORT}"
echo "Stage:           ${STAGE}"
echo
echo "Copy to the Deck and untar:"
echo "  scp ${TARBALL} deck@<deck-address>:~/"
echo "  ssh deck@<deck-address> 'tar xzf ${STAGE_NAME}.tar.gz && cd ${STAGE_NAME} && ./scripts/install.sh --from-build ./bin'"
