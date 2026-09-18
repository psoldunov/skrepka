#!/usr/bin/env bash
#
# Installs a released build of Skrepka's Linux daemon, CLI and Settings window
# into your home directory. No root, no package manager, nothing to compile.
#
#   curl -fsSL https://raw.githubusercontent.com/psoldunov/skrepka/master/install.sh | bash
#   curl -fsSL <same url> | bash -s -- --version v0.2.0
#   curl -fsSL <same url> | bash -s -- --uninstall
#
#   ./install.sh                    from inside an untarred release: install it
#   ./install.sh --tarball FILE     install a release tarball already on disk
#   ./install.sh --from-dir DIR     install a staged build (scripts/setup-linux.sh)
#
# Piped from curl it downloads skrepka-linux-x86_64.tar.gz from the latest
# GitHub release — or the one --version names — checks it against the .sha256
# published beside it, and installs what is inside. That is the whole Steam Deck
# story: one line in Konsole, in Desktop Mode, and no sshd, no password and no
# scp from another machine.
#
# Building from a checkout is a different job and a different script:
# scripts/setup-linux.sh compiles the three products and then hands them to this
# one with --from-dir. So there is exactly one copy of the rules about where
# files go and how the unit is started, and it is this file.
#
# By default everything lands under $HOME; an absolute $XDG_BIN_HOME,
# $XDG_CONFIG_HOME or $XDG_DATA_HOME moves its part to wherever it points:
#
#   ~/.local/bin/skrepkad            the daemon      ($XDG_BIN_HOME is honoured)
#   ~/.local/bin/skrepka             the CLI
#   ~/.local/bin/skrepka-settings    the GTK4 Settings window (optional)
#   ~/.local/lib/skrepka/libgtk4-layer-shell.so.0
#                                    a private copy of that library, only from a
#                                    build that bundles one (the release tarball)
#   ~/.local/share/applications/dev.soldunov.Skrepka.Settings.desktop
#                                    the launcher entry for the Settings window
#                                    ($XDG_DATA_HOME is honoured)
#   ~/.config/systemd/user/skrepkad.service          ($XDG_CONFIG_HOME too)
#
# skrepka-settings is optional because it is the one piece that needs GTK4 and
# gtk4-layer-shell. A headless build with only the daemon and the CLI is a
# legitimate install, so a payload without it skips it with a note.
#
# That layout is a decision recorded in docs/linux-sync/open-questions.md as
# D-10, and the reason is SteamOS: its root filesystem is read-only,
# `steamos-readonly disable` is undone by the next atomic OS update, and with
# systemd-sysext extensions merged /usr stays read-only even after disabling it.
# A .deb or .rpm has nowhere to land there. /home survives OS updates, so the
# installer writes only into /home. This is not a Steam Deck script, though —
# it is the no-root install path for any x86_64 distribution.
#
# What it deliberately does NOT touch: ~/.local/share/skrepka. The history
# database and the device key live there, the daemon creates that directory
# itself with the modes it needs (0700 for the directory, 0600 for the key),
# and an installer that pre-creates it at the wrong mode is a real exposure
# rather than a tidiness question. --uninstall leaves it alone too, and says
# where it is instead: deleting device.key un-pairs this machine from every
# peer it has ever synced with, and that is not something an uninstall should
# do behind the user's back.
#
# Everything below is functions, and the last line calls main. That matters for
# `curl | bash`: bash executes a piped script as it reads it, so a download cut
# off halfway would otherwise run the first half. Wrapped like this, nothing
# runs until the closing line has arrived and the whole file has parsed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

UNIT_NAME="skrepkad.service"
DAEMON_NAME="skrepkad"
CLI_NAME="skrepka"
SETTINGS_NAME="skrepka-settings"
DESKTOP_NAME="dev.soldunov.Skrepka.Settings.desktop"
LAYER_SHELL_LIBRARY="libgtk4-layer-shell.so.0"

# The release asset. Its name carries no version on purpose: GitHub's
# /releases/latest/download/<name> redirect only works for a name that is the
# same in every release.
RELEASE_ARCH="x86_64"
ASSET_STEM="skrepka-linux-${RELEASE_ARCH}"
ASSET_NAME="${ASSET_STEM}.tar.gz"
RELEASE_BASE_URL="${SKREPKA_RELEASE_BASE_URL:-https://github.com/psoldunov/skrepka/releases}"

