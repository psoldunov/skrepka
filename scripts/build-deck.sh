#!/usr/bin/env bash
#
# Builds an x86_64 release tarball for the Steam Deck — Skrepka's Linux
# executables, their systemd user unit and the installer that lands them under
# $HOME. Runs inside the amd64 variant of the build image because Swift on
# Linux is not a cross compiler and the Deck's Zen 2 is not aarch64.
#
#   scripts/build-deck.sh                       full build + tarball
#   SKREPKA_LINUX_ARCH=amd64 scripts/build-deck.sh   same thing, spelled out
#
# The image the amd64 build runs against is skrepka-linux:6.3-amd64. It is
# built on demand by scripts/linux-image.sh with SKREPKA_LINUX_ARCH=amd64,
# which is what this script does when the tag is missing. Under emulation on
# an arm64 host that first build takes a few minutes; subsequent runs reuse
# the cached image and only pay for what changed in the Swift sources.
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
	SKREPKA_LINUX_ARCH=amd64 scripts/linux-image.sh
fi

# `-t` only when the caller has one; CI and background invocations do not, and
# `-it` on a non-TTY dies with `input device is not a TTY`. The same shape
# scripts/linux.sh already uses.
TTY_ARGS=()
[[ -t 0 && -t 1 ]] && TTY_ARGS=(-it)

# One-shot exec into the amd64 image, with the repo mounted at its host path
# so paths in diagnostics are clickable on both sides, and the caller's uid so
# every artefact ends up owned by the host user. Matches scripts/linux.sh.
run_in_container() {
	docker run --rm ${TTY_ARGS[@]+"${TTY_ARGS[@]}"} \
		--platform linux/amd64 \
		-u "$(id -u):$(id -g)" \
		-e HOME=/tmp/skrepka-linux-home \
		-v "${REPO}:${REPO}" \
		-w "${REPO}" \
		"${IMAGE}" \
		"$@"
}

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
	run_in_container \
		swift build -c release \
		--static-swift-stdlib \
		--scratch-path "${SCRATCH}" \
		--product "${product}"
done

# `--show-bin-path` also compiles the "default target" when nothing else says
# what to build, so the flag combination has to match one of the invocations
# above or SwiftPM does a second, unrelated build to answer the question.
BIN_PATH="$(run_in_container swift build -c release \
	--static-swift-stdlib \
	--scratch-path "${SCRATCH}" \
	--show-bin-path | tr -d '\r')"

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
# glibc version the binary requires. SteamOS 3.8 ships glibc 2.38 (unverified,
# to be confirmed on the Deck); anything higher than that in this report is a
# blocker for that host. All three run inside the container so no amd64 tool
# is expected on the host.
{
	echo "# Skrepka x86_64 release — runtime probe"
	echo "# Image:   ${IMAGE}"
	echo "# Swift:   $(run_in_container swift --version 2>&1 | head -1)"
	echo "# Date:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo
	for product in "${PRODUCTS[@]}"; do
		echo "## ${product}"
		echo "### elf header"
		run_in_container bash -lc \
			"readelf -h '${BIN_PATH}/${product}' | grep -E 'Class|Machine|Type'"
		echo
		echo "### ldd"
		run_in_container ldd "${BIN_PATH}/${product}" || true
		echo
		echo "### highest GLIBC_ symbol version"
		run_in_container bash -lc \
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
LIBDIR_IN_IMAGE=/usr/lib/x86_64-linux-gnu
LIB_TAR="${STAGE_ROOT}/lib-stage.tar"
run_in_container bash -lc "cd ${LIBDIR_IN_IMAGE} && tar cf - \
	libgtk4-layer-shell.so \
	libgtk4-layer-shell.so.0 \
	libgtk4-layer-shell.so.1.3.0" > "${LIB_TAR}"
tar xf "${LIB_TAR}" -C "${STAGE}/lib"
rm -f "${LIB_TAR}"

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
the host — SteamOS Plasma sessions carry it. If the demo aborts on
"gtk_init_check", the compositor has no Wayland display advertised in
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
