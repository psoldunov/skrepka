#!/usr/bin/env bash
#
# Screenshots every pane of the Linux Settings window, dark and light, under a
# headless sway in the Linux build image — the Steam Deck's 1280×800 panel,
# without a Steam Deck.
#
#   scripts/screenshot-settings.sh              build the demo, then shoot
#   scripts/screenshot-settings.sh --no-build   shoot the demo already built
#
# Output lands in build/settings-shots/<section>-<appearance>.png, plus
# history-old-dark.png (a daemon too old to change settings),
# diagnostics-problems-dark.png, and the picker beside them for comparison —
# picker-{list,empty}-{dark,light}.png. build/ is ignored by git.
#
# The recipe is prototypes/palette-bakeoff/harness.sh's: sway with the
# headless wlroots backend, WAYLAND_DISPLAY found by hand, grim for the shot.
# What it cannot show is Breeze-GTK on the Deck — the image has Adwaita only.
#
# SKREPKA_SETTINGS_SCRATCH overrides the build's scratch path
# (default .build-linux-settings).

set -euo pipefail

cd "$(dirname "$0")/.."
SCRATCH="${SKREPKA_SETTINGS_SCRATCH:-.build-linux-settings}"

if [[ "${1:-}" != "--no-build" ]]; then
	scripts/linux.sh swift build --product skrepka-settings-demo --scratch-path "${SCRATCH}"
	scripts/linux.sh swift build --product skrepka-palette-demo --scratch-path "${SCRATCH}"
fi

# Everything below runs inside the image, where sway, grim and the binary are.
# Passed as a string rather than on stdin: scripts/linux.sh attaches stdin only
# when there is a terminal. `read -d ''` answers 1 at the end of its input,
# which is the only way it ends here.
read -r -d '' INNER << 'INNER' || true
set -uo pipefail

export XDG_RUNTIME_DIR=/tmp/xdg-settings
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"
export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_HEADLESS_OUTPUTS=1
export SWAYSOCK="${XDG_RUNTIME_DIR}/sway.sock"

BIN="$(pwd)/${SCRATCH}/debug/skrepka-settings-demo"
OUT="$(pwd)/build/settings-shots"
mkdir -p "${OUT}"
if [[ ! -x "${BIN}" ]]; then
	echo "FATAL: no demo at ${BIN}; build it first" >&2
	exit 1
fi

cat > "${XDG_RUNTIME_DIR}/sway.conf" << 'EOF'
output HEADLESS-1 resolution 1280x800 background #3a3f4b solid_color
default_border none
# A toplevel is tiled by default; float it so the window keeps the size it
# asks for, the way KWin shows it, instead of filling the output.
for_window [app_id=".*"] floating enable
exec_always true
EOF

sway -c "${XDG_RUNTIME_DIR}/sway.conf" > "${XDG_RUNTIME_DIR}/sway.log" 2>&1 &
SWAY=$!
for _ in $(seq 1 50); do
	[[ -S "${SWAYSOCK}" ]] && break
	sleep 0.2
done
for _ in $(seq 1 25); do
	SOCKET="$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -printf '%f\n' 2> /dev/null | head -1)"
	[[ -n "${SOCKET}" ]] && break
	sleep 0.2
done
if [[ -z "${SOCKET:-}" ]]; then
	echo "FATAL: sway created no wayland socket" >&2
	tail -20 "${XDG_RUNTIME_DIR}/sway.log" >&2
	exit 1
fi
export WAYLAND_DISPLAY="${SOCKET}"
export GDK_BACKEND=wayland

# shoot <file> <section> <appearance> [VAR=value ...]
shoot() {
	local file="$1" section="$2" appearance="$3"
	shift 3
	env SKREPKA_DEMO_SECTION="${section}" SKREPKA_DEMO_APPEARANCE="${appearance}" "$@" \
		"${BIN}" > "${XDG_RUNTIME_DIR}/demo.log" 2>&1 &
	local demo=$!
	sleep 2.5
	grim "${OUT}/${file}.png" && echo "shot ${OUT}/${file}.png"
	kill "${demo}" 2> /dev/null
	wait "${demo}" 2> /dev/null
	if [[ -s "${XDG_RUNTIME_DIR}/demo.log" ]]; then
		sed 's/^/  demo: /' "${XDG_RUNTIME_DIR}/demo.log" | head -20
	fi
}

for appearance in dark light; do
	for section in general history privacy sync diagnostics; do
		shoot "${section}-${appearance}" "${section}" "${appearance}"
	done
done
shoot history-old-dark history dark SKREPKA_DEMO_DAEMON=old
shoot diagnostics-problems-dark diagnostics dark SKREPKA_DEMO_PROBLEMS=1

# The picker, from skrepka-palette-demo: a layer-shell overlay over the output.
BIN="$(pwd)/${SCRATCH}/debug/skrepka-palette-demo"
for appearance in dark light; do
	for state in list empty; do
		shoot "picker-${state}-${appearance}" general "${appearance}" SKREPKA_DEMO_STATE="${state}"
	done
done

swaymsg exit > /dev/null 2>&1
wait "${SWAY}" 2> /dev/null
INNER
scripts/linux.sh env SCRATCH="${SCRATCH}" bash -c "${INNER}"