# Filled in by main and the functions it calls.
BIN_DIR=""
CONFIG_HOME=""
DATA_HOME=""
UNIT_DIR=""
DESKTOP_DIR=""
STATE_DIR=""
PRIVATE_LIB_DIR=""
MODE="install"
VERSION=""
TARBALL=""
FROM_DIR=""
PAYLOAD=""
TEMP_ROOT=""
INSTALL_SETTINGS=0

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# Colour only when stdout is a terminal. Piped into a file or a CI log, escape
# codes are noise. `curl | bash` still has a terminal on stdout — it is stdin
# that the pipe takes — so the Deck's Konsole gets colour.
if [[ -t 1 ]]; then
	bold() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
	green() { printf '\033[32m%s\033[0m\n' "$1"; }
	yellow() { printf '\033[33m%s\033[0m\n' "$1" >&2; }
else
	bold() { printf '\n▸ %s\n' "$1"; }
	green() { printf '%s\n' "$1"; }
	yellow() { printf '%s\n' "$1" >&2; }
fi

fail() {
	local line
	for line in "$@"; do
		printf 'error: %s\n' "${line}" >&2
	done
	exit 1
}

usage() {
	cat << 'USAGE'
Installs a released build of Skrepka's Linux daemon (skrepkad), CLI (skrepka)
and Settings window (skrepka-settings) into your home directory, plus a systemd
user unit that starts the daemon with your session. No root, no package
manager, nothing to compile.

Usage:
  install.sh                    download the latest release and install it
                                (or, from inside an untarred release, install
                                that one)
  install.sh --version TAG      download that release instead, e.g. v0.2.0
  install.sh --tarball FILE     install a release tarball already on disk;
                                FILE.sha256 beside it is checked when present
  install.sh --from-dir DIR     install a staged build: DIR/bin, DIR/packaging
                                and optionally DIR/lib (scripts/setup-linux.sh
                                uses this)
  install.sh --uninstall        stop and remove the unit, binaries and entry
  install.sh --help             this message

Piped from curl, pass arguments after `bash -s --`:

  curl -fsSL https://raw.githubusercontent.com/psoldunov/skrepka/master/install.sh \
    | bash -s -- --version v0.2.0

Release builds are x86_64 only. On any other machine, clone the repository and
run scripts/setup-linux.sh, which builds from source.

The Settings window needs GTK 4.12 or newer from the host. The release bundles
gtk4-layer-shell, which SteamOS does not ship.

Where things land (XDG_BIN_HOME, XDG_CONFIG_HOME and XDG_DATA_HOME are
honoured when they hold an absolute path):

  ~/.local/bin/skrepkad, ~/.local/bin/skrepka, ~/.local/bin/skrepka-settings
  ~/.local/lib/skrepka/libgtk4-layer-shell.so.0  a private copy, only when the
                             build bundles one; it sits at ../lib/skrepka
                             relative to the bin directory
  ~/.local/share/applications/dev.soldunov.Skrepka.Settings.desktop
  ~/.config/systemd/user/skrepkad.service
  ~/.local/share/skrepka/  — history and device key, created by the daemon,
                             never touched by this script or by --uninstall

Environment:
  SKREPKA_RELEASE_BASE_URL  where releases are downloaded from
                            (default: https://github.com/psoldunov/skrepka/releases)
USAGE
}

# ---------------------------------------------------------------------------
# Arguments and paths
# ---------------------------------------------------------------------------

parse_arguments() {
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
			--version | --tarball | --from-dir)
				if [[ -z "${2:-}" ]]; then
					fail "$1 needs a value."
				fi
				set_option "$1" "$2"
				shift 2
				;;
			--version=* | --tarball=* | --from-dir=*)
				set_option "${1%%=*}" "${1#*=}"
				shift
				;;
			*)
				fail "unknown argument: $1" "try: install.sh --help"
				;;
		esac
	done

	local sources=0
	[[ -n "${VERSION}" ]] && sources=$((sources + 1))
	[[ -n "${TARBALL}" ]] && sources=$((sources + 1))
	[[ -n "${FROM_DIR}" ]] && sources=$((sources + 1))
	if ((sources > 1)); then
		fail "--version, --tarball and --from-dir each name where the build comes from;" \
			"pass one of them."
	fi
	if [[ "${MODE}" == "uninstall" ]] && ((sources > 0)); then
		fail "--uninstall takes no --version, --tarball or --from-dir."
	fi
}

