#!/usr/bin/env bash
#
# Runs things inside a live headless KDE Plasma 6.4 session — SteamOS 3.8's
# packages, see docker/Dockerfile.kde — so the Linux desktop app can be tested
# against the Deck's compositor, tray host and portal.
#
#   scripts/kde.sh up                 start the session (reuses a running one)
#   scripts/kde.sh up --fresh         throw the running one away first
#   scripts/kde.sh down               stop and remove it
#   scripts/kde.sh shot NAME          screenshot to build/kde/NAME.png
#   scripts/kde.sh key ctrl+alt+v     a real key press, through KWin's input
#   scripts/kde.sh click X Y          a real left click at X,Y (1280x800 space)
#   scripts/kde.sh                    an interactive shell in the session
#   scripts/kde.sh skrepka-gui --picker   any command in the session
#
# The session is one long-lived container, `skrepka-kde`, whose main process is
# docker/kde/session.sh; `up` waits until that reports ready (roughly 30-60 s
# under Rosetta). Every other command is a `docker exec` as the `deck` user
# with the session's D-Bus, Wayland and Xwayland addresses sourced from
# /tmp/kde/env, so what runs is an ordinary client of the session — the same
# position skrepka-gui is in on a Deck. Starting anything but `up`/`down`
# brings the session up first if it is not running.
#
# build/kde on the host is /out in the container. Screenshots land there;
# component logs are at /tmp/kde/logs/*.log inside (`scripts/kde.sh cat
# /tmp/kde/logs/kwin.log`).
#
# `key` and `click` go through xdotool on the Xvfb display KWin's windowed
# backend draws into (docker/kde/session.sh says why that display exists). To
# KWin they are real input from its only keyboard and pointer, so a key press
# reaches kglobalaccel's shortcut matching exactly as a Deck keyboard's would.
# Key names are xdotool's: ctrl, alt, shift, super, and X keysym names.
#
# SKREPKA_KDE_IMAGE overrides the image (default skrepka-kde:3.8, built by
# scripts/kde-image.sh); SKREPKA_KDE_CONTAINER the container name.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

if ! docker info > /dev/null 2>&1; then
	echo "docker is not reachable." >&2
	echo "OrbStack exposes its socket at ~/.orbstack/run/docker.sock; under a" >&2
	echo "sandbox that path has to be granted before this script can run." >&2
	exit 1
fi

IMAGE="${SKREPKA_KDE_IMAGE:-skrepka-kde:3.8}"
CONTAINER="${SKREPKA_KDE_CONTAINER:-skrepka-kde}"
READY_TIMEOUT=180

if ! docker image inspect "${IMAGE}" > /dev/null 2>&1; then
	echo "${IMAGE} is not built yet. Build it with: scripts/kde-image.sh" >&2
	exit 1
fi

running() {
	[[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2> /dev/null)" == "true" ]]
}

down() {
	docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true
}

# --cap-add SYS_NICE: kwin_wayland carries the file capability cap_sys_nice=ep,
# and Docker's default bounding set does not include it, so without this the
# kernel refuses to exec it at all — "Operation not permitted" on
# /usr/sbin/kwin_wayland, before KWin runs a line.
# --shm-size: Qt and GTK clients exchange wl_shm buffers through /dev/shm, and
# Docker's 64 MB default runs out with a few 1280x800 surfaces.
up() {
	if running; then
		return 0
	fi
	down
	mkdir -p "${REPO}/build/kde"
	docker run -d --name "${CONTAINER}" --platform linux/amd64 \
		--cap-add SYS_NICE --shm-size 512m \
		-v "${REPO}/build/kde:/out" \
		"${IMAGE}" skrepka-kde-session > /dev/null
	local waited=0
	until docker exec "${CONTAINER}" test -f /tmp/kde/ready 2> /dev/null; do
		if ! running; then
			echo "the session exited while starting:" >&2
			docker logs "${CONTAINER}" 2>&1 | tail -20 >&2
			exit 1
		fi
		if ((waited >= READY_TIMEOUT)); then
			echo "the session was not ready after ${READY_TIMEOUT}s." >&2
			docker logs "${CONTAINER}" 2>&1 | tail -20 >&2
			exit 1
		fi
		sleep 2
		waited=$((waited + 2))
	done
	docker logs "${CONTAINER}" 2>&1 | tail -1
}

# `-it` only with a terminal on both ends, for the reason scripts/linux.sh gives.
TTY_ARGS=(-i)
[[ -t 0 && -t 1 ]] && TTY_ARGS=(-it)

in_session() {
	docker exec "${TTY_ARGS[@]}" -u deck "${CONTAINER}" \
		bash -c 'source /tmp/kde/env && exec "$@"' bash "$@"
}

case "${1:-}" in
	up)
		[[ "${2:-}" == "--fresh" ]] && down
		up
		;;
	down)
		down
		;;
	shot)
		if [[ -z "${2:-}" ]]; then
			echo "usage: scripts/kde.sh shot NAME" >&2
			exit 64
		fi
		up
		in_session skrepka-kde-screenshot "/out/${2%.png}.png" > /dev/null
		echo "build/kde/${2%.png}.png"
		;;
	key)
		up
		shift
		# shellcheck disable=SC2016 # expanded by the session's shell, not this one
		in_session bash -c 'DISPLAY="${SKREPKA_KDE_OUTER_DISPLAY}" xdotool key --delay 50 "$@"' bash "$@"
		;;
	click)
		if [[ $# -ne 3 ]]; then
			echo "usage: scripts/kde.sh click X Y" >&2
			exit 64
		fi
		up
		# shellcheck disable=SC2016 # expanded by the session's shell, not this one
		in_session bash -c 'DISPLAY="${SKREPKA_KDE_OUTER_DISPLAY}" xdotool mousemove "$1" "$2" sleep 0.2 click 1' bash "$2" "$3"
		;;
	"")
		up
		in_session bash
		;;
	*)
		up
		in_session "$@"
		;;
esac
