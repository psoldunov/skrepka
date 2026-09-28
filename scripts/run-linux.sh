#!/usr/bin/env bash
#
# The Linux Run button: builds skrepkad and skrepka-gui in debug and runs both
# against this desktop session, in the foreground, until the app quits from its
# tray menu or you press Ctrl-C. scripts/run.sh lands here on Linux.
#
#   scripts/run-linux.sh
#   SKREPKA_DEV_SYNC=1 scripts/run-linux.sh               join the network too
#   SKREPKA_DEV_DATA_DIR=/tmp/skrepka scripts/run-linux.sh another history
#   SKREPKA_DEV_LOG_LEVEL=trace scripts/run-linux.sh      the daemon's log level
#
# Only one daemon can own dev.soldunov.Skrepka on the session bus, and only one
# skrepka-gui can own the app's ID, so an installed copy steps aside for the
# run: a running tray app is asked to quit, the skrepkad user unit is stopped,
# and both come back when the run ends, however it ends.
#
# The dev daemon keeps its history, device key and settings in
# .build-linux/dev-data unless told otherwise, and does not sync unless
# SKREPKA_DEV_SYNC=1. Your real history is not a test fixture, and a second
# device key announcing itself would look like a new machine to every peer you
# have paired.
#
# Quitting from the tray is the clean exit. Ctrl-C works too, but under the nix
# sandbox the interrupt can reach bubblewrap before the daemon finishes shutting
# down, and bubblewrap takes the daemon with it — harmless for a dev data dir.
#
# Needs a toolchain that can reach this session: native, or the nix sandbox.
# The build image has no display and no session bus, so the container runner
# is refused rather than started.

set -euo pipefail

cd "$(dirname "$0")/.."
REPOSITORY="$(pwd -P)"

# shellcheck source=scripts/lib/linux-env.sh
source scripts/lib/linux-env.sh
# shellcheck source=scripts/lib/session-bus.sh
source scripts/lib/session-bus.sh

UNIT="skrepkad.service"
BUS_NAME="dev.soldunov.Skrepka"
APP_ID="dev.soldunov.Skrepka.App"
SCRATCH=".build-linux"
BIN="${REPOSITORY}/${SCRATCH}/debug"
DATA_DIR="${SKREPKA_DEV_DATA_DIR:-${REPOSITORY}/${SCRATCH}/dev-data}"

bold() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1" >&2; }
fail() {
	printf '\033[31merror: %s\033[0m\n' "$1" >&2
	exit 1
}

[[ "$(uname -s)" == "Linux" ]] || fail "scripts/run-linux.sh runs the Linux app; on macOS use scripts/run.sh."

RUNNER="$(linux_env_runner)"
case "${RUNNER}" in
	native | nix) ;;
	container) fail "the container runner has no display or session bus to run the app against. Install nix, or a Swift 6.3 toolchain with the -dev packages docker/Dockerfile.linux lists." ;;
	*) linux_env_exec "${RUNNER}" ;;
esac

if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
	fail "neither WAYLAND_DISPLAY nor DISPLAY is set; run this from inside a desktop session."
fi
BUS_STATUS=0
session_bus_name_owned org.freedesktop.DBus || BUS_STATUS=$?
if ((BUS_STATUS == 2)); then
	fail "cannot ask the session bus anything: none of busctl, gdbus or dbus-send is on PATH, or there is no session bus."
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

bold "Building skrepkad and skrepka-gui (debug)"
# One product per invocation: `swift build --product A --product B` builds only
# the last one and exits 0 (docs/linux-sync/open-questions.md, OQ-13).
scripts/linux-env.sh swift build --product skrepkad --scratch-path "${SCRATCH}"
scripts/linux-env.sh swift build --product skrepka-gui --scratch-path "${SCRATCH}"

# ---------------------------------------------------------------------------
# Move the installed copy aside, and put it back on the way out
# ---------------------------------------------------------------------------

UNIT_WAS_ACTIVE=0
GUI_WAS_RUNNING=0

restore() {
	if ((UNIT_WAS_ACTIVE)); then
		bold "Restarting ${UNIT}"
		systemctl --user start "${UNIT}" || yellow "could not restart ${UNIT}; run: systemctl --user start ${UNIT}"
	fi
	if ((GUI_WAS_RUNNING)); then
		bold "Relaunching the installed skrepka-gui"
		# Detached, so it outlives this script and the terminal it ran in.
		setsid -f skrepka-gui --background > /dev/null 2>&1 \
			|| yellow "could not relaunch skrepka-gui; start it from your app launcher."
	fi
}
trap restore EXIT
# An interrupted or terminated bash does not always run an EXIT trap on its
# own; turning the signals into exits makes sure it does.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The app first: while it runs, a daemon stopped under it can be re-activated
# by its next call.
if session_bus_name_owned "${APP_ID}"; then
	command -v skrepka-gui > /dev/null 2>&1 \
		|| fail "an installed skrepka-gui is running but is not on PATH to ask it to quit. Quit it from its tray menu and run this again."
	bold "Quitting the installed skrepka-gui"
	GUI_WAS_RUNNING=1
	skrepka-gui --quit || true
	for _ in $(seq 1 50); do
		session_bus_name_owned "${APP_ID}" || break
		sleep 0.1
	done
	if session_bus_name_owned "${APP_ID}"; then
		fail "the installed skrepka-gui did not quit within 5 seconds. Quit it from its tray menu and run this again."
	fi
fi

if command -v systemctl > /dev/null 2>&1 && systemctl --user is-active --quiet "${UNIT}"; then
	bold "Stopping ${UNIT}"
	UNIT_WAS_ACTIVE=1
	systemctl --user stop "${UNIT}"
fi

if session_bus_name_owned "${BUS_NAME}"; then
	fail "something still owns ${BUS_NAME} on the session bus — a skrepkad started by hand, or by another unit. Stop it and run this again."
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

bold "Running the dev build — data in ${DATA_DIR}$([[ "${SKREPKA_DEV_SYNC:-0}" == "1" ]] || printf ', sync off')"
echo "Quit from the tray menu, or press Ctrl-C."
scripts/linux-env.sh scripts/lib/dev-session.sh "${BIN}" "${DATA_DIR}"