set_option() {
	case "$1" in
		--version)
			# Tags are v-prefixed; accept 0.2.0 as well as v0.2.0.
			VERSION="v${2#v}"
			;;
		--tarball)
			TARBALL="$2"
			;;
		--from-dir)
			FROM_DIR="$2"
			;;
	esac
}

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

resolve_paths() {
	if [[ -z "${HOME:-}" ]]; then
		fail "\$HOME is not set; this installer has nowhere to install to."
	fi

	BIN_DIR="$(xdg_directory "${XDG_BIN_HOME:-}" "${HOME}/.local/bin")"
	CONFIG_HOME="$(xdg_directory "${XDG_CONFIG_HOME:-}" "${HOME}/.config")"
	DATA_HOME="$(xdg_directory "${XDG_DATA_HOME:-}" "${HOME}/.local/share")"
	UNIT_DIR="${CONFIG_HOME}/systemd/user"
	DESKTOP_DIR="${DATA_HOME}/applications"
	STATE_DIR="${DATA_HOME}/skrepka"

	# The private library directory is computed from BIN_DIR, not from $HOME,
	# because it has to match what the skrepka-settings binary was linked with:
	# an rpath of $ORIGIN/../lib/skrepka, which the dynamic loader resolves
	# relative to the directory the binary sits in. With the default BIN_DIR
	# that is ~/.local/lib/skrepka; with XDG_BIN_HOME=/opt/me/bin it is
	# /opt/me/lib/skrepka, and a copy left in ~/.local/lib would never be found.
	PRIVATE_LIB_DIR="$(dirname "${BIN_DIR}")/lib/skrepka"
}

# One temporary directory per run, made on first use and removed on exit.
# EXIT alone: this script ends by returning from main or calling exit, and a
# trap on EXIT covers both. The directory is one mktemp -d created by this
# process, so removing it recursively is bounded to what this run made.
cleanup() {
	if [[ -n "${TEMP_ROOT}" ]]; then
		rm -rf "${TEMP_ROOT}"
	fi
}

# Under the user's cache directory rather than /tmp, because the downloaded
# daemon is run from here before anything is installed (see preflight), and
# hardened systems mount /tmp noexec — which would read as "this build cannot
# run on this machine" when the machine is fine. The home directory is where
# the binaries are about to be installed and run from anyway.
temp_root() {
	if [[ -z "${TEMP_ROOT}" ]]; then
		local base
		base="$(xdg_directory "${XDG_CACHE_HOME:-}" "${HOME}/.cache")"
		mkdir -p "${base}"
		TEMP_ROOT="$(mktemp -d "${base}/skrepka-install.XXXXXX")"
	fi
}

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

