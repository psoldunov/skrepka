#!/usr/bin/env bash
#
# Runs the Steam Deck checks against a Linux release tarball, inside a fresh
# headless KDE Plasma 6.4.3 session built from SteamOS 3.8's packages.
#
#   scripts/kde-smoke.sh                                   the v0.3.0 release
#   SKREPKA_KDE_RELEASE=v0.3.1 scripts/kde-smoke.sh        another release
#   SKREPKA_TARBALL=build/deck/skrepka-linux-x86_64.tar.gz scripts/kde-smoke.sh
#
# SKREPKA_TARBALL installs a tarball already on disk — what scripts/build-deck.sh
# produces — instead of downloading one; its .sha256 beside it is copied along
# and checked by install.sh when present. It is installed with its own
# install.sh --tarball, as a user would, into a fresh `deck` home.
#
# The checks, each PASS or FAIL:
#
#   1 tray      skrepka-gui --background registers a StatusNotifierItem with
#               the watcher, and plasmashell (the tray host) is running.
#   2 shortcut  the GlobalShortcuts portal binds show-picker (KDE asks with a
#               "Global Shortcuts Requested" dialog, which this accepts with
#               Return, as a user would), and pressing the bound keys for real
#               opens the picker.
#   3 picker    skrepka-gui --picker maps a window, and its drop shadow is not
#               cut off at the surface edge. Measured, not eyeballed: the
#               screen is captured before and after, and the change right
#               inside the surface's left and bottom edges is compared with the
#               change right outside. A shadow that fades out inside its
#               surface changes nothing at the edge; one the surface is too
#               small for leaves a step there — the hard rectangle seen on the
#               Deck.
#   4 focus     with the picker open, a real click on the desktop closes it.
#               That is the behaviour this check assumes is wanted (the macOS
#               picker closes when it loses focus); on 0.2.1 it stays open.
#
# Everything lands in build/kde/smoke/<run>/: shots/ (screenshots and a 4x
# crop of the shadow corner), logs/ (skrepka-gui and skrepkad stderr, portal
# traffic, the session's component logs), summary.txt. Exit status 1 when any
# check fails or stops without reporting a result.
#
# Takes about two minutes after the image exists (scripts/kde-image.sh).
#
# One known difference from a Deck: KWin composites with QPainter here, not
# OpenGL, because the container has no GPU render node — see
# docker/kde/session.sh. What is drawn is the same client buffers; KWin's own
# OpenGL-only effects (blur, the screenshot effect) are absent.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

RELEASE="${SKREPKA_KDE_RELEASE:-v0.3.0}"
ASSET=skrepka-linux-x86_64.tar.gz
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${REPO}/build/kde/smoke/${RUN_ID}"
RUN="/out/smoke/${RUN_ID}"
mkdir -p "${RUN_DIR}/input" "${RUN_DIR}/logs" "${RUN_DIR}/shots"

# ---------------------------------------------------------------------------
# The subject
# ---------------------------------------------------------------------------

if [[ -n "${SKREPKA_TARBALL:-}" ]]; then
	if [[ ! -f "${SKREPKA_TARBALL}" ]]; then
		echo "SKREPKA_TARBALL=${SKREPKA_TARBALL} does not exist." >&2
		exit 1
	fi
	SOURCE="${SKREPKA_TARBALL}"
else
	CACHE="${REPO}/build/kde/release/${RELEASE}"
	SOURCE="${CACHE}/${ASSET}"
	if [[ ! -f "${SOURCE}" ]]; then
		mkdir -p "${CACHE}"
		URL="https://github.com/psoldunov/skrepka/releases/download/${RELEASE}/${ASSET}"
		echo "downloading ${URL}"
		curl -fsSL -o "${SOURCE}.part" "${URL}"
		curl -fsSL -o "${SOURCE}.sha256" "${URL}.sha256"
		mv "${SOURCE}.part" "${SOURCE}"
	fi
fi
cp "${SOURCE}" "${RUN_DIR}/input/${ASSET}"
if [[ -f "${SOURCE}.sha256" ]]; then
	cp "${SOURCE}.sha256" "${RUN_DIR}/input/${ASSET}.sha256"
fi
echo "subject: ${SOURCE}"
echo "run:     build/kde/smoke/${RUN_ID}"

scripts/kde.sh up --fresh

# Runs a bash script from stdin inside the session, with RUN set.
session() {
	scripts/kde.sh env RUN="${RUN}" bash -s
}

# ---------------------------------------------------------------------------
# Setup: install, start the daemon and the app, give the history something
# ---------------------------------------------------------------------------

