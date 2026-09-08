#!/usr/bin/env bash
#
# Installs Skrepka's Linux daemon and CLI into the user's home directory.
#
#   scripts/install.sh                     build from this checkout and install
#   scripts/install.sh --from-build DIR    install binaries already built in DIR
#   scripts/install.sh --uninstall         reverse it
#   curl -fsSL <raw-url>/scripts/install.sh | bash
#
# Everything lands under $HOME. Nothing is written outside it, nothing asks for
# root, and no package manager is involved:
#
#   ~/.local/bin/skrepkad            the daemon      ($XDG_BIN_HOME is honoured)
#   ~/.local/bin/skrepka             the CLI
#   ~/.config/systemd/user/skrepkad.service          ($XDG_CONFIG_HOME too)
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
STATE_DIR="${DATA_HOME}/skrepka"

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
session. No root, no package manager, nothing written outside $HOME.

Usage:
  install.sh                    build this checkout in release and install
  install.sh --from-build DIR   install the binaries already built in DIR
  install.sh --uninstall        stop and remove the unit and the binaries
  install.sh --help             this message

Where things land (XDG_BIN_HOME, XDG_CONFIG_HOME and XDG_DATA_HOME are
honoured when they hold an absolute path):

  ~/.local/bin/skrepkad, ~/.local/bin/skrepka
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
		"${UNIT_DIR}/${UNIT_NAME}"; do
		if [[ -e "${path}" ]]; then
			rm -f "${path}"
			echo "removed ${path}"
		fi
	done

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

if [[ -n "${FROM_BUILD}" ]]; then
	if [[ ! -d "${FROM_BUILD}" ]]; then
		echo "error: --from-build ${FROM_BUILD} is not a directory" >&2
		exit 1
	fi
	BUILD_DIR="$(cd "${FROM_BUILD}" && pwd)"
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
	BUILD_DIR="$(cd "${REPOSITORY}" && swift build -c release --show-bin-path)"
fi

for name in "${DAEMON_NAME}" "${CLI_NAME}"; do
	if [[ ! -x "${BUILD_DIR}/${name}" ]]; then
		echo "error: ${BUILD_DIR}/${name} is missing or not executable" >&2
		exit 1
	fi
done

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
	# Through a temporary file rather than `sed -i`, whose in-place flag takes a
	# mandatory argument on BSD sed and none on GNU sed; the two spellings are
	# incompatible and this script has no business caring which one it met.
	#
	# The replacement is an absolute path that contains slashes, so `|` is the
	# s/// separator. No path this script accepts can contain a newline or a
	# `|` unescaped in a way that matters, because it came from an environment
	# variable read at the top and is used only on the right-hand side.
	UNIT_STAGE="$(mktemp)"
	trap 'rm -f "${UNIT_STAGE}"; if [[ -n "${CLONE_DIRECTORY}" ]]; then rm -rf "${CLONE_DIRECTORY}"; fi' EXIT
	sed "s|^ExecStart=%h/.local/bin/${DAEMON_NAME}\$|ExecStart=${BIN_DIR}/${DAEMON_NAME}|" \
		"${REPOSITORY}/packaging/systemd/${UNIT_NAME}" > "${UNIT_STAGE}"
	install -m 0644 "${UNIT_STAGE}" "${UNIT_DIR}/${UNIT_NAME}"
	echo "unit ExecStart pointed at ${BIN_DIR}/${DAEMON_NAME} (\$XDG_BIN_HOME is set)"
fi
echo "installed ${UNIT_DIR}/${UNIT_NAME}"

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
echo "  ${CLI_NAME} --help                       what the CLI can do"
echo "  systemctl --user status ${UNIT_NAME}   is it running"
echo "  journalctl --user -u ${UNIT_NAME} -f   what it is saying"
