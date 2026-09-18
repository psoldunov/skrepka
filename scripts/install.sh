#!/usr/bin/env bash
#
# Installs Skrepka's Linux daemon, CLI and Settings window into the user's home
# directory.
#
#   scripts/install.sh                     build from this checkout and install
#   scripts/install.sh --from-build DIR    install binaries already built in DIR
#   scripts/install.sh --uninstall         reverse it
#   curl -fsSL <raw-url>/scripts/install.sh | bash
#
# By default everything lands under $HOME; an absolute $XDG_BIN_HOME,
# $XDG_CONFIG_HOME or $XDG_DATA_HOME moves its part to wherever it points.
# Nothing asks for root, and no package manager is involved:
#
#   ~/.local/bin/skrepkad            the daemon      ($XDG_BIN_HOME is honoured)
#   ~/.local/bin/skrepka             the CLI
#   ~/.local/bin/skrepka-settings    the GTK4 Settings window (optional)
#   ~/.local/lib/skrepka/libgtk4-layer-shell.so.0
#                                    a private copy of that library, only from a
#                                    build that bundles one (the Deck tarball)
#   ~/.local/share/applications/dev.soldunov.Skrepka.Settings.desktop
#                                    the launcher entry for the Settings window
#                                    ($XDG_DATA_HOME is honoured)
#   ~/.config/systemd/user/skrepkad.service          ($XDG_CONFIG_HOME too)
#
# skrepka-settings is optional because it is the one piece that needs GTK4 and
# gtk4-layer-shell. A headless box with only the daemon and the CLI is a
# legitimate install, so a build without it — or a machine that cannot build it —
# skips it with a note instead of failing.
#
# That layout is a decision recorded in docs/linux-sync/open-questions.md as
# D-10, and the reason is SteamOS: its root filesystem is read-only,
# `steamos-readonly disable` is undone by the next atomic OS update, and with
# systemd-sysext extensions merged /usr stays read-only even after disabling it.
# A .deb or .rpm has nowhere to land there. /home survives OS updates, so the
# installer writes only into /home. This is not a Steam Deck script, though —
# it is the no-root install path for any distribution.
#
# What it deliberately does NOT touch: ~/.local/share/skrepka. The history
# database and the device key live there, the daemon creates that directory
# itself with the modes it needs (0700 for the directory, 0600 for the key),
# and an installer that pre-creates it at the wrong mode is a real exposure
# rather than a tidiness question. --uninstall leaves it alone too, and says
# where it is instead: deleting device.key un-pairs this machine from every
# peer it has ever synced with, and that is not something an uninstall should
# do behind the user's back.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants and paths
# ---------------------------------------------------------------------------

UNIT_NAME="skrepkad.service"
DAEMON_NAME="skrepkad"
CLI_NAME="skrepka"
SETTINGS_NAME="skrepka-settings"
# The oldest GTK whose API the Settings window uses throughout:
# gtk_css_provider_load_from_string and gtk_list_box_remove_all are 4.12.
GTK_REQUIREMENT="gtk4 >= 4.12"
DESKTOP_NAME="dev.soldunov.Skrepka.Settings.desktop"
LAYER_SHELL_LIBRARY="libgtk4-layer-shell.so.0"
REPOSITORY_URL="${SKREPKA_REPOSITORY_URL:-https://github.com/psoldunov/skrepka.git}"