session << 'EOF'
set -euo pipefail
mkdir -p /tmp/rel
tar -xzf "${RUN}/input/skrepka-linux-x86_64.tar.gz" -C /tmp/rel
bash /tmp/rel/*/install.sh --tarball "${RUN}/input/skrepka-linux-x86_64.tar.gz" \
	> "${RUN}/logs/install.log" 2>&1

# The portal traffic the app starts with: every error on the bus, and every
# Registry, GlobalShortcuts and Request message.
nohup dbus-monitor "type=error" \
	"interface=org.freedesktop.host.portal.Registry" \
	"interface=org.freedesktop.portal.GlobalShortcuts" \
	"interface=org.freedesktop.portal.Request" \
	> "${RUN}/logs/dbus-portal.log" 2>&1 &

# install.sh starts the app itself (`setsid -f skrepka-gui --background`, output
# to /dev/null), and the app D-Bus-activates the daemon. Both are stopped and
# started again here so their stderr is kept: a second `--background` would
# only hand off to the running instance and exit.
pkill -x skrepka-gui || true
pkill -x skrepkad || true
for _ in $(seq 40); do
	pgrep -x 'skrepka-gui|skrepkad' > /dev/null || break
	sleep 0.25
done

# No systemd user manager in the container, so the unit install.sh wrote cannot
# run; the daemon is started the way the unit would, and before the app, so
# its stderr lands here instead of being D-Bus-activated into dbus-daemon's.
nohup ~/.local/bin/skrepkad > "${RUN}/logs/skrepkad.log" 2>&1 &
for _ in $(seq 40); do
	busctl --user status dev.soldunov.Skrepka > /dev/null 2>&1 && break
	sleep 0.25
done
nohup ~/.local/bin/skrepka-gui --background > "${RUN}/logs/skrepka-gui.log" 2>&1 &
echo $! > /tmp/kde/gui.pid
for text in "hello from the Deck box" "second entry: kwin 6.4.3" \
	"https://github.com/psoldunov/skrepka"; do
	printf '%s' "${text}" | wl-copy
	sleep 1.5
done
EOF

# ---------------------------------------------------------------------------
# 1. Tray
# ---------------------------------------------------------------------------

session << 'EOF' | tee "${RUN_DIR}/logs/1-tray.txt"
set -uo pipefail
pid="$(cat /tmp/kde/gui.pid)"
items=""
for _ in $(seq 80); do
	items="$(busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher \
		org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems 2> /dev/null)"
	[[ "${items}" == *"-${pid}-"* ]] && break
	sleep 0.25
done
echo "watcher: ${items}"
item="$(grep -o "org.kde.StatusNotifierItem-${pid}-[0-9]*" <<< "${items}" | head -1)"
if [[ -n "${item}" ]]; then
	for property in Id Title Status IconName Menu ItemIsMenu; do
		echo "${property}: $(busctl --user get-property "${item}" /StatusNotifierItem \
			org.kde.StatusNotifierItem "${property}" 2>&1)"
	done
fi
skrepka-kde-screenshot "${RUN}/shots/1-tray.png" > /dev/null
ffmpeg -hide_banner -loglevel error -i "${RUN}/shots/1-tray.png" \
	-vf "crop=640:60:640:740,scale=1280:120:flags=neighbor" -y "${RUN}/shots/1-tray-panel-x2.png"
if [[ -n "${item}" ]] && pgrep -x plasmashell > /dev/null; then
	echo "RESULT 1 tray PASS: ${item} registered, plasmashell hosting"
else
	echo "RESULT 1 tray FAIL: no item for skrepka-gui pid ${pid}"
fi
EOF

# ---------------------------------------------------------------------------
# 2. Shortcut
# ---------------------------------------------------------------------------

session << 'EOF' | tee "${RUN_DIR}/logs/2-shortcut.txt"
set -uo pipefail
rc=~/.config/kglobalshortcutsrc
trigger() {
	awk -F'[=,]' '/^\[dev\.soldunov\.Skrepka\.App\]/ {s=1; next} /^\[/ {s=0}
		s && $1 == "show-picker" {print $2; exit}' "${rc}" 2> /dev/null
}
picker_open() { skrepka-kde-windows | grep -q '|skrepka-gui|'; }

dialog=no
for _ in $(seq 30); do
	[[ -n "$(trigger)" ]] && break
	if skrepka-kde-windows | grep -q '^Global Shortcuts Requested|'; then
		dialog=yes
		skrepka-kde-screenshot "${RUN}/shots/2-shortcut-dialog.png" > /dev/null
		DISPLAY="${SKREPKA_KDE_OUTER_DISPLAY}" xdotool key Return
		sleep 2
	fi
	sleep 0.5
done
echo "dialog shown: ${dialog}"
echo "kglobalshortcutsrc: $(grep -A3 '^\[dev\.soldunov\.Skrepka\.App\]' "${rc}" 2> /dev/null | tr '\n' ' ')"
echo "portal errors:"
grep -a -A1 '^error' "${RUN}/logs/dbus-portal.log" | grep -a 'string' | sort | uniq -c

keys="$(trigger)"
if [[ -z "${keys}" ]]; then
	echo "RESULT 2 shortcut FAIL: show-picker never bound (no dialog, nothing in kglobalshortcutsrc)"
	exit 0
fi
# KDE's "Meta+Shift+V" as xdotool's "super+shift+v".
xkeys="$(sed -e 's/Meta/super/g; s/Ctrl/ctrl/g; s/Alt/alt/g; s/Shift/shift/g' <<< "${keys}" \
	| awk -F+ '{ $NF = tolower($NF); print }' OFS=+)"
DISPLAY="${SKREPKA_KDE_OUTER_DISPLAY}" xdotool key "${xkeys}"
opened=no
for _ in $(seq 12); do
	picker_open && { opened=yes; break; }
	sleep 0.5
done
skrepka-kde-screenshot "${RUN}/shots/2-shortcut-pressed.png" > /dev/null
DISPLAY="${SKREPKA_KDE_OUTER_DISPLAY}" xdotool key Escape
sleep 1
if [[ "${opened}" == yes ]]; then
	echo "RESULT 2 shortcut PASS: bound to ${keys}; pressing ${xkeys} opened the picker"
else
	echo "RESULT 2 shortcut FAIL: bound to ${keys}, but pressing ${xkeys} did not open the picker"
fi
EOF

# ---------------------------------------------------------------------------
# 3. Picker, and its shadow
# ---------------------------------------------------------------------------

session << 'EOF' | tee "${RUN_DIR}/logs/3-picker.txt"
set -uo pipefail
skrepka-kde-screenshot "${RUN}/shots/3-before.png" > /dev/null
~/.local/bin/skrepka-gui --picker >> "${RUN}/logs/skrepka-gui.log" 2>&1
window=""
for _ in $(seq 20); do
	window="$(skrepka-kde-windows | grep '|skrepka-gui|' | head -1)"
	[[ -n "${window}" ]] && break
	sleep 0.5
done
if [[ -z "${window}" ]]; then
	echo "RESULT 3 picker FAIL: skrepka-gui --picker mapped no window"
	exit 0
fi
sleep 1
skrepka-kde-screenshot "${RUN}/shots/3-picker.png" > /dev/null
echo "window: ${window}"
geometry="$(cut -d'|' -f4 <<< "${window}")"
python3 - "${geometry}" "${RUN}/shots/3-before.png" "${RUN}/shots/3-picker.png" << 'PY'
# Mean brightness change, before vs after the picker mapped, on the surface's
# outermost rows and columns and on the ones just outside.
import subprocess, sys
x, y, size = sys.argv[1].split(",")
w, h = size.split("x")
x, y, w, h = int(x), int(y), int(w), int(h)
W, H = 1280, 800
def gray(path):
    return subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-f", "rawvideo",
                           "-pix_fmt", "gray", "-"], capture_output=True, check=True).stdout
a, b = gray(sys.argv[2]), gray(sys.argv[3])
def delta(points):
    points = [(px, py) for px, py in points if 0 <= px < W and 0 <= py < H]
    return sum(abs(a[py * W + px] - b[py * W + px]) for px, py in points) / max(len(points), 1)
if (x, y, w, h) == (0, 0, W, H):
    # A picker that covers the output — the transparent overlay — has no
    # surface edge for a shadow to be cut at, so look for the cut in the fade
    # itself: find the panel as the region that changed a lot, then walk out
    # from its left side and from its bottom to the screen edge. A shadow that
    # fades out changes by a level or two per pixel once clear of the panel's
    # own edge; the 0.2.1 clip was a jump of 6 to 12 levels.
    strong = [i for i in range(W * H) if abs(a[i] - b[i]) > 40]
    if not strong:
        print("RESULT 3 picker FAIL: an overlay mapped, but nothing on screen changed")
        sys.exit(0)
    xs, ys = [i % W for i in strong], [i // W for i in strong]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    mid_y, mid_x = (y0 + y1) // 2, (x0 + x1) // 2
    left = [abs(a[mid_y * W + c] - b[mid_y * W + c]) for c in range(x0 - 12, -1, -1)]
    below = [abs(a[r * W + mid_x] - b[r * W + mid_x]) for r in range(y1 + 12, H)]
    def step(profile):
        return max((abs(profile[i] - profile[i + 1]) for i in range(len(profile) - 1)), default=0)
    print(f"panel {x1 - x0 + 1}x{y1 - y0 + 1} at {x0},{y0}; "
          f"largest step in the fade: left {step(left)}, below {step(below)}; "
          f"change at the screen edge: left {left[-1] if left else 0}, bottom {below[-1] if below else 0}")
    cut = [name for name, profile in (("left", left), ("bottom", below))
           if step(profile) >= 4 or (profile and profile[-1] >= 2)]
    corner_x, corner_y = max(0, x0 - 40), min(H - 140, max(0, y1 - 100))
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", sys.argv[3], "-vf",
                    f"crop=200:140:{corner_x}:{corner_y},scale=800:560:flags=neighbor,eq=contrast=3",
                    "-y", sys.argv[3].replace("3-picker.png", "3-picker-shadow-corner-x4.png")], check=False)
    if cut:
        print(f"RESULT 3 picker FAIL: full-screen overlay, but its shadow is cut on the {' and '.join(cut)}")
    else:
        print(f"RESULT 3 picker PASS: full-screen overlay, panel at {x0},{y0}, shadow fades out")
    sys.exit(0)
rows = range(y + h // 4, y + 3 * h // 4)
cols = range(x + w // 4, x + 3 * w // 4)
left_in, left_out = delta((x, r) for r in rows), delta((x - 1, r) for r in rows)
bottom_in, bottom_out = delta((c, y + h - 1) for c in cols), delta((c, y + h) for c in cols)
print(f"left edge:   change inside {left_in:.1f}, outside {left_out:.1f}")
print(f"bottom edge: change inside {bottom_in:.1f}, outside {bottom_out:.1f}")
clipped = [name for name, inside, outside in
           (("left", left_in, left_out), ("bottom", bottom_in, bottom_out))
           if inside >= 2.0 and inside > 3 * outside]
if clipped:
    print(f"RESULT 3 picker FAIL: shows, but its shadow is cut off at the {' and '.join(clipped)} "
          f"edge of the {w}x{h} surface")
else:
    print(f"RESULT 3 picker PASS: shows, {w}x{h} surface, shadow fades out inside it")
PY
# A full-output overlay's corner crop is made above, around the panel.
if [[ "${geometry}" != "0,0,1280x800" ]]; then
	cx=$(( $(cut -d, -f1 <<< "${geometry}") - 40 ))
	cy=$(( $(cut -d, -f2 <<< "${geometry}") + $(cut -dx -f2 <<< "${geometry}") - 100 ))
	ffmpeg -hide_banner -loglevel error -i "${RUN}/shots/3-picker.png" \
		-vf "crop=200:140:${cx}:${cy},scale=800:560:flags=neighbor,eq=contrast=3" \
		-y "${RUN}/shots/3-picker-shadow-corner-x4.png"
fi
EOF

# ---------------------------------------------------------------------------
# 4. Focus: click away with the picker open
# ---------------------------------------------------------------------------

session << 'EOF' | tee "${RUN_DIR}/logs/4-focus.txt"
set -uo pipefail
if ! skrepka-kde-windows | grep -q '|skrepka-gui|'; then
	~/.local/bin/skrepka-gui --picker >> "${RUN}/logs/skrepka-gui.log" 2>&1
	sleep 2
fi
DISPLAY="${SKREPKA_KDE_OUTER_DISPLAY}" xdotool mousemove 150 150 sleep 0.3 click 1
sleep 2
skrepka-kde-screenshot "${RUN}/shots/4-after-click-away.png" > /dev/null
skrepka-kde-windows | sed 's/^/window: /'
if skrepka-kde-windows | grep -q '|skrepka-gui|'; then
	echo "RESULT 4 focus FAIL: the picker stayed open after a click on the desktop"
	DISPLAY="${SKREPKA_KDE_OUTER_DISPLAY}" xdotool key Escape
else
	echo "RESULT 4 focus PASS: a click on the desktop closed the picker"
fi
EOF

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

scripts/kde.sh bash -c "mkdir -p '${RUN}/logs/session' && cp /tmp/kde/logs/*.log '${RUN}/logs/session/'"
{
	echo "subject: ${SOURCE}"
	echo "session: $(scripts/kde.sh pacman -Q kwin plasma-workspace xdg-desktop-portal-kde gtk4 | tr '\n' ' ')"
	# No match at all is reported below, by check; only a grep error aborts here.
	grep -h '^RESULT' "${RUN_DIR}"/logs/[1-4]-*.txt || [[ $? -eq 1 ]]
} > "${RUN_DIR}/summary.txt"
echo
cat "${RUN_DIR}/summary.txt"
echo "evidence: build/kde/smoke/${RUN_ID}/"
# A section runs without set -e, so one that dies before its RESULT line can
# still exit 0 — and a missing FAIL is not a PASS.
missing=""
for check in 1 2 3 4; do
	grep -q "^RESULT ${check} " "${RUN_DIR}/summary.txt" || missing="${missing} ${check}"
done
if [[ -n "${missing}" ]]; then
	echo "no result from check${missing}: it stopped before reporting; see its log in logs/" >&2
	exit 1
fi
! grep -q '^RESULT .* FAIL' "${RUN_DIR}/summary.txt"
