#!/usr/bin/env bash
#
# The inside half of scripts/run-linux.sh: runs under the Linux toolchain,
# starts the dev daemon in the background and the dev app in the foreground,
# and stops the daemon when the app exits. Not meant to be run by hand.
#
#   scripts/lib/dev-session.sh <bin-dir> <data-dir>
#
# Both processes run here rather than one per runner call so that, under the
# nix sandbox, the daemon and the app share one sandbox and this script can
# signal the daemon directly instead of reaching through bubblewrap.

set -euo pipefail

BIN="$1"
DATA_DIR="$2"
BUS_NAME="dev.soldunov.Skrepka"

# shellcheck source=scripts/lib/session-bus.sh
source "$(dirname "$0")/session-bus.sh"

mkdir -p "${DATA_DIR}"

DAEMON_ARGS=(--data-dir "${DATA_DIR}" --log-level "${SKREPKA_DEV_LOG_LEVEL:-debug}")
if [[ "${SKREPKA_DEV_SYNC:-0}" != "1" ]]; then
	DAEMON_ARGS+=(--no-sync)
fi

"${BIN}/skrepkad" "${DAEMON_ARGS[@]}" &
DAEMON=$!

stop_daemon() {
	if kill -0 "${DAEMON}" 2> /dev/null; then
		kill -TERM "${DAEMON}" 2> /dev/null || true
	fi
	# `wait` reports the daemon's own status; a daemon stopped by the signal
	# above is not a failure of this script.
	wait "${DAEMON}" 2> /dev/null || true
}
trap stop_daemon EXIT

# The app must not start before the daemon owns its name: its first call would
# have the bus activate the installed daemon instead. Ten seconds is far more
# than a debug build needs to claim it.
for _ in $(seq 1 100); do
	if ! kill -0 "${DAEMON}" 2> /dev/null; then
		echo "skrepkad exited before it claimed ${BUS_NAME}; its log is above." >&2
		exit 1
	fi
	if session_bus_name_owned "${BUS_NAME}"; then
		break
	fi
	sleep 0.1
done
if ! session_bus_name_owned "${BUS_NAME}"; then
	echo "skrepkad did not claim ${BUS_NAME} within 10 seconds." >&2
	exit 1
fi

# SKREPKA_GUI_EXECUTABLE is what Settings writes into an autostart entry. The
# name on PATH, not this build's path under .build-linux, so turning autostart
# on from a dev run leaves an entry that starts the installed app.
SKREPKA_GUI_EXECUTABLE=skrepka-gui "${BIN}/skrepka-gui"