# An empty or relative XDG variable is treated as unset. That is the XDG base
# directory specification's own rule — "if an implementation encounters a
# relative path in any of these variables it should consider the path invalid
# and ignore it" — and it is the rule SessionPaths.swift already applies to
# $XDG_DATA_HOME, so the installer and the daemon agree about where things go.
xdg_directory() {
	local value="$1" fallback="$2"
	if [[ -n "${value}" && "${value}" == /* ]]; then
		printf '%s' "${value}"
	else
		printf '%s' "${fallback}"
	fi
}

if [[ -z "${HOME:-}" ]]; then
	echo "error: \$HOME is not set; this installer has nowhere to install to." >&2
	exit 1
fi

BIN_DIR="$(xdg_directory "${XDG_BIN_HOME:-}" "${HOME}/.local/bin")"
CONFIG_HOME="$(xdg_directory "${XDG_CONFIG_HOME:-}" "${HOME}/.config")"
DATA_HOME="$(xdg_directory "${XDG_DATA_HOME:-}" "${HOME}/.local/share")"
UNIT_DIR="${CONFIG_HOME}/systemd/user"
DESKTOP_DIR="${DATA_HOME}/applications"
STATE_DIR="${DATA_HOME}/skrepka"

# The private library directory is computed from BIN_DIR, not from $HOME,
# because it has to match what the skrepka-settings binary was linked with: an
# rpath of $ORIGIN/../lib/skrepka, which the dynamic loader resolves relative to
# the directory the binary sits in. With the default BIN_DIR that is
# ~/.local/lib/skrepka; with XDG_BIN_HOME=/opt/me/bin it is /opt/me/lib/skrepka,
# and a copy left in ~/.local/lib would never be found.
PRIVATE_LIB_DIR="$(dirname "${BIN_DIR}")/lib/skrepka"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# Colour only when stdout is a terminal. Piped into a file or a CI log, escape
# codes are noise, and `curl | bash` is exactly the case where the output is
# read through something else often enough to matter.
if [[ -t 1 ]]; then
	bold() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
	green() { printf '\033[32m%s\033[0m\n' "$1"; }
	yellow() { printf '\033[33m%s\033[0m\n' "$1" >&2; }
else
	bold() { printf '\n▸ %s\n' "$1"; }
	green() { printf '%s\n' "$1"; }
	yellow() { printf '%s\n' "$1" >&2; }
fi

usage() {
	cat << 'USAGE'
Installs Skrepka's Linux daemon (skrepkad) and CLI (skrepka) into your home
directory, plus a systemd user unit that starts the daemon with your graphical
session, and the Settings window (skrepka-settings) with a launcher entry when
the build has one. No root, no package manager, and by default nothing
installed outside $HOME.

Usage:
  install.sh                    build this checkout in release and install
  install.sh --from-build DIR   install the binaries already built in DIR
  install.sh --uninstall        stop and remove the unit, binaries and entry
  install.sh --help             this message

The Settings window needs GTK 4.12 or newer and gtk4-layer-shell. Building from
a checkout, it is built only when pkg-config finds both; with --from-build, only
when DIR holds a skrepka-settings. Otherwise it is skipped and the rest still
installs.

Where things land (XDG_BIN_HOME, XDG_CONFIG_HOME and XDG_DATA_HOME are
honoured when they hold an absolute path):

  ~/.local/bin/skrepkad, ~/.local/bin/skrepka, ~/.local/bin/skrepka-settings
  ~/.local/lib/skrepka/libgtk4-layer-shell.so.0  a private copy, only when the
                             build bundles one (../lib beside DIR); it sits at
                             ../lib/skrepka relative to the bin directory
  ~/.local/share/applications/dev.soldunov.Skrepka.Settings.desktop
  ~/.config/systemd/user/skrepkad.service
  ~/.local/share/skrepka/  — history and device key, created by the daemon,
                             never touched by this script or by --uninstall

Environment:
  SKREPKA_REPOSITORY_URL  clone source when run outside a checkout
                          (default: https://github.com/psoldunov/skrepka.git)
USAGE
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

MODE="install"
FROM_BUILD=""

while (($#)); do
	case "$1" in
		--help | -h)
			usage
			exit 0
			;;
		--uninstall)
			MODE="uninstall"
			shift
			;;
		--from-build)
			if [[ -z "${2:-}" ]]; then
				echo "error: --from-build needs a directory." >&2
				exit 1
			fi
			FROM_BUILD="$2"
			shift 2
			;;
		--from-build=*)
			FROM_BUILD="${1#--from-build=}"
			shift
			;;
		*)
			echo "error: unknown argument: $1" >&2
			echo "try: install.sh --help" >&2
			exit 1
			;;
	esac
done

# ---------------------------------------------------------------------------
# systemd user instance
# ---------------------------------------------------------------------------

# Detected rather than assumed. `systemctl --user` needs a running per-user
# manager to talk to, and there are three ordinary ways not to have one: a
# container, a distribution that is not systemd at all, and an ssh session on a
# host without lingering enabled. In all three the install still succeeds — the
# binaries and the unit file are on disk and correct — and the only honest
# thing to do is say which two commands to run by hand later.
#
# `systemctl --user show` rather than `is-system-running`: show fails cleanly
# when there is no bus to reach, whereas is-system-running answers "degraded"
# or "offline" and exits non-zero for reasons that have nothing to do with
# whether a manager exists.
has_systemd_user_instance() {
	command -v systemctl > /dev/null 2>&1 \
		&& systemctl --user show --property=Version > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Desktop entry
# ---------------------------------------------------------------------------

# Refreshes the launcher's cache of desktop entries so a new or removed entry is
# visible without a re-login. Absent on plenty of systems (it ships with
# desktop-file-utils) and its failure changes nothing that matters — desktops
# that watch the directory pick the file up regardless — so it is best effort:
# the exit status is ignored on purpose.
refresh_desktop_database() {
	if command -v update-desktop-database > /dev/null 2>&1; then
		update-desktop-database "${DESKTOP_DIR}" > /dev/null 2>&1 || true
	fi
}

# Prints $1 as the program path of a Desktop Entry `Exec=` value, per the
# freedesktop Desktop Entry Specification, "The Exec key". Returns 1, printing
# nothing, for a path the key cannot hold at all.
#
# The rules, as the specification states them:
#   - the program path may not contain "=";
#   - an argument holding a reserved character (space, tab, newline, ", ', \,
#     <, >, ~, |, &, ;, $, *, ?, #, ( ) or `) must be quoted with double quotes;
#   - inside the quotes, ", `, $ and \ are each escaped with a backslash — and
#     because the general string-value rule un-escapes "\\" first, that
#     backslash has to be written twice: a literal backslash is four characters
#     in the file and a literal dollar sign is "\\$";
#   - a literal "%" is "%%", quoted or not, because "%" starts a field code.
# Newlines and tabs are refused instead of escaped: a newline would end the
# line the value lives on, and no real bin directory has either.
desktop_exec_quote() {
	local path="$1" out="" char needs_quotes=0 index
	if [[ "${path}" == *=* || "${path}" == *$'\n'* || "${path}" == *$'\t'* ]]; then
		return 1
	fi
	if [[ ! "${path}" =~ ^[A-Za-z0-9/._+:@,%-]+$ ]]; then
		needs_quotes=1
	fi
	for ((index = 0; index < ${#path}; index++)); do
		char="${path:index:1}"
		case "${char}" in
			'"' | '`' | '$')
				out+="\\\\${char}"
				;;
			'\')
				# Its own case: the escape is the character itself, so it is
				# four backslashes and not two in front of one.
				out+='\\\\'
				;;
			'%')
				out+="%%"
				;;
			*)
				out+="${char}"
				;;
		esac
	done
	if [[ "${needs_quotes}" -eq 1 ]]; then
		printf '"%s"' "${out}"
	else
		printf '%s' "${out}"
	fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if [[ "${MODE}" == "uninstall" ]]; then
	bold "Removing Skrepka"

	if has_systemd_user_instance; then
		# `|| true` on both: disabling a unit that was never enabled, or one
		# whose file is already gone, exits non-zero, and neither is a failure
		# of this script.
		systemctl --user disable --now "${UNIT_NAME}" > /dev/null 2>&1 || true
		systemctl --user reset-failed "${UNIT_NAME}" > /dev/null 2>&1 || true
	else
		yellow "no systemd user instance here; skipping stop and disable"
	fi

	# Named files only, never a directory, and never a wildcard. Every path is
	# built from BIN_DIR/UNIT_DIR, both of which were derived above from an
	# absolute-or-fallback rule, so none of them can collapse to "/" or to an
	# empty string and take a home directory with them.
	for path in \
		"${BIN_DIR}/${DAEMON_NAME}" \
		"${BIN_DIR}/${CLI_NAME}" \
		"${BIN_DIR}/${SETTINGS_NAME}" \
		"${DESKTOP_DIR}/${DESKTOP_NAME}" \
		"${PRIVATE_LIB_DIR}/${LAYER_SHELL_LIBRARY}" \
		"${UNIT_DIR}/${UNIT_NAME}"; do
		# -L as well as -e: a dangling symlink at one of these paths is still
		# ours to remove, and -e alone would step over it.
		if [[ -e "${path}" || -L "${path}" ]]; then
			rm -f "${path}"
			echo "removed ${path}"
		fi
	done

	# rmdir, never rm -r: it removes the private library directory only when
	# nothing is left in it, so a file the user put there survives and so does
	# every other directory. Failing because the directory is absent or not
	# empty is the expected outcome, hence `|| true`.
	if [[ -d "${PRIVATE_LIB_DIR}" ]]; then
		rmdir "${PRIVATE_LIB_DIR}" 2> /dev/null || true
	fi
	refresh_desktop_database

	if has_systemd_user_instance; then
		systemctl --user daemon-reload
	fi

	green "✓ Skrepka removed"
	echo
	echo "Your clipboard history and this device's sync identity were left in place:"
	echo
	echo "    ${STATE_DIR}/skrepka.sqlite3   the history database"
	echo "    ${STATE_DIR}/device.key        this device's sync identity"
	echo
	echo "Deleting device.key un-pairs this machine from every peer it has synced"
	echo "with, so it is left for you to do deliberately:"
	echo
	echo "    rm -rf \"${STATE_DIR}\""
	exit 0
fi

# ---------------------------------------------------------------------------
# Source resolution
# ---------------------------------------------------------------------------

# Two ways in. From a checkout, ${BASH_SOURCE[0]} is this file and the repository
# is its parent's parent. Piped from curl, bash reads the script from stdin,
# BASH_SOURCE[0] is "bash" or "main" and there is no checkout anywhere — so one
# is cloned into a temporary directory. Both paths end up building the same
# source and installing the same unit file; there is no second, embedded copy
# of the unit to drift out of sync with packaging/systemd/skrepkad.service.
REPOSITORY=""
CLONE_DIRECTORY=""

resolve_repository() {
	local script_path="${BASH_SOURCE[0]:-}"
	if [[ -n "${script_path}" && -f "${script_path}" ]]; then
		local candidate
		candidate="$(cd "$(dirname "${script_path}")/.." && pwd)"
		if [[ -f "${candidate}/Package.swift" && -f "${candidate}/packaging/systemd/${UNIT_NAME}" ]]; then
			REPOSITORY="${candidate}"
			return 0
		fi
	fi

	if ! command -v git > /dev/null 2>&1; then
		echo "error: not running from a Skrepka checkout, and git is not installed" >&2
		echo "so there is nothing to clone from. Install git, or clone the repository" >&2
		echo "yourself and run scripts/install.sh from inside it." >&2
		exit 1
	fi

	bold "Fetching Skrepka"
	CLONE_DIRECTORY="$(mktemp -d)"
	# EXIT alone: this script ends by falling off the end or calling exit, and a
	# trap on EXIT covers both. The directory is one mktemp -d created in this
	# process, so removing it recursively is bounded to what this run made.
	trap 'if [[ -n "${CLONE_DIRECTORY}" ]]; then rm -rf "${CLONE_DIRECTORY}"; fi' EXIT
	git clone --depth 1 "${REPOSITORY_URL}" "${CLONE_DIRECTORY}/skrepka"
	REPOSITORY="${CLONE_DIRECTORY}/skrepka"

	# Checked rather than assumed, because SKREPKA_REPOSITORY_URL can point at
	# anything — a fork, a mirror, a local path used for testing — and the next
	# failure without this would be `install` reporting a missing file with no
	# hint about which repository it came from.
	if [[ ! -f "${REPOSITORY}/packaging/systemd/${UNIT_NAME}" ]]; then
		echo "error: ${REPOSITORY_URL} has no packaging/systemd/${UNIT_NAME}." >&2
		echo "That is not a Skrepka checkout new enough to install from." >&2
		exit 1
	fi
}

resolve_repository

# ---------------------------------------------------------------------------
# Binaries
# ---------------------------------------------------------------------------

BUILT_SETTINGS=0

if [[ -n "${FROM_BUILD}" ]]; then
	if [[ ! -d "${FROM_BUILD}" ]]; then
		echo "error: --from-build ${FROM_BUILD} is not a directory" >&2
		exit 1
	fi
	# -P: the bundled library is looked up at ${BUILD_DIR}/../lib, and ".." must
	# mean the parent of the real directory. Through a symlink to bin/ the logical
	# path's parent is wherever the link lives, which has no lib beside it.
	BUILD_DIR="$(cd "${FROM_BUILD}" && pwd -P)"
	bold "Using binaries from ${BUILD_DIR}"
else
	if ! command -v swift > /dev/null 2>&1; then
		echo "error: swift is not on PATH, and there is nothing to build with." >&2
		echo "Install a Swift 6.3 toolchain from https://swift.org/install/linux/," >&2
		echo "or build elsewhere and pass --from-build DIR." >&2
		exit 1
	fi

	bold "Building (release)"
	# Two invocations on purpose, and merging them into one would silently
	# install a stale daemon. `swift build --product A --product B` accepts the
	# repeated flag, builds only the LAST one and exits 0 — the same trap
	# docs/linux-sync/open-questions.md records for --target under OQ-13, and
	# the reason scripts/doctor-linux.sh builds a single umbrella product.
	(cd "${REPOSITORY}" && swift build -c release --product "${DAEMON_NAME}")
	(cd "${REPOSITORY}" && swift build -c release --product "${CLI_NAME}")

	# The Settings window is the only product that links GTK4 and
	# gtk4-layer-shell, so it is the only one whose build can fail on a machine
	# that is otherwise fine. Building it is gated on both -dev packages being
	# visible to pkg-config — GTK at the version its API needs, so an older one
	# is a note here rather than a screen of compiler errors — and a machine
	# without them gets the daemon and the CLI and a note. A third invocation,
	# for the reason above.
	if command -v pkg-config > /dev/null 2>&1 \
		&& pkg-config --exists "${GTK_REQUIREMENT}" gtk4-layer-shell-0; then
		#
		# A failed build is a skipped Settings window, not a failed install: under
		# `set -e` a bare failure here would abort before the daemon and the CLI
		# built above were installed.
		if (cd "${REPOSITORY}" && swift build -c release --product "${SETTINGS_NAME}"); then
			BUILT_SETTINGS=1
		else
			yellow "skipping ${SETTINGS_NAME}: its build failed, see the output above."
			yellow "  The daemon and the CLI are installed regardless."
		fi
	else
		yellow "skipping ${SETTINGS_NAME}: pkg-config cannot find ${GTK_REQUIREMENT} and gtk4-layer-shell-0."
		yellow "  Install their development packages and re-run to get the Settings window."
	fi
	BUILD_DIR="$(cd "${REPOSITORY}" && swift build -c release --show-bin-path)"
fi

for name in "${DAEMON_NAME}" "${CLI_NAME}"; do
	if [[ ! -x "${BUILD_DIR}/${name}" ]]; then
		echo "error: ${BUILD_DIR}/${name} is missing or not executable" >&2
		exit 1
	fi
done

# Optional, unlike the two above. A --from-build directory from a headless
# build has no skrepka-settings, and that is a complete install. A checkout
# build installs it only if it was built in this run: a leftover binary from an
# earlier build, on a machine that can no longer build it, would be stale.
INSTALL_SETTINGS=0
if [[ -n "${FROM_BUILD}" ]]; then
	if [[ -x "${BUILD_DIR}/${SETTINGS_NAME}" ]]; then
		INSTALL_SETTINGS=1
	else
		yellow "skipping ${SETTINGS_NAME}: ${BUILD_DIR}/${SETTINGS_NAME} is not there."
	fi
elif [[ "${BUILT_SETTINGS}" -eq 1 ]]; then
	INSTALL_SETTINGS=1
fi

# A re-run that skips the Settings window leaves an earlier one in place, and it
# was built against the previous daemon's D-Bus interface. Left silently, it
# would talk to a daemon that has moved on.
if [[ "${INSTALL_SETTINGS}" -eq 0 && -e "${BIN_DIR}/${SETTINGS_NAME}" ]]; then
	yellow "note: ${BIN_DIR}/${SETTINGS_NAME} was left as it was, and may not match"
	yellow "  the D-Bus interface of the daemon just installed."
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

bold "Installing into ${BIN_DIR}"

mkdir -p "${BIN_DIR}" "${UNIT_DIR}"

# `install` rather than `cp`: it replaces the destination by unlinking first,
# so overwriting a binary that is currently running (an upgrade over a live
# daemon) writes a new inode instead of ETXTBSY.
install -m 0755 "${BUILD_DIR}/${DAEMON_NAME}" "${BIN_DIR}/${DAEMON_NAME}"
install -m 0755 "${BUILD_DIR}/${CLI_NAME}" "${BIN_DIR}/${CLI_NAME}"
echo "installed ${BIN_DIR}/${DAEMON_NAME}"
echo "installed ${BIN_DIR}/${CLI_NAME}"

# The unit ships with ExecStart=%h/.local/bin/skrepkad, which is right for
# everyone who has not set $XDG_BIN_HOME. When they have, %h is still their home
# but the rest of the path is wrong, so the one line is rewritten on the way in.
# Rewritten rather than templated everywhere, because a unit file with a
# placeholder in it cannot be checked with `systemd-analyze verify` as it stands
# in the repository.
if [[ "${BIN_DIR}" == "${HOME}/.local/bin" ]]; then
	install -m 0644 "${REPOSITORY}/packaging/systemd/${UNIT_NAME}" "${UNIT_DIR}/${UNIT_NAME}"
else
	# Rewritten line by line in the shell rather than with `sed`, and that is a
	# correctness measure rather than a preference.
	#
	# $BIN_DIR comes from $XDG_BIN_HOME, which is a user's environment variable
	# and can hold anything a path can hold. Put on the right-hand side of an
	# `s|||` it is not data, it is sed source: an `&` expands to the whole
	# match, a backslash escapes the character after it, and a `|` closes the
	# replacement early. Any of the three silently writes a corrupt ExecStart
	# that systemd then reports as 203/EXEC with nothing pointing at the cause.
	# Escaping the three would work; not handing the path to an expression
	# language at all is shorter and has nothing left to get wrong.
	#
	# Through a temporary file rather than `sed -i` either way, whose in-place
	# flag takes a mandatory argument on BSD sed and none on GNU sed; the two
	# spellings are incompatible and this script has no business caring which
	# one it met.
	UNIT_STAGE="$(mktemp)"
	trap 'rm -f "${UNIT_STAGE}"; if [[ -n "${CLONE_DIRECTORY}" ]]; then rm -rf "${CLONE_DIRECTORY}"; fi' EXIT
	EXEC_START_FROM="ExecStart=%h/.local/bin/${DAEMON_NAME}"
	EXEC_START_TO="ExecStart=${BIN_DIR}/${DAEMON_NAME}"
	REWROTE=0
	# `|| [[ -n "${line}" ]]` so a final line without a trailing newline is not
	# dropped; `IFS=` and `-r` so leading whitespace and backslashes survive.
	while IFS= read -r line || [[ -n "${line}" ]]; do
		if [[ "${line}" == "${EXEC_START_FROM}" ]]; then
			printf '%s\n' "${EXEC_START_TO}"
			REWROTE=1
		else
			printf '%s\n' "${line}"
		fi
	done < "${REPOSITORY}/packaging/systemd/${UNIT_NAME}" > "${UNIT_STAGE}"

	# Asserted rather than assumed. The old `sed` exited 0 having substituted
	# nothing if that line ever changed, and the next line claimed success — so
	# the unit would point at a binary that is not there.
	if [[ "${REWROTE}" -ne 1 ]]; then
		echo "error: no '${EXEC_START_FROM}' line in ${UNIT_NAME}; cannot point it at ${BIN_DIR}." >&2
		exit 1
	fi
	install -m 0644 "${UNIT_STAGE}" "${UNIT_DIR}/${UNIT_NAME}"
	echo "unit ExecStart pointed at ${BIN_DIR}/${DAEMON_NAME} (\$XDG_BIN_HOME is set)"
fi
echo "installed ${UNIT_DIR}/${UNIT_NAME}"

# ---------------------------------------------------------------------------
# Settings window
# ---------------------------------------------------------------------------

# Warns about shared libraries the loader cannot find for the installed
# binary. A warning and never a failure: the daemon and the CLI do not need GTK
# and work regardless, so an install whose Settings window will not start is
# still a working install with one broken piece the user is told about.
#
# ldd exits non-zero and prints "not a dynamic executable" for a file that is
# not one, which has no line saying "not found", so that case is silent. It
# resolves the binary's own rpath ($ORIGIN/../lib and $ORIGIN/../lib/skrepka)
# from where the binary now sits, so it sees the private copy installed above.
warn_about_missing_libraries() {
	local binary="$1" line library missing=()
	while IFS= read -r line; do
		if [[ "${line}" == *"not found"* ]]; then
			read -r library _ <<< "${line}"
			missing+=("${library}")
		fi
	done < <(ldd "${binary}" 2> /dev/null || true)

	if ((${#missing[@]} > 0)); then
		yellow ""
		yellow "⚠ ${binary} cannot find: ${missing[*]}"
		yellow "  The Settings window will not start until they are installed."
		yellow "  Install the packages that provide them from your distribution —"
		yellow "  usually the GTK 4 runtime and gtk4-layer-shell. skrepkad and"
		yellow "  skrepka are unaffected."
	fi
}

# `install` for the binary and the library alike: it unlinks the destination
# first, so replacing a file a running Settings window has mapped writes a new
# inode instead of failing with ETXTBSY or corrupting the mapping.
if [[ "${INSTALL_SETTINGS}" -eq 1 ]]; then
	install -m 0755 "${BUILD_DIR}/${SETTINGS_NAME}" "${BIN_DIR}/${SETTINGS_NAME}"
	echo "installed ${BIN_DIR}/${SETTINGS_NAME}"

	# A build that bundles gtk4-layer-shell keeps it in ../lib beside the bin
	# directory — the tarball layout, and where the binary's first rpath,
	# $ORIGIN/../lib, finds it when run in place. SteamOS does not ship the
	# library, so an installed copy needs its own. It goes to ../lib/skrepka
	# relative to BIN_DIR, the binary's second rpath, and into a directory of
	# Skrepka's own so it never overwrites a system copy. It does shadow one: an
	# rpath (RUNPATH) is searched before the loader's cache, so once this file is
	# there the binary uses it instead of the system's.
	#
	# `install` follows the source symlink, so what lands is one regular file
	# named exactly for the soname the binary asks for, however the tarball
	# spelled the .so -> .so.0 -> .so.1.3.0 chain.
	BUNDLED_LAYER_SHELL="$(cd "${BUILD_DIR}" && pwd -P)/../lib/${LAYER_SHELL_LIBRARY}"
	if [[ -e "${BUNDLED_LAYER_SHELL}" ]]; then
		mkdir -p "${PRIVATE_LIB_DIR}"
		install -m 0644 "${BUNDLED_LAYER_SHELL}" "${PRIVATE_LIB_DIR}/${LAYER_SHELL_LIBRARY}"
		echo "installed ${PRIVATE_LIB_DIR}/${LAYER_SHELL_LIBRARY}"
	elif [[ -e "${PRIVATE_LIB_DIR}/${LAYER_SHELL_LIBRARY}" || -L "${PRIVATE_LIB_DIR}/${LAYER_SHELL_LIBRARY}" ]]; then
		# This build has no bundled copy, so it expects the system's. A private
		# copy left by an earlier install would come first in the rpath and
		# shadow it, pinning the binary to a library from a different build.
		# Named file, then rmdir: the directory goes only if that left it empty.
		rm -f "${PRIVATE_LIB_DIR}/${LAYER_SHELL_LIBRARY}"
		rmdir "${PRIVATE_LIB_DIR}" 2> /dev/null || true
		echo "removed stale ${PRIVATE_LIB_DIR}/${LAYER_SHELL_LIBRARY}"
	fi

	warn_about_missing_libraries "${BIN_DIR}/${SETTINGS_NAME}"

	# The launcher entry. Its Exec= line is the repository file's, with the
	# plain program name replaced by the absolute installed path, for the
	# reason the file itself gives.
	DESKTOP_SOURCE="${REPOSITORY}/packaging/desktop/${DESKTOP_NAME}"
	if [[ ! -f "${DESKTOP_SOURCE}" ]]; then
		yellow "no ${DESKTOP_NAME} in this checkout; ${SETTINGS_NAME} has no launcher entry."
	elif ! EXEC_VALUE="$(desktop_exec_quote "${BIN_DIR}/${SETTINGS_NAME}")"; then
		yellow "cannot write a launcher entry: ${BIN_DIR} contains a character that"
		yellow "a Desktop Entry Exec= line cannot hold (\"=\", a tab or a newline)."
		yellow "  Run ${BIN_DIR}/${SETTINGS_NAME} from a terminal instead."
	else
		# Line by line in the shell, no `sed`, for the reason the unit rewrite
		# above gives: the path is a user's environment variable and would be
		# sed source on the right-hand side of a substitution.
		DESKTOP_STAGE="$(mktemp)"
		trap 'rm -f "${UNIT_STAGE:-}" "${DESKTOP_STAGE}"; if [[ -n "${CLONE_DIRECTORY}" ]]; then rm -rf "${CLONE_DIRECTORY}"; fi' EXIT
		DESKTOP_EXEC_FROM="Exec=${SETTINGS_NAME}"
		REWROTE=0
		while IFS= read -r line || [[ -n "${line}" ]]; do
			if [[ "${line}" == "${DESKTOP_EXEC_FROM}" ]]; then
				printf '%s\n' "Exec=${EXEC_VALUE}"
				REWROTE=$((REWROTE + 1))
			else
				printf '%s\n' "${line}"
			fi
		done < "${DESKTOP_SOURCE}" > "${DESKTOP_STAGE}"

		# Exactly one, asserted, so a renamed or duplicated Exec= line in the
		# entry is an error here and not a launcher that starts nothing.
		if [[ "${REWROTE}" -ne 1 ]]; then
			echo "error: expected exactly one '${DESKTOP_EXEC_FROM}' line in ${DESKTOP_NAME}, found ${REWROTE}." >&2
			exit 1
		fi
		mkdir -p "${DESKTOP_DIR}"
		install -m 0644 "${DESKTOP_STAGE}" "${DESKTOP_DIR}/${DESKTOP_NAME}"
		rm -f "${DESKTOP_STAGE}"
		echo "installed ${DESKTOP_DIR}/${DESKTOP_NAME}"
		refresh_desktop_database
	fi
fi

# ---------------------------------------------------------------------------
# Enable
# ---------------------------------------------------------------------------

if has_systemd_user_instance; then
	bold "Enabling ${UNIT_NAME}"
	systemctl --user daemon-reload
	systemctl --user enable --now "${UNIT_NAME}"
	# `enable --now` starts a unit only when it is inactive, so on the upgrade
	# path — the ordinary second run, and the whole point of --from-build — it
	# does nothing and the *old* binary keeps running behind a rewritten unit.
	# `try-restart` restarts it only if it is already up, which is exactly the
	# case `--now` just declined to handle, and is a no-op on a first install.
	systemctl --user try-restart "${UNIT_NAME}"
	green "✓ skrepkad is enabled and running"
else
	yellow "⚠ no systemd user instance is reachable from this shell."
	yellow "  The unit file is installed and correct; nothing was started."
	yellow "  In a graphical session on the machine itself, run:"
	yellow ""
	yellow "      systemctl --user daemon-reload"
	yellow "      systemctl --user enable --now ${UNIT_NAME}"
	yellow ""
	yellow "  Over ssh, a user manager only exists while you are logged in unless"
	yellow "  lingering is on: loginctl enable-linger \"\$USER\"."
fi

# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------

# A warning, never a failure, and never an edit to the user's shell files. The
# daemon does not care about $PATH — systemd runs it by absolute path — so an
# install with the CLI off $PATH is a working install with an awkward CLI, and
# rewriting someone's .bashrc from a curl | bash script is a bigger surprise
# than the warning it would save.
case ":${PATH}:" in
	*":${BIN_DIR}:"*) ;;
	*)
		yellow ""
		yellow "⚠ ${BIN_DIR} is not on your \$PATH, so \`${CLI_NAME}\` will not be found."
		yellow "  Add this line to ~/.profile (bash, sh, zsh):"
		yellow ""
		yellow "      export PATH=\"${BIN_DIR}:\$PATH\""
		yellow ""
		yellow "  or, for fish, to ~/.config/fish/config.fish:"
		yellow ""
		yellow "      fish_add_path ${BIN_DIR}"
		;;
esac

echo
echo "Clipboard history and this device's sync identity will be created by the"
echo "daemon, on first run, under ${STATE_DIR}."
echo
if [[ "${INSTALL_SETTINGS}" -eq 1 ]]; then
	echo "  ${SETTINGS_NAME}                    pair and manage devices (also in the launcher)"
fi
echo "  ${CLI_NAME} --help                       what the CLI can do"
echo "  systemctl --user status ${UNIT_NAME}   is it running"
echo "  journalctl --user -u ${UNIT_NAME} -f   what it is saying"
