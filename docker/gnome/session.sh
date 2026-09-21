#!/usr/bin/env bash
# Starts one headless GNOME Shell Wayland session and keeps it running.
# Logs live in /tmp/gnome/logs; /tmp/gnome/env joins later docker execs to it.

set -euo pipefail

STATE=/tmp/gnome
LOGS=${STATE}/logs
WIDTH=${SKREPKA_GNOME_WIDTH:-1280}
HEIGHT=${SKREPKA_GNOME_HEIGHT:-800}
mkdir -p "${LOGS}" "${XDG_RUNTIME_DIR}"
chmod 0700 "${XDG_RUNTIME_DIR}"
rm -f "${STATE}/ready" "${STATE}/env"

wait_for() {
    local check=$1 seconds=$2
    for _ in $(seq $((seconds * 4))); do
        if eval "${check}" >/dev/null 2>&1; then return 0; fi
        sleep 0.25
    done
    echo "timed out after ${seconds}s waiting for: ${check}" >&2
    return 1
}

# GNOME components consult the system bus even though this container has no
# systemd or logind. A private bus makes those lookups fail promptly instead of
# trying to activate a bus that does not exist.
sudo install -d -m 0755 /run/dbus
sudo rm -f /run/dbus/pid
sudo dbus-daemon --system --fork --nopidfile
# Redirect as the session user so later evidence collection can always read it.
# shellcheck disable=SC2024
sudo /usr/lib/systemd/systemd-logind >"${LOGS}/systemd-logind.log" 2>&1 &
wait_for "busctl --system status org.freedesktop.login1" 30

DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --nopidfile)
export DBUS_SESSION_BUS_ADDRESS
export WAYLAND_DISPLAY=wayland-0

dbus-update-activation-environment DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP \
    XDG_SESSION_DESKTOP XDG_SESSION_TYPE DESKTOP_SESSION

# These flags are checked by scripts/gnome-image.sh against the image's own
# --help output. --unsafe-mode deliberately enables org.gnome.Shell.Eval for
# the harness's screenshots, window inspection and virtual input devices.
gnome-shell --headless --virtual-monitor "${WIDTH}x${HEIGHT}" --unsafe-mode \
    >"${LOGS}/gnome-shell.log" 2>&1 &
SHELL_PID=$!
wait_for "busctl --user status org.gnome.Shell" 90
wait_for "test -S '${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}'" 90
wait_for "skrepka-gnome-eval 'global.stage !== null'" 90

# Xwayland is lazy. Starting an innocuous X client asks Mutter to create it;
# its socket then supplies DISPLAY to every later X11 client, including xclip.
(xclip -selection clipboard -o >/dev/null 2>&1 || true) &
for _ in $(seq 120); do
    socket=$(find /tmp/.X11-unix -maxdepth 1 -type s -name 'X*' -print -quit 2>/dev/null || true)
    [[ -n "${socket}" ]] && break
    sleep 0.25
done
if [[ -n "${socket:-}" ]]; then
    DISPLAY=":${socket##*/X}"
    XAUTHORITY=$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name '.mutter-Xwaylandauth.*' -print -quit)
    export DISPLAY XAUTHORITY
fi

dbus-update-activation-environment DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY \
    DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP DESKTOP_SESSION

# Start the backend before the frontend so D-Bus activation cannot win the
# names with a differently configured instance. GNOME's backend also brokers
# the GlobalShortcuts and RemoteDesktop consent dialogs used by the smoke test.
pipewire >"${LOGS}/pipewire.log" 2>&1 &
wireplumber >"${LOGS}/wireplumber.log" 2>&1 &
PORTAL_GNOME=$(command -v xdg-desktop-portal-gnome || find /usr/libexec /usr/lib -type f -name xdg-desktop-portal-gnome -print -quit)
PORTAL=$(command -v xdg-desktop-portal || find /usr/libexec /usr/lib -type f -name xdg-desktop-portal -print -quit)
"${PORTAL_GNOME}" >"${LOGS}/xdg-desktop-portal-gnome.log" 2>&1 &
wait_for "busctl --user status org.freedesktop.impl.portal.desktop.gnome" 60
"${PORTAL}" >"${LOGS}/xdg-desktop-portal.log" 2>&1 &
wait_for "busctl --user status org.freedesktop.portal.Desktop" 60

extension=$(find /usr/share/gnome-shell/extensions -mindepth 1 -maxdepth 1 -type d \
    \( -iname '*appindicator*' -o -iname '*indicator*' \) -printf '%f\n' | head -1)
if [[ -n "${extension}" ]]; then
    gnome-extensions enable "${extension}" >"${LOGS}/appindicator-enable.log" 2>&1 || true
fi
sleep 3

{
    echo "export DBUS_SESSION_BUS_ADDRESS='${DBUS_SESSION_BUS_ADDRESS}'"
    echo "export WAYLAND_DISPLAY='${WAYLAND_DISPLAY}'"
    [[ -n "${DISPLAY:-}" ]] && echo "export DISPLAY='${DISPLAY}'"
    [[ -n "${XAUTHORITY:-}" ]] && echo "export XAUTHORITY='${XAUTHORITY}'"
    echo "export SKREPKA_GNOME_WIDTH='${WIDTH}'"
    echo "export SKREPKA_GNOME_HEIGHT='${HEIGHT}'"
} >"${STATE}/env"
touch "${STATE}/ready"
echo "session ready: ${WIDTH}x${HEIGHT}, ${WAYLAND_DISPLAY}, Xwayland ${DISPLAY:-unavailable}"
wait "${SHELL_PID}"