# Copies $1 to $2, replacing every line equal to $3 with $4, and prints how many
# lines it replaced.
#
# Line by line in the shell rather than with `sed`, and that is a correctness
# measure rather than a preference. The replacement carries a path that comes
# from $XDG_BIN_HOME, which is a user's environment variable and can hold
# anything a path can hold. Put on the right-hand side of an `s|||` it is not
# data, it is sed source: an `&` expands to the whole match, a backslash escapes
# the character after it, and a `|` closes the replacement early. Any of the
# three silently writes a corrupt line. Not handing the path to an expression
# language at all is shorter than escaping it and has nothing left to get wrong.
#
# `|| [[ -n "${line}" ]]` so a final line without a trailing newline is not
# dropped; `IFS=` and `-r` so leading whitespace and backslashes survive.
replace_line() {
	local source="$1" destination="$2" from="$3" to="$4" line count=0
	while IFS= read -r line || [[ -n "${line}" ]]; do
		if [[ "${line}" == "${from}" ]]; then
			printf '%s\n' "${to}"
			count=$((count + 1))
		else
			printf '%s\n' "${line}"
		fi
	done < "${source}" > "${destination}"
	printf '%s' "${count}"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

uninstall() {
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
	# built from BIN_DIR/UNIT_DIR, both of which were derived from an
	# absolute-or-fallback rule, so none of them can collapse to "/" or to an
	# empty string and take a home directory with them.
	local path
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
}

# ---------------------------------------------------------------------------
# Payload: where the build comes from
# ---------------------------------------------------------------------------

# A payload is a directory laid out like the release tarball:
#
#   bin/skrepkad, bin/skrepka             required
#   bin/skrepka-settings                  optional
#   lib/libgtk4-layer-shell.so.0          optional, the bundled library
#   packaging/systemd/skrepkad.service    required
#   packaging/desktop/<desktop entry>     needed for the launcher entry
#
# Four ways to get one, tried in this order: --from-dir names it, --tarball
# names an archive of one, this script sits inside one (an untarred release),
# or one is downloaded from GitHub.
resolve_payload() {
	if [[ -n "${FROM_DIR}" ]]; then
		if [[ ! -d "${FROM_DIR}" ]]; then
			fail "--from-dir ${FROM_DIR} is not a directory"
		fi
		# -P so the lib/ beside bin/ is looked up in the real directory, not
		# through whatever symlink the caller named it by.
		PAYLOAD="$(cd "${FROM_DIR}" && pwd -P)"
		bold "Using the build in ${PAYLOAD}"
	elif [[ -n "${TARBALL}" ]]; then
		if [[ ! -f "${TARBALL}" ]]; then
			fail "--tarball ${TARBALL} is not a file"
		fi
		require_release_architecture
		bold "Using the release tarball ${TARBALL}"
		if [[ -f "${TARBALL}.sha256" ]]; then
			verify_checksum "${TARBALL}" "${TARBALL}.sha256"
		else
			yellow "no ${TARBALL}.sha256 beside it; installing without a checksum."
		fi
		extract_tarball "${TARBALL}"
	elif own_directory_is_payload; then
		require_release_architecture
		bold "Using the release this script was unpacked with, in ${PAYLOAD}"
	else
		require_release_architecture
		download_release
	fi

	local name
	for name in "${DAEMON_NAME}" "${CLI_NAME}"; do
		if [[ ! -x "${PAYLOAD}/bin/${name}" ]]; then
			fail "${PAYLOAD}/bin/${name} is missing or not executable"
		fi
	done
	if [[ ! -f "${PAYLOAD}/packaging/systemd/${UNIT_NAME}" ]]; then
		fail "${PAYLOAD}/packaging/systemd/${UNIT_NAME} is missing;" \
			"that is not a Skrepka build this installer understands."
	fi
}

# From a file on disk, ${BASH_SOURCE[0]} is this script. Piped from curl, bash
# reads the script from stdin and BASH_SOURCE[0] is empty or "main", which is
# not a file — so this answers no and the release is downloaded instead. Run
# from the root of a checkout it also answers no: a checkout has packaging/ but
# no bin/.
own_directory_is_payload() {
	local script_path="${BASH_SOURCE[0]:-}" candidate
	if [[ -z "${script_path}" || ! -f "${script_path}" ]]; then
		return 1
	fi
	candidate="$(cd "$(dirname "${script_path}")" && pwd -P)"
	if [[ -x "${candidate}/bin/${DAEMON_NAME}" && -f "${candidate}/packaging/systemd/${UNIT_NAME}" ]]; then
		PAYLOAD="${candidate}"
		return 0
	fi
	return 1
}

# The release binaries are x86_64 ELF. Anywhere else they fail with "Exec
# format error" at the first run, after the unit is already enabled, so the
# mismatch is refused up front with the route that does work.
require_release_architecture() {
	local machine
	machine="$(uname -m)"
	if [[ "${machine}" != "${RELEASE_ARCH}" ]]; then
		fail "Skrepka's release builds are ${RELEASE_ARCH}; this machine is ${machine}." \
			"Clone https://github.com/psoldunov/skrepka and run scripts/setup-linux.sh" \
			"to build from source instead."
	fi
}

download_release() {
	if ! command -v curl > /dev/null 2>&1; then
		fail "curl is not installed, and it is what this installer downloads with."
	fi

	local url
	if [[ -n "${VERSION}" ]]; then
		url="${RELEASE_BASE_URL}/download/${VERSION}"
		bold "Downloading Skrepka ${VERSION}"
	else
		url="${RELEASE_BASE_URL}/latest/download"
		bold "Downloading the latest Skrepka release"
	fi

	temp_root
	local archive="${TEMP_ROOT}/${ASSET_NAME}"
	# -f so an HTTP error is a failure and not an HTML page saved as a tarball;
	# -L because GitHub answers both URLs with a redirect to its asset storage.
	if ! curl -fL --retry 3 --connect-timeout 15 --progress-bar \
		-o "${archive}" "${url}/${ASSET_NAME}"; then
		fail "could not download ${url}/${ASSET_NAME}." \
			"Check the network, and that the release exists and carries that file."
	fi
	if ! curl -fsSL --retry 3 --connect-timeout 15 \
		-o "${archive}.sha256" "${url}/${ASSET_NAME}.sha256"; then
		fail "could not download ${url}/${ASSET_NAME}.sha256, so the build cannot be" \
			"checked. Nothing was installed."
	fi

	verify_checksum "${archive}" "${archive}.sha256"
	extract_tarball "${archive}"
}

# Compares the SHA-256 of $1 with the first field of $2, the `sha256sum` output
# scripts/build-deck.sh publishes beside the tarball. Read and compared here
# rather than with `sha256sum -c`, which looks the file up by the name written
# inside the checksum file and so depends on where it was run from.
#
# What this does and does not prove: the checksum comes from the same release as
# the tarball, so it catches a truncated or corrupted download. It does not
# protect against someone who controls the release itself — they could replace
# both files.
verify_checksum() {
	local file="$1" checksum_file="$2" expected actual
	read -r expected _ < "${checksum_file}" || true
	if [[ ! "${expected}" =~ ^[0-9a-fA-F]{64}$ ]]; then
		fail "${checksum_file} does not hold a SHA-256 checksum. Nothing was installed."
	fi

	if command -v sha256sum > /dev/null 2>&1; then
		read -r actual _ < <(sha256sum "${file}")
	elif command -v shasum > /dev/null 2>&1; then
		read -r actual _ < <(shasum -a 256 "${file}")
	else
		fail "neither sha256sum nor shasum is installed, so the download cannot be" \
			"checked. Nothing was installed."
	fi

	if [[ "${actual,,}" != "${expected,,}" ]]; then
		fail "checksum mismatch for $(basename "${file}")" \
			"  expected ${expected}" \
			"  got      ${actual}" \
			"The download is damaged or is not the file the release published." \
			"Nothing was installed."
	fi
	green "✓ checksum matches"
}

extract_tarball() {
	local archive="$1"
	temp_root
	local destination="${TEMP_ROOT}/unpacked"
	mkdir -p "${destination}"
	if ! tar -xzf "${archive}" -C "${destination}"; then
		fail "could not unpack ${archive}"
	fi
	if [[ ! -d "${destination}/${ASSET_STEM}" ]]; then
		fail "${archive} has no ${ASSET_STEM}/ directory at its top;" \
			"that is not a Skrepka release tarball."
	fi
	PAYLOAD="${destination}/${ASSET_STEM}"
}

# Runs the daemon's --version before anything is written. A binary that cannot
# start on this machine — a glibc older than the one it was linked against is
# the likely cause — fails here, with the loader's own message, rather than
# after the unit is enabled and systemd reports a crash loop.
preflight() {
	local output
	if ! output="$("${PAYLOAD}/bin/${DAEMON_NAME}" --version 2>&1)"; then
		fail "${DAEMON_NAME} from this build cannot run on this machine:" \
			"  ${output}" \
			"Nothing was installed."
	fi
	echo "${output}"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

install_binaries() {
	bold "Installing into ${BIN_DIR}"
	mkdir -p "${BIN_DIR}" "${UNIT_DIR}"

	# `install` rather than `cp`: it replaces the destination by unlinking
	# first, so overwriting a binary that is currently running (an upgrade over
	# a live daemon) writes a new inode instead of ETXTBSY. It also follows a
	# symlinked source, which is how scripts/setup-linux.sh stages its build.
	install -m 0755 "${PAYLOAD}/bin/${DAEMON_NAME}" "${BIN_DIR}/${DAEMON_NAME}"
	install -m 0755 "${PAYLOAD}/bin/${CLI_NAME}" "${BIN_DIR}/${CLI_NAME}"
	echo "installed ${BIN_DIR}/${DAEMON_NAME}"
	echo "installed ${BIN_DIR}/${CLI_NAME}"
}

install_unit() {
	local source="${PAYLOAD}/packaging/systemd/${UNIT_NAME}"

	# The unit ships with ExecStart=%h/.local/bin/skrepkad, which is right for
	# everyone who has not set $XDG_BIN_HOME. When they have, %h is still their
	# home but the rest of the path is wrong, so the one line is rewritten on
	# the way in. Rewritten rather than templated everywhere, because a unit
	# file with a placeholder in it cannot be checked with
	# `systemd-analyze verify` as it stands in the repository.
	if [[ "${BIN_DIR}" == "${HOME}/.local/bin" ]]; then
		install -m 0644 "${source}" "${UNIT_DIR}/${UNIT_NAME}"
	else
		temp_root
		local staged="${TEMP_ROOT}/${UNIT_NAME}"
		local from="ExecStart=%h/.local/bin/${DAEMON_NAME}"
		local rewrote
		rewrote="$(replace_line "${source}" "${staged}" "${from}" "ExecStart=${BIN_DIR}/${DAEMON_NAME}")"
		# Asserted rather than assumed: if that line ever changes, a rewrite
		# that matched nothing would leave the unit pointing at a binary that is
		# not there, and systemd would report 203/EXEC with nothing pointing at
		# the cause.
		if [[ "${rewrote}" -ne 1 ]]; then
			fail "expected exactly one '${from}' line in ${UNIT_NAME}, found ${rewrote};" \
				"cannot point it at ${BIN_DIR}."
		fi
		install -m 0644 "${staged}" "${UNIT_DIR}/${UNIT_NAME}"
		echo "unit ExecStart pointed at ${BIN_DIR}/${DAEMON_NAME} (\$XDG_BIN_HOME is set)"
	fi
	echo "installed ${UNIT_DIR}/${UNIT_NAME}"
}

# Warns about shared libraries the loader cannot find for the installed
# binary. A warning and never a failure: the daemon and the CLI do not need GTK
# and work regardless, so an install whose Settings window will not start is
# still a working install with one broken piece the user is told about.
#
# ldd exits non-zero and prints "not a dynamic executable" for a file that is
# not one, which has no line saying "not found", so that case is silent. It
# resolves the binary's own rpath ($ORIGIN/../lib and $ORIGIN/../lib/skrepka)
# from where the binary now sits, so it sees the private copy installed first.
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

install_settings() {
	if [[ ! -x "${PAYLOAD}/bin/${SETTINGS_NAME}" ]]; then
		yellow "skipping ${SETTINGS_NAME}: this build does not include it."
		# A re-run that skips the Settings window leaves an earlier one in
		# place, and it was built against the previous daemon's D-Bus
		# interface. Left silently, it would talk to a daemon that has moved on.
		if [[ -e "${BIN_DIR}/${SETTINGS_NAME}" ]]; then
			yellow "note: ${BIN_DIR}/${SETTINGS_NAME} was left as it was, and may not match"
			yellow "  the D-Bus interface of the daemon just installed."
		fi
		return 0
	fi
	INSTALL_SETTINGS=1

	# `install` for the binary and the library alike: it unlinks the
	# destination first, so replacing a file a running Settings window has
	# mapped writes a new inode instead of failing with ETXTBSY or corrupting
	# the mapping.
	install -m 0755 "${PAYLOAD}/bin/${SETTINGS_NAME}" "${BIN_DIR}/${SETTINGS_NAME}"
	echo "installed ${BIN_DIR}/${SETTINGS_NAME}"

	install_layer_shell
	warn_about_missing_libraries "${BIN_DIR}/${SETTINGS_NAME}"
	install_desktop_entry
}

# A build that bundles gtk4-layer-shell keeps it in lib/ beside bin/ — the
# tarball layout, and where the binary's first rpath, $ORIGIN/../lib, finds it
# when run in place. SteamOS does not ship the library, so an installed copy
# needs its own. It goes to ../lib/skrepka relative to BIN_DIR, the binary's
# second rpath, and into a directory of Skrepka's own so it never overwrites a
# system copy. It does shadow one: an rpath (RUNPATH) is searched before the
# loader's cache, so once this file is there the binary uses it instead of the
# system's.
#
# `install` follows the source symlink, so what lands is one regular file named
# exactly for the soname the binary asks for, however the tarball spelled the
# .so -> .so.0 -> .so.1.3.0 chain.
install_layer_shell() {
	local bundled="${PAYLOAD}/lib/${LAYER_SHELL_LIBRARY}"
	local installed="${PRIVATE_LIB_DIR}/${LAYER_SHELL_LIBRARY}"
	if [[ -e "${bundled}" ]]; then
		mkdir -p "${PRIVATE_LIB_DIR}"
		install -m 0644 "${bundled}" "${installed}"
		echo "installed ${installed}"
	elif [[ -e "${installed}" || -L "${installed}" ]]; then
		# This build has no bundled copy, so it expects the system's. A private
		# copy left by an earlier install would come first in the rpath and
		# shadow it, pinning the binary to a library from a different build.
		# Named file, then rmdir: the directory goes only if that left it empty.
		rm -f "${installed}"
		rmdir "${PRIVATE_LIB_DIR}" 2> /dev/null || true
		echo "removed stale ${installed}"
	fi
}

# The launcher entry. Its Exec= line is the payload's, with the plain program
# name replaced by the absolute installed path, because ~/.local/bin is not on
# every desktop session's $PATH.
install_desktop_entry() {
	local source="${PAYLOAD}/packaging/desktop/${DESKTOP_NAME}" exec_value
	if [[ ! -f "${source}" ]]; then
		yellow "no ${DESKTOP_NAME} in this build; ${SETTINGS_NAME} has no launcher entry."
		return 0
	fi
	if ! exec_value="$(desktop_exec_quote "${BIN_DIR}/${SETTINGS_NAME}")"; then
		yellow "cannot write a launcher entry: ${BIN_DIR} contains a character that"
		yellow "a Desktop Entry Exec= line cannot hold (\"=\", a tab or a newline)."
		yellow "  Run ${BIN_DIR}/${SETTINGS_NAME} from a terminal instead."
		return 0
	fi

	temp_root
	local staged="${TEMP_ROOT}/${DESKTOP_NAME}"
	local from="Exec=${SETTINGS_NAME}"
	local rewrote
	rewrote="$(replace_line "${source}" "${staged}" "${from}" "Exec=${exec_value}")"
	# Exactly one, asserted, so a renamed or duplicated Exec= line in the entry
	# is an error here and not a launcher that starts nothing.
	if [[ "${rewrote}" -ne 1 ]]; then
		fail "expected exactly one '${from}' line in ${DESKTOP_NAME}, found ${rewrote}."
	fi
	mkdir -p "${DESKTOP_DIR}"
	install -m 0644 "${staged}" "${DESKTOP_DIR}/${DESKTOP_NAME}"
	echo "installed ${DESKTOP_DIR}/${DESKTOP_NAME}"
	refresh_desktop_database
}

# ---------------------------------------------------------------------------
# Enable, and what to tell the user
# ---------------------------------------------------------------------------

enable_unit() {
	if has_systemd_user_instance; then
		bold "Enabling ${UNIT_NAME}"
		systemctl --user daemon-reload
		systemctl --user enable --now "${UNIT_NAME}"
		# `enable --now` starts a unit only when it is inactive, so on the
		# upgrade path — the ordinary second run — it does nothing and the *old*
		# binary keeps running behind a rewritten unit. `try-restart` restarts
		# it only if it is already up, which is exactly the case `--now` just
		# declined to handle, and is a no-op on a first install.
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
}

# A warning, never a failure, and never an edit to the user's shell files. The
# daemon does not care about $PATH — systemd runs it by absolute path — so an
# install with the CLI off $PATH is a working install with an awkward CLI, and
# rewriting someone's .bashrc from a curl | bash script is a bigger surprise
# than the warning it would save.
warn_about_path() {
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
}

print_next_steps() {
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
}

main() {
	parse_arguments "$@"
	resolve_paths
	trap cleanup EXIT

	if [[ "${MODE}" == "uninstall" ]]; then
		uninstall
		return 0
	fi

	resolve_payload
	preflight
	install_binaries
	install_unit
	install_settings
	enable_unit
	warn_about_path
	print_next_steps
}

main "$@"
