#!/usr/bin/env bash
#
# Starts a headless Plasma 6 Wayland session inside the skrepka-kde image and
# keeps it running. The container's main process: scripts/kde.sh starts the
# container with this, waits for /tmp/kde/ready, then `docker exec`s commands
# into the session with /tmp/kde/env sourced.
#
# Not startplasma-wayland. That script launches kwin_wayland_wrapper with no
# backend flag, so KWin picks DRM, which a container has none of; and its
# plasma_session half expects a systemd user manager to start the rest. Here
# the pieces are started by hand:
#
#   Xvfb :99            the outer "monitor". See below.
#   dbus-daemon         the session bus, one per container.
#   kwin_wayland        --x11-display :99 is the X11-windowed backend: KWin
#                       draws its whole output into one window on Xvfb, at the
#                       Deck's 1280x800. --xwayland for X11 clients (a second X
#                       server, :0, inside the session); --no-lockscreen because
#                       nothing here can unlock it. KGlobalAccel lives inside
#                       KWin on Plasma 6.
#   xdg-desktop-portal  and its KDE backend, for GlobalShortcuts. Started
#                       before anything that could D-Bus-activate them, or the
#                       explicit start loses the name race.
#   kded6               hosts org.kde.StatusNotifierWatcher, the tray's
#                       registry.
#   plasmashell         the panel and the system tray applet — the tray host.
#
# Why Xvfb rather than `kwin_wayland --virtual`. Both run, and both composite
# with QPainter, not OpenGL: every KWin 6 backend allocates GL buffers through
# GBM, GBM needs a DRM render node, and OrbStack's VM has none (no /dev/dri; its
# kernel has virtio_gpu with no device and no vgem). Without OpenGL, KWin does
# not load its screenshot effect, so org.kde.KWin.ScreenShot2 — and spectacle,
# which uses it — do not exist. The X11-windowed backend makes KWin's output an
# ordinary X window, which ffmpeg's x11grab can read (skrepka-kde-screenshot),
# and makes its input an ordinary X window's input, which xdotool can drive —
# real key and pointer events entering KWin through its input stack, global
# shortcuts included.
#
# KWIN_WAYLAND_NO_PERMISSION_CHECKS (the name is in libkwin.so.6.4.3) is
# deliberately NOT set. It would have been the way to let a test call
# ScreenShot2, which does not exist here anyway, and it also hands every client
# the restricted Wayland globals — org_kde_kwin_fake_input,
# zkde_screencast_unstable_v1 and the rest — which a Deck does not. A test that
# passes only because of that would be testing a desktop nobody runs.
#
# Logs: /tmp/kde/logs/<component>.log.

set -euo pipefail

STATE=/tmp/kde
LOGS="${STATE}/logs"
WIDTH="${SKREPKA_KDE_WIDTH:-1280}"
HEIGHT="${SKREPKA_KDE_HEIGHT:-800}"
OUTER_DISPLAY=:99
mkdir -p "${LOGS}"
rm -f "${STATE}/ready" "${STATE}/env"

mkdir -p "${XDG_RUNTIME_DIR}"
chmod 0700 "${XDG_RUNTIME_DIR}"

# Waits up to $2 seconds for the command $1 to succeed.
wait_for() {
	local check="$1" seconds="$2"
	for _ in $(seq $((seconds * 4))); do
		if eval "${check}" > /dev/null 2>&1; then
			return 0
		fi
		sleep 0.25
	done
	echo "timed out after ${seconds}s waiting for: ${check}" >&2
	return 1
}

Xvfb "${OUTER_DISPLAY}" -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp \
	> "${LOGS}/xvfb.log" 2>&1 &
wait_for "test -S /tmp/.X11-unix/X${OUTER_DISPLAY#:}" 30

DBUS_SESSION_BUS_ADDRESS="$(dbus-daemon --session --fork --print-address=1 --nopidfile)"
export DBUS_SESSION_BUS_ADDRESS
export WAYLAND_DISPLAY=wayland-0
export QT_QPA_PLATFORM=wayland

DISPLAY="${OUTER_DISPLAY}" kwin_wayland --x11-display "${OUTER_DISPLAY}" \
	--width "${WIDTH}" --height "${HEIGHT}" \
	--no-lockscreen --xwayland --socket "${WAYLAND_DISPLAY}" \
	> "${LOGS}/kwin.log" 2>&1 &
KWIN_PID=$!
wait_for "test -S ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" 60
wait_for "busctl --user status org.kde.KWin" 60

# Xwayland's display is whichever X socket is not Xvfb's.
xwayland_socket() {
	local socket
	for socket in /tmp/.X11-unix/X*; do
		if [[ -S "${socket}" && "${socket}" != "/tmp/.X11-unix/X${OUTER_DISPLAY#:}" ]]; then
			echo "${socket#/tmp/.X11-unix/X}"
			return 0
		fi
	done
	return 1
}
wait_for xwayland_socket 60
DISPLAY=":$(xwayland_socket)"
export DISPLAY

dbus-update-activation-environment DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY \
	DISPLAY QT_QPA_PLATFORM XDG_CURRENT_DESKTOP XDG_SESSION_TYPE \
	XDG_SESSION_DESKTOP KDE_FULL_SESSION KDE_SESSION_VERSION DESKTOP_SESSION

/usr/lib/xdg-desktop-portal-kde > "${LOGS}/xdg-desktop-portal-kde.log" 2>&1 &
wait_for "busctl --user status org.freedesktop.impl.portal.desktop.kde" 60
/usr/lib/xdg-desktop-portal > "${LOGS}/xdg-desktop-portal.log" 2>&1 &
wait_for "busctl --user status org.freedesktop.portal.Desktop" 60

kded6 > "${LOGS}/kded6.log" 2>&1 &
wait_for "busctl --user status org.kde.StatusNotifierWatcher" 60

plasmashell --no-respawn > "${LOGS}/plasmashell.log" 2>&1 &
wait_for "busctl --user status org.kde.plasmashell" 90
# plasmashell owns its bus name well before it has mapped anything. Ready
# means the desktop and the panel are both on screen, and then a moment more
# for the wallpaper to finish decoding: a screenshot taken sooner shows black.
plasmashell_windows() {
	[[ "$(skrepka-kde-windows | grep -c '|plasmashell|')" -ge 2 ]]
}
wait_for plasmashell_windows 90
sleep 3

# What every later `docker exec` needs to join the session.
{
	echo "export DBUS_SESSION_BUS_ADDRESS='${DBUS_SESSION_BUS_ADDRESS}'"
	echo "export WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
	echo "export DISPLAY=${DISPLAY}"
	echo "export QT_QPA_PLATFORM=wayland"
	echo "export SKREPKA_KDE_OUTER_DISPLAY=${OUTER_DISPLAY}"
	echo "export SKREPKA_KDE_WIDTH=${WIDTH}"
	echo "export SKREPKA_KDE_HEIGHT=${HEIGHT}"
} > "${STATE}/env"
touch "${STATE}/ready"
echo "session ready: ${WIDTH}x${HEIGHT}, ${WAYLAND_DISPLAY}, Xwayland ${DISPLAY}"

# The session lives as long as KWin does.
wait "${KWIN_PID}"
