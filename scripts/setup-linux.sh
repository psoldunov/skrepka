#!/usr/bin/env bash
#
# Builds Skrepka's Linux daemon, CLI and Settings window from this checkout and
# installs them into your home directory — the developer's path on a Linux box.
#
#   scripts/setup-linux.sh                 build in release and install
#   scripts/setup-linux.sh --uninstall     reverse it
#
# To install a released build without a toolchain, use install.sh at the root
# of the repository instead; it downloads the release from GitHub and needs
# nothing but curl. The two are separate on purpose: this script owns building,
# and install.sh owns where the files go. This one compiles, lays the result out
# the way the release tarball is laid out, and hands that directory to
# `install.sh --from-dir` — so both routes put files in exactly the same places,
# rewrite the unit and the launcher entry the same way, and uninstall the same
# way.
#
# Runs on the Linux machine itself, with a Swift 6.3 toolchain on PATH. From a
# Mac, scripts/linux.sh runs it inside the build image, where there is no
# systemd user instance and install.sh says so rather than failing.

set -euo pipefail

cd "$(dirname "$0")/.."
REPOSITORY="$(pwd -P)"
INSTALLER="${REPOSITORY}/install.sh"

DAEMON_NAME="skrepkad"
CLI_NAME="skrepka"
SETTINGS_NAME="skrepka-settings"
# The oldest GTK whose API the Settings window uses throughout:
# gtk_css_provider_load_from_string and gtk_list_box_remove_all are 4.12.
GTK_REQUIREMENT="gtk4 >= 4.12"

if [[ -t 1 ]]; then
	bold() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
	yellow() { printf '\033[33m%s\033[0m\n' "$1" >&2; }
else
	bold() { printf '\n▸ %s\n' "$1"; }
	yellow() { printf '%s\n' "$1" >&2; }
fi

usage() {
	cat << 'USAGE'
Builds skrepkad, skrepka and skrepka-settings from this checkout in release and
installs them into your home directory with ./install.sh --from-dir.

Usage:
  scripts/setup-linux.sh              build and install
  scripts/setup-linux.sh --uninstall  stop and remove what install.sh installed
  scripts/setup-linux.sh --help       this message

The Settings window is built only when pkg-config finds GTK 4.12 or newer and
gtk4-layer-shell; without them the daemon and the CLI install alone.

No toolchain? ./install.sh downloads the released x86_64 build instead.
USAGE
}

case "${1:-}" in
	"") ;;
	--help | -h)
		usage
		exit 0
		;;
	--uninstall)
		exec "${INSTALLER}" --uninstall
		;;
	*)
		echo "error: unknown argument: $1" >&2
		echo "try: scripts/setup-linux.sh --help" >&2
		exit 1
		;;
esac

if ! command -v swift > /dev/null 2>&1; then
	echo "error: swift is not on PATH, and there is nothing to build with." >&2
	echo "Install a Swift 6.3 toolchain from https://swift.org/install/linux/," >&2
	echo "or run ./install.sh to install the released build instead." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

bold "Building (release)"
# One invocation per product on purpose, and merging them would silently
# install a stale daemon. `swift build --product A --product B` accepts the
# repeated flag, builds only the LAST one and exits 0 — the same trap
# docs/linux-sync/open-questions.md records for --target under OQ-13, and the
# reason scripts/doctor-linux.sh builds a single umbrella product.
swift build -c release --product "${DAEMON_NAME}"
swift build -c release --product "${CLI_NAME}"

# The Settings window is the only product that links GTK4 and gtk4-layer-shell,
# so it is the only one whose build can fail on a machine that is otherwise
# fine. Building it is gated on both -dev packages being visible to pkg-config —
# GTK at the version its API needs, so an older one is a note here rather than
# a screen of compiler errors — and a machine without them gets the daemon and
# the CLI and a note.
BUILT_SETTINGS=0
if command -v pkg-config > /dev/null 2>&1 \
	&& pkg-config --exists "${GTK_REQUIREMENT}" gtk4-layer-shell-0; then
	# A failed build is a skipped Settings window, not a failed install: under
	# `set -e` a bare failure here would abort before the daemon and the CLI
	# built above were installed.
	if swift build -c release --product "${SETTINGS_NAME}"; then
		BUILT_SETTINGS=1
	else
		yellow "skipping ${SETTINGS_NAME}: its build failed, see the output above."
		yellow "  The daemon and the CLI are installed regardless."
	fi
else
	yellow "skipping ${SETTINGS_NAME}: pkg-config cannot find ${GTK_REQUIREMENT} and gtk4-layer-shell-0."
	yellow "  Install their development packages and re-run to get the Settings window."
fi

BIN_PATH="$(swift build -c release --show-bin-path)"

# ---------------------------------------------------------------------------
# Stage and hand off
# ---------------------------------------------------------------------------

# The payload install.sh expects: bin/ and packaging/, laid out as the release
# tarball lays them out. Symlinks, not copies — install.sh copies with
# `install`, which follows them. No lib/: a source build links the system's
# gtk4-layer-shell, and install.sh removes a private copy an earlier release
# install left behind so it cannot shadow that one.
#
# skrepka-settings is staged only if it was built in this run. A leftover binary
# from an earlier build, on a machine that can no longer build it, would be
# stale against the daemon installed beside it.
STAGE="$(mktemp -d)"
# The stage holds only symlinks this run made, so removing it recursively is
# bounded to them. Called rather than exec'd below, so this trap still runs.
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${STAGE}/bin"
ln -s "${BIN_PATH}/${DAEMON_NAME}" "${STAGE}/bin/${DAEMON_NAME}"
ln -s "${BIN_PATH}/${CLI_NAME}" "${STAGE}/bin/${CLI_NAME}"
if [[ "${BUILT_SETTINGS}" -eq 1 ]]; then
	ln -s "${BIN_PATH}/${SETTINGS_NAME}" "${STAGE}/bin/${SETTINGS_NAME}"
fi
ln -s "${REPOSITORY}/packaging" "${STAGE}/packaging"

"${INSTALLER}" --from-dir "${STAGE}"
