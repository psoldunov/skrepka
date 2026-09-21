#!/usr/bin/env bash
#
# Lists the windows KWin is managing, one per line:
#
#   caption|resourceClass|layer|x,y,WxH|active
#
#   skrepka-kde-windows
#   skrepka-kde-windows | grep -q '^Global Shortcuts Requested|'
#
# Layer-shell surfaces are included — they are windows to KWin — so the picker
# shows up here while it is mapped, which is a firmer check than looking at
# pixels. `layer` is KWin's stacking layer number: an ordinary window is 2, the
# panel and overlay-layer surfaces higher.
#
# KWin exposes no "list windows" D-Bus call, so this loads a one-shot KWin
# script through org.kde.kwin.Scripting. The script cannot print: KWin 6.4's
# print() output never reaches kwin_wayland's stderr, whatever
# QT_LOGGING_RULES says (tried kwin_scripting.debug=true and
# kwin_scripting=true). What a script can do is callDBus(), so it sends each
# line as the argument of a harmless org.freedesktop.DBus.NameHasOwner call and
# dbus-monitor reads the arguments back off the bus. Each run tags its lines
# with a nonce so nothing else on the bus is mistaken for a window.

set -euo pipefail

# skrepka-kde-session calls this before it has written /tmp/kde/env, with the
# session's addresses already in its own environment.
if [[ -f /tmp/kde/env ]]; then
	# shellcheck source=/dev/null
	source /tmp/kde/env
fi

NONCE="w$$x${RANDOM}"
SCRIPT="$(mktemp /tmp/kde/windows-XXXXXX.js)"
CAPTURE="$(mktemp /tmp/kde/windows-XXXXXX.txt)"
MONITOR_PID=""
cleanup() {
	[[ -n "${MONITOR_PID}" ]] && kill "${MONITOR_PID}" 2> /dev/null
	rm -f "${SCRIPT}" "${CAPTURE}"
}
trap cleanup EXIT

cat > "${SCRIPT}" << EOF
function send(line) {
	callDBus("org.freedesktop.DBus", "/org/freedesktop/DBus",
		"org.freedesktop.DBus", "NameHasOwner", "${NONCE}|" + line);
}
for (const w of workspace.windowList()) {
	const g = w.frameGeometry;
	send(w.caption + "|" + w.resourceClass + "|" + w.layer + "|"
		+ Math.round(g.x) + "," + Math.round(g.y) + ","
		+ Math.round(g.width) + "x" + Math.round(g.height) + "|"
		+ (workspace.activeWindow === w ? "active" : ""));
}
send("END");
EOF

dbus-monitor "member=NameHasOwner" > "${CAPTURE}" 2>&1 &
MONITOR_PID=$!
sleep 0.5

id="$(busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting \
	loadScript ss "${SCRIPT}" "${NONCE}" | awk '{print $2}')"
busctl --user call org.kde.KWin "/Scripting/Script${id}" org.kde.kwin.Script run
for _ in $(seq 20); do
	grep -aq "${NONCE}|END" "${CAPTURE}" && break
	sleep 0.25
done
busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting \
	unloadScript s "${NONCE}" > /dev/null

# dbus-monitor prints the argument as:   string "w123x456|caption|..."
grep -a "string \"${NONCE}|" "${CAPTURE}" \
	| sed -e "s/^.*string \"${NONCE}|//" -e 's/"$//' \
	| grep -v '^END$' || true
