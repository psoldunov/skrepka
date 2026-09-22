#!/usr/bin/env bash
#
# Records the Linux half of the README demo: one continuous screen capture of
# the headless KDE Plasma 6.4.3 session, dark, at the Deck's native 1280x800,
# in which the real global shortcut opens the Skrepka picker over a Dolphin
# window, the wallpaper file copied on the Mac is pasted into the folder, and
# the Plasma desktop is then set to it.
#
#   scripts/record-demo-linux.sh
#   SKREPKA_TARBALL=build/deck/skrepka-linux-x86_64.tar.gz scripts/record-demo-linux.sh
#
# Needs a Linux release tarball — scripts/build-deck.sh writes
# build/deck/skrepka-linux-x86_64.tar.gz, which is the default subject — and
# the session image scripts/kde-image.sh builds. The session has no repo mount,
# so the tarball is how the binaries get in; it is installed with its own
# install.sh, as a user would, into a fresh `deck` home.
#
# Output:
#
#   build/demo/linux.mov          the take: H.264 in a .mov, 1280x800
#   build/kde/demo/<run>/         the same file, the steps that made it, the
#                                 stills the rehearsal judged, the take's first
#                                 and last frames, and the logs
#
# What happens on camera, in order: a beat of rest on an empty Dolphin window
# showing ~/Pictures, Meta+Shift+V pressed for real through xdotool on the
# session's outer X display (so KWin and kglobalacceld route it exactly as a
# Deck keyboard would), the picker opening over Dolphin with `Sonoma.heic` —
# the wallpaper the macOS half copies out of Finder — as its top row, Return,
# the picker closing, the file appearing in the folder, the file being set as
# the desktop wallpaper, and a beat of rest with the macOS wallpaper behind the
# Plasma desktop. The GIF built from this loops, which is what the rest at both
# ends is for.
#
# The window is centred, with wallpaper showing on all four sides, because the
# wallpaper changing is the payoff and it needs room to be seen changing. The
# change happens inside the recording rather than before it: the take checks
# the desktop is drawing the stock wallpaper before the camera starts, and the
# encode checks the first and last frames of the finished file differ. Neither
# check believes what plasma-apply-wallpaperimage says about itself.
#
# Nothing is stitched: ffmpeg's x11grab reads the Xvfb display KWin's
# X11-windowed backend draws into — the same display skrepka-kde-screenshot
# reads — for the whole take, at SKREPKA_DEMO_FPS frames a second.
#
# Four things about this box that a Deck would not need.
#
# Dolphin, libheif and kimageformats are installed into the session at run
# time, because the image carries none of them (docker/Dockerfile.kde), so the
# script needs network. Dolphin is the window a file paste is honest in — a
# text editor cannot receive a file — and the two libraries are what let the
# session decode a HEIC at all: without them Dolphin draws a generic icon and
# the Plasma wallpaper silently stays as it was. The Qt image plugin they carry
# is loaded at process start, so the install has to happen before the
# plasmashell restart further down, not after it.
#
# The file is staged in ~/Downloads and pasted into ~/Pictures, rather than
# copied and pasted in one folder, because Skrepka re-offers a local file row
# as the path it was copied from. The bytes are in the history — the row
# carries an `application/vnd.skrepka.files+cbor` bundle — but that bundle is
# what a *peer* materialises on the other side of a sync;
# `SkrepkaCore.ForeignFileGuard` passes a row this device recorded straight
# through, so the clipboard gets the original path back. Delete the staged file
# to make the folder empty on camera and the paste lands on nothing: Dolphin
# says "The file or folder /home/deck/Pictures/Sonoma.heic does not exist",
# which is correct behaviour and a terrible demo. Two folders is what a user
# does anyway.
#
# The picker's automatic paste is rehearsed rather than assumed, and on this
# box it does not happen. Off camera the whole flow is played once into a
# Dolphin window on an emptied ~/Pictures; whether the file is there afterwards
# is the answer, which beats reading pixels. If it did not arrive,
# `paste.automatic` is turned off — which is what stops Skrepka's "copied the
# entry but could not paste it" alert from appearing in the take — and
# Dolphin's own paste, Ctrl+V, is sent by hand during the real one. The same
# rehearsal then drives the wallpaper gesture — right-click, "Set as
# Wallpaper", "Desktop" — and judges it by the wallpaper setting and by a
# pixel of the desktop, falling back to `plasma-apply-wallpaperimage` for the
# take if the menu did not take. The script prints which of the two happened
# for each, and both belong in any caption written for the result.
#
# One reason the paste lands on the second, and it is the box rather than the
# window: the container offers no zwp_virtual_keyboard_manager_v1, so Skrepka
# falls back to the Remote Desktop portal, and xdg-desktop-portal-kde will not
# open a session here. Dolphin itself takes Ctrl+V — the key Skrepka
# synthesises, and the one the assisted take sends — so unlike a terminal,
# whose paste is Ctrl+Shift+V, the target is not what stands in the way.
#
# And the session renders without a GPU, so KWin's OpenGL-only effects — blur
# above all — are missing from the recording. That is a property of the box,
# not of the app; see docker/kde/session.sh.
#
# SKREPKA_DEMO_FPS overrides the capture frame rate (default 25).

set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

ASSET=skrepka-linux-x86_64.tar.gz
FPS="${SKREPKA_DEMO_FPS:-25}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${REPO}/build/kde/demo/${RUN_ID}"
RUN="/out/demo/${RUN_ID}"
OUTPUT="${REPO}/build/demo/linux.mov"

# The three files the history is made of. Generated once and kept: the two
# pictures are what an image row looks like at a glance, and the wallpaper is
# the macOS one the story is about. Nothing here regenerates them.
ASSET_DIR="${REPO}/build/demo"
WALLPAPER="${ASSET_DIR}/wallpaper/Sonoma.heic"
PICTURES=(
	"${ASSET_DIR}/history/radial-sky-blue.png"
	"${ASSET_DIR}/history/imac-purple.png"
)

# Everything the picker shows, oldest first, so the last line is its top row.
# Shared with scripts/record-demo-macos.sh — the story is one history synced
# between a Mac and a Deck, so the two halves seed the same nine entries in the
# same order, character for character, and this is not the place to improve one
# of them. The Mac seeds the first eight and copies the ninth on camera, out of
# Finder; this half seeds all nine, because the file has to be in the history
# before the picker opens.
#
# Nine is what the picker shows before it runs out of height, which is what
# keeps the operator's own clipboard out of the shot.
HISTORY=(
	$'text\tgit rebase --onto master feature~3 feature'
	$'text\tdocs/linux-sync/phase-7-linux-gui.md'
	$'image\tradial-sky-blue.png'
	$'text\tswift test --parallel'
	$'text\tShip the Linux tarball before Friday'
	$'text\t#3A86FF'
	$'image\timac-purple.png'
	$'text\thttps://github.com/psoldunov/skrepka'
	$'file\tSonoma.heic'
)

mkdir -p "${RUN_DIR}"/{input/assets,logs,shots,steps} "${REPO}/build/demo"

# Runs the script on stdin inside the session, with RUN and FPS set, keeping a
# copy of it in the run directory.
#
# The script goes in as a file rather than through `bash -s`, because the
# session's stdin cannot be trusted: ffmpeg and pacman both read from it, and a
# command that swallows two bytes of a script bash is still reading turns the
# next line into nonsense.
step() {
	local name="$1" script="${RUN_DIR}/steps/$1.sh"
	cat > "${script}"
	scripts/kde.sh env RUN="${RUN}" FPS="${FPS}" bash "${RUN}/steps/$1.sh" \
		< /dev/null 2>&1 | tee "${RUN_DIR}/logs/${name}.log"
}

# ---------------------------------------------------------------------------
# The subject
# ---------------------------------------------------------------------------

SOURCE="${SKREPKA_TARBALL:-build/deck/${ASSET}}"
if [[ ! -f "${SOURCE}" ]]; then
	echo "${SOURCE} does not exist. Build it with: scripts/build-deck.sh" >&2
	exit 1
fi
for asset in "${WALLPAPER}" "${PICTURES[@]}"; do
	if [[ ! -f "${asset}" ]]; then
		echo "${asset#"${REPO}/"} does not exist; the history cannot be seeded without it." >&2
		exit 1
	fi
done

cp "${SOURCE}" "${RUN_DIR}/input/${ASSET}"
[[ -f "${SOURCE}.sha256" ]] && cp "${SOURCE}.sha256" "${RUN_DIR}/input/${ASSET}.sha256"
cp "${WALLPAPER}" "${PICTURES[@]}" "${RUN_DIR}/input/assets/"
printf '%s\n' "${HISTORY[@]}" > "${RUN_DIR}/input/history.tsv"

echo "subject:   ${SOURCE}"
echo "history:   ${#HISTORY[@]} entries, newest $(tail -1 "${RUN_DIR}/input/history.tsv" | cut -f2)"
echo "run:       build/kde/demo/${RUN_ID}"

scripts/kde.sh up --fresh

# ---------------------------------------------------------------------------
# The scene: the window, the points a click lands on, and the gesture
# ---------------------------------------------------------------------------

cat > "${RUN_DIR}/steps/scene.sh" << 'STEP'
# Sourced by the rehearsal and the take. Everything both of them have to agree
# on lives here, because a coordinate that drifts between them is a rehearsal
# that proves nothing.
#
# The click points were measured against the geometry the KWin rule forces, and
# `open_dolphin` refuses to continue if the window came up anywhere else — they
# are only meaningful relative to it. What proves them right on the day is the
# rehearsal, which drives the same gesture off camera and reads the wallpaper
# back afterwards.

# 900x560 centred in the 1280x800 output — 190 pixels of wallpaper to the left
# and right, 120 above and below — because the wallpaper changing is the
# payoff, and it needs to be visible on all four sides of the window while it
# happens. The macOS half centres its window the same way, so the two panes of
# the GIF read as a pair.
DOLPHIN_GEOMETRY=190,120,900x560
STAGED=/home/deck/Downloads/Sonoma.heic
PASTED=/home/deck/Pictures/Sonoma.heic

ICON_X=514 ICON_Y=237       # the first file in the view, once one is there
MENU_X=640 MENU_Y=535       # "Set as Wallpaper" in Dolphin's context menu
SUBMENU_X=835 SUBMENU_Y=535 # its "Desktop"
PARK_X=1272 PARK_Y=8        # where the pointer rests between the clicks it makes

# Not the bottom-right corner, which is the obvious place and the wrong one:
# the panel's Peek at Desktop widget lives there, and a pointer left on it
# raises its tooltip over the last two seconds of the take.

POINTER_X="${PARK_X}"
POINTER_Y="${PARK_Y}"

# Moves the pointer the way a hand does, in one xdotool invocation: sixteen
# steps of a process each would be a second of stutter under emulation, and a
# pointer that teleports across the frame reads as a script rather than a user.
glide() {
	local target_x="$1" target_y="$2" steps=16 i x y
	local -a moves=()
	for ((i = 1; i <= steps; i++)); do
		x=$((POINTER_X + (target_x - POINTER_X) * i / steps))
		y=$((POINTER_Y + (target_y - POINTER_Y) * i / steps))
		moves+=(mousemove "${x}" "${y}" sleep 0.02)
	done
	xdotool "${moves[@]}"
	POINTER_X="${target_x}"
	POINTER_Y="${target_y}"
}

park() {
	xdotool mousemove "${PARK_X}" "${PARK_Y}"
	POINTER_X="${PARK_X}"
	POINTER_Y="${PARK_Y}"
}

# Puts the keyboard back on Dolphin by clicking an empty patch of its view.
# Only the rehearsal needs it, and only after Skrepka's "could not paste it"
# alert has taken focus: xdotool cannot activate a Wayland client, and a Ctrl+V
# sent to that alert goes nowhere.
focus_dolphin() {
	xdotool mousemove 950 550 sleep 0.2 click 1
	sleep 1
	park
}

# The gesture the take makes: the real global shortcut, a beat to read the
# picker, Return on the top row.
choose_top_entry() {
	xdotool key "$(cat /tmp/kde/trigger)"
	sleep 3
	xdotool key Return
	sleep 3
}

# A fresh Dolphin on an empty ~/Pictures, focused, with the pointer parked.
# The folder is emptied first so that a file in it afterwards means the paste
# put it there.
open_dolphin() {
	pkill -x dolphin || true
	sleep 1
	mkdir -p "${HOME}/Pictures"
	find "${HOME}/Pictures" -mindepth 1 -delete
	nohup dolphin "${HOME}/Pictures" > /tmp/kde/logs/dolphin.log 2>&1 &
	# Waiting for the window to be *active* rather than merely listed: the
	# shortcut and Ctrl+V go to whatever KWin considers focused, and a window
	# that has appeared but not been focused yet swallows the whole thing.
	for _ in $(seq 60); do
		skrepka-kde-windows | grep '|org.kde.dolphin|' | grep -q 'active$' && break
		sleep 0.5
	done
	sleep 1.5
	local geometry
	geometry="$(skrepka-kde-windows | grep '|org.kde.dolphin|' | head -1 | cut -d'|' -f4)"
	if [[ -z "${geometry}" ]]; then
		echo "FATAL: Dolphin did not open a window; see /tmp/kde/logs/dolphin.log" >&2
		exit 1
	fi
	if [[ "${geometry}" != "${DOLPHIN_GEOMETRY}" ]]; then
		echo "FATAL: Dolphin came up at ${geometry}, not ${DOLPHIN_GEOMETRY}. The KWin" >&2
		echo "       rule did not apply, so every click point below is aimed at the" >&2
		echo "       wrong pixel." >&2
		exit 1
	fi
	echo "dolphin: ${geometry} on ${HOME}/Pictures"
	park
	sleep 1
}

# Right-click the file, "Set as Wallpaper", "Desktop" — the gesture a user
# makes. The pauses are the submenu's, not decoration: KDE opens a submenu on
# hover rather than on click.
set_wallpaper_by_menu() {
	glide "${ICON_X}" "${ICON_Y}"
	sleep 0.3
	xdotool click 3
	sleep 0.75
	glide "${MENU_X}" "${MENU_Y}"
	sleep 0.6
	glide "${SUBMENU_X}" "${SUBMENU_Y}"
	sleep 0.3
	xdotool click 1
}

# What the desktop containment is currently told to show. Written by the menu
# action and by plasma-apply-wallpaperimage alike, and the only one of the two
# answers that is cheap to read.
wallpaper_setting() {
	kreadconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
		--group Containments --group 1 --group Wallpaper \
		--group org.kde.image --group General --key Image
}

# The patch of desktop every wallpaper check reads: 160x160 pixels of the lower
# left, which the centred window leaves clear and the panel does not reach.
WALLPAPER_PATCH=crop=160:160:10:500

# That patch of an image, averaged to one RGB triplet, so that a repaint moves
# it and dithering does not.
image_pixel() {
	ffmpeg -v error -i "$1" -vf "${WALLPAPER_PATCH},scale=1:1" \
		-f rawvideo -pix_fmt rgb24 - < /dev/null | od -An -tu1 | tr -s ' '
}

# The same, for the desktop as it is right now. The setting says what Plasma
# was asked for; this says what it drew, and the two disagree whenever the
# image cannot be decoded — which is the whole reason
# `plasma-apply-wallpaperimage` printing "Successfully set the wallpaper" is
# not evidence of anything.
desktop_pixel() {
	skrepka-kde-screenshot "$1" > /dev/null < /dev/null
	image_pixel "$1"
}

# How far apart two of those triplets are, summed over the channels. Anything
# under a handful is the same image; a wallpaper change is in the hundreds.
pixel_distance() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		split(a, x, " "); split(b, y, " ")
		for (i = 1; i <= 3; i++) { d = x[i] - y[i]; total += (d < 0 ? -d : d) }
		print total
	}'
}
STEP


# ---------------------------------------------------------------------------
# The set: a dark session, a file manager, and the app installed as a user would
# ---------------------------------------------------------------------------

step setup << 'STEP'
set -euo pipefail
source "${RUN}/steps/scene.sh"

# The image ships no file manager, and no HEIC support. Dolphin is KDE's own,
# and kimageformats is the Qt image plugin that reads the wallpaper — without
# it Dolphin draws a generic icon and the Plasma wallpaper quietly refuses the
# file. Both come from the same SteamOS repositories as the rest of this
# session, and both land before plasmashell is restarted below, because a
# running plasmashell does not pick up an image plugin installed under it.
sudo pacman -Sy --noconfirm --needed dolphin libheif kimageformats \
	> /tmp/kde/logs/pacman.log 2>&1 < /dev/null
dolphin --version 2> /dev/null | tail -1

# Dark, both halves. plasma-apply-colorscheme moves the Plasma session; the
# GTK4 picker follows because xdg-desktop-portal-kde derives
# org.freedesktop.appearance color-scheme from that scheme, and the gsettings
# value is the fallback for a GTK that reads the setting directly.
plasma-apply-colorscheme BreezeDark > /dev/null 2>&1
plasma-apply-desktoptheme breeze-dark > /dev/null 2>&1
gsettings set org.gnome.desktop.interface color-scheme prefer-dark

# The scene needs Dolphin in one place every run: the picker opens centred and
# 660 points wide, and the right-click that sets the wallpaper is aimed at a
# point in the view. A KWin rule is how a window gets a geometry here — the
# session's clients are Wayland ones, so xdotool cannot move them, and Dolphin
# would otherwise restore whatever size it last had.
# Spelled out of DOLPHIN_GEOMETRY rather than written twice: the rule and the
# check `open_dolphin` makes against it have to be the same numbers, and two
# places to edit them is one place to forget.
rule_size="${DOLPHIN_GEOMETRY##*,}"
cat > ~/.config/kwinrulesrc << RULES
[General]
count=1
rules=demo-dolphin

[demo-dolphin]
Description=the demo's Dolphin window
wmclass=org.kde.dolphin
wmclassmatch=1
wmclasscomplete=false
position=${DOLPHIN_GEOMETRY%,*}
positionrule=2
size=${rule_size/x/,}
sizerule=2
RULES
busctl --user call org.kde.KWin /KWin org.kde.KWin reconfigure > /dev/null 2>&1

# SteamOS pins System Settings and Discover to the task manager, and this image
# has neither installed, so Plasma draws each of them as the generic blank
# page. Unpinning leaves the panel with the launcher, the tray and the clock —
# which is what a Deck's panel looks like with nothing pinned, rather than a
# Deck's panel with two icons that failed to load. plasmashell reads launchers
# at startup, so it is restarted rather than reconfigured in place.
applets=~/.config/plasma-org.kde.plasma.desktop-appletsrc
tasks="$(awk '/^\[Containments\]\[2\]\[Applets\]\[/ { n = $0; sub(/.*\[/, "", n); sub(/\].*/, "", n) }
	/^plugin=org\.kde\.plasma\.icontasks$/ { print n; exit }' "${applets}")"
if [[ -n "${tasks}" ]]; then
	kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
		--group Containments --group 2 --group Applets --group "${tasks}" \
		--group Configuration --group General --key launchers ""
else
	echo "no icontasks applet in ${applets}; the panel keeps whatever it pins" >&2
fi
kquitapp6 plasmashell > /dev/null 2>&1 || true
sleep 2
nohup plasmashell > /tmp/kde/logs/plasmashell-demo.log 2>&1 &
sleep 8
echo "portal color-scheme: $(busctl --user call org.freedesktop.portal.Desktop \
	/org/freedesktop/portal/desktop org.freedesktop.portal.Settings Read ss \
	org.freedesktop.appearance color-scheme 2>&1)"

# The wallpaper the take starts from, said out loud rather than inherited.
# Three reasons it is set here rather than assumed: the rehearsal sets the
# desktop to Sonoma.heic to find out whether it can, so the take needs
# something to go back to; a fresh session's own default has no Image key to
# read, so there would be nothing to go back *to*; and a container someone
# applied a wallpaper in by hand is a container whose desktop is already the
# thing the GIF is supposed to change to. Next is Plasma's own default, which
# is what this image shows untouched — the frame does not change, it just
# becomes nameable.
#
# The patch of desktop it draws is recorded beside it. That, not the setting,
# is what the take checks itself against before the camera starts.
plasma-apply-wallpaperimage /usr/share/wallpapers/Next > /dev/null 2>&1
echo /usr/share/wallpapers/Next > /tmp/kde/wallpaper-default
sleep 5
desktop_pixel /tmp/kde/wallpaper-default.png > /tmp/kde/wallpaper-default-pixel
echo "wallpaper: /usr/share/wallpapers/Next, drawing$(cat /tmp/kde/wallpaper-default-pixel)"

mkdir -p /tmp/rel
tar -xzf "${RUN}/input/skrepka-linux-x86_64.tar.gz" -C /tmp/rel
bash /tmp/rel/*/install.sh --tarball "${RUN}/input/skrepka-linux-x86_64.tar.gz" \
	> "${RUN}/logs/install.log" 2>&1 < /dev/null

# Where the file is copied from. ~/Pictures is where it is pasted to, and the
# take empties that; a file row pastes as the path it was copied from, so the
# source has to survive the take.
mkdir -p ~/Downloads ~/Pictures
cp "${RUN}/input/assets/Sonoma.heic" ~/Downloads/
echo "staged: $(du -h ~/Downloads/Sonoma.heic | cut -f1) at ~/Downloads/Sonoma.heic"

# No systemd user manager in the container, so the unit install.sh wrote cannot
# run. The daemon and the app are started the way the unit and the autostart
# entry would, in that order, so each one's stderr is kept rather than landing
# in dbus-daemon's.
pkill -x skrepka-gui || true
pkill -x skrepkad || true
for _ in $(seq 40); do
	pgrep -x 'skrepka-gui|skrepkad' > /dev/null || break
	sleep 0.25
done
nohup ~/.local/bin/skrepkad > "${RUN}/logs/skrepkad.log" 2>&1 &
for _ in $(seq 40); do
	busctl --user status dev.soldunov.Skrepka > /dev/null 2>&1 && break
	sleep 0.25
done
nohup ~/.local/bin/skrepka-gui --background > "${RUN}/logs/skrepka-gui.log" 2>&1 &
STEP

# ---------------------------------------------------------------------------
# The shortcut: let KDE ask for it off camera
# ---------------------------------------------------------------------------
#
# Binding show-picker makes KDE put a "Global Shortcuts Requested" dialog on
# screen, which a user accepts once. Accepting it here, before anything is
# recorded, is the only reason this is a step of its own.

step shortcut << 'STEP'
set -uo pipefail
rc=~/.config/kglobalshortcutsrc
trigger() {
	awk -F'[=,]' '/^\[dev\.soldunov\.Skrepka\.App\]/ {s=1; next} /^\[/ {s=0}
		s && $1 == "show-picker" {print $2; exit}' "${rc}" 2> /dev/null
}
for _ in $(seq 40); do
	[[ -n "$(trigger)" ]] && break
	if skrepka-kde-windows | grep -q '^Global Shortcuts Requested|'; then
		DISPLAY="${SKREPKA_KDE_OUTER_DISPLAY}" xdotool key Return
		sleep 2
	fi
	sleep 0.5
done
keys="$(trigger)"
if [[ -z "${keys}" ]]; then
	echo "FATAL: show-picker was never bound; the shortcut cannot be pressed for real" >&2
	exit 1
fi
# KDE writes "Meta+Shift+V"; xdotool wants "super+shift+v".
sed -e 's/Meta/super/g; s/Ctrl/ctrl/g; s/Alt/alt/g; s/Shift/shift/g' <<< "${keys}" \
	| awk -F+ '{ $NF = tolower($NF); print }' OFS=+ > /tmp/kde/trigger
echo "shortcut: ${keys} (xdotool: $(cat /tmp/kde/trigger))"
STEP
# ---------------------------------------------------------------------------
# The rehearsal: does the picker reach the folder, and does the menu reach the
# wallpaper?
# ---------------------------------------------------------------------------

step rehearse << 'STEP'
set -euo pipefail
source /tmp/kde/env
source "${RUN}/steps/scene.sh"
export DISPLAY="${SKREPKA_KDE_OUTER_DISPLAY}"

open_dolphin

# One entry, because that is all either question needs: the file has to be the
# picker's top row, and nothing below it is read. The history the take films is
# seeded fresh afterwards, which is also what keeps the rows' "seconds ago"
# honest.
~/.local/bin/skrepka clear --all < /dev/null > /dev/null
wl-copy --clear
sleep 1
printf 'file://%s\r\n' "${STAGED}" | wl-copy --type text/uri-list
sleep 2
# The last thing copied is also what is left on the clipboard, which would let
# a Ctrl+V land the right file whether or not the picker did anything.
# Clearing the selection takes that away: after this, only choosing the entry
# in the picker can put it back.
wl-copy --clear
sleep 1

skrepka-kde-screenshot "${RUN}/shots/rehearsal-before.png" > /dev/null < /dev/null
choose_top_entry

if [[ -f "${PASTED}" ]]; then
	echo automatic > /tmp/kde/paste-mode
	echo "PASTE automatic: the picker put the file in the folder by itself"
else
	echo assisted > /tmp/kde/paste-mode
	echo "PASTE assisted: the file stopped at the clipboard; the take sends Ctrl+V"
	skrepka-kde-screenshot "${RUN}/shots/rehearsal-alert.png" > /dev/null < /dev/null
	# Skrepka says so on screen when it tried and failed. Taking the attempt
	# away takes the alert away with it, and leaves the picker doing what it
	# does on a desktop with no input-injection service: copy, and let the
	# user paste.
	~/.local/bin/skrepka config set paste.automatic off < /dev/null
	# That alert is also holding the keyboard, which is why the whole thing is
	# played a second time rather than finished with a Ctrl+V here: closing it
	# and clicking Dolphin gets focus back, and what is rehearsed after that is
	# the take's own sequence — picker, Return, Ctrl+V, with the attempted
	# paste already turned off — rather than a near miss of it.
	xdotool key Escape
	sleep 1
	focus_dolphin
	wl-copy --clear
	sleep 1
	choose_top_entry
	sleep 0.6
	xdotool key ctrl+v
	sleep 3
fi
if [[ ! -f "${PASTED}" ]]; then
	echo "FATAL: neither the picker nor Ctrl+V put the file in ${PASTED}, so the" >&2
	echo "       scene has nothing to film. The clipboard holds:" >&2
	wl-paste --list-types 2> /dev/null | sed 's/^/         /' >&2
	exit 1
fi
skrepka-kde-screenshot "${RUN}/shots/rehearsal-pasted.png" > /dev/null < /dev/null

# And now the other half of the scene, judged the same way. The setting alone
# is not enough: plasma-apply-wallpaperimage and the menu action both report
# success for an image plasmashell then fails to decode, and the only thing
# that knows the difference is the desktop itself.
before="$(desktop_pixel "${RUN}/shots/rehearsal-wallpaper-before.png")"
set_wallpaper_by_menu
sleep 4
after="$(desktop_pixel "${RUN}/shots/rehearsal-wallpaper-after.png")"
setting="$(wallpaper_setting)"
echo "  wallpaper setting: ${setting:-<unset>}"
echo "  desktop corner:    ${before} -> ${after}"
if [[ "${setting}" == *Pictures/Sonoma.heic && "${before}" != "${after}" ]]; then
	echo menu > /tmp/kde/wallpaper-mode
	echo "WALLPAPER menu: the Dolphin service menu set the desktop, and it repainted"
else
	echo command > /tmp/kde/wallpaper-mode
	echo "WALLPAPER command: the menu did not take; the take runs plasma-apply-wallpaperimage"
fi

# Whatever the rehearsal left behind — an open menu, a pasted file, a changed
# desktop — goes now; the take opens its own Dolphin on its own empty folder.
xdotool key Escape
sleep 0.5
xdotool key Escape
sleep 0.5
pkill -x dolphin || true
find ~/Pictures -mindepth 1 -delete
plasma-apply-wallpaperimage "$(cat /tmp/kde/wallpaper-default)" > /dev/null 2>&1
sleep 3
wl-copy --clear
sleep 1
STEP

# ---------------------------------------------------------------------------
# The history
# ---------------------------------------------------------------------------

step history << 'STEP'
set -euo pipefail
source "${RUN}/steps/scene.sh"

~/.local/bin/skrepka clear --all < /dev/null > /dev/null
wl-copy --clear
sleep 1

# Each kind goes on the clipboard the way the thing it stands for does: text as
# text, a picture as image/png, and the wallpaper as a text/uri-list naming the
# file it was copied from — which is what makes it a file row rather than a
# picture, and what makes choosing it paste a file into a folder.
while IFS=$'\t' read -r kind value; do
	case "${kind}" in
		text) printf '%s' "${value}" | wl-copy ;;
		image) wl-copy --type image/png < "${RUN}/input/assets/${value}" ;;
		file) printf 'file://%s\r\n' "${STAGED}" | wl-copy --type text/uri-list ;;
		*)
			echo "FATAL: ${kind} is not a kind of history entry this script seeds" >&2
			exit 1
			;;
	esac
	sleep 1.5
done < "${RUN}/input/history.tsv"
sleep 1

# And then check that the daemon kept the newest one as a file. A refused or
# mis-decoded entry looks like nothing at all from out here — the picker would
# simply open with the row below it on top, and the take would paste that — so
# this is the gate between seeding the history and filming it. Read from the
# daemon's own document rather than from the clipboard, because asking for an
# entry back would record it again and leave the take with two identical top
# rows.
top="$(~/.local/bin/skrepka list --limit 1 --json < /dev/null)"
kind="$(grep -o '"kind":"[^"]*"' <<< "${top}" | head -1 | cut -d'"' -f4)"
preview="$(grep -o '"preview":"[^"]*"' <<< "${top}" | head -1 | cut -d'"' -f4)"
if [[ "${kind}" != file || "${preview}" != Sonoma.heic ]]; then
	echo "FATAL: the newest history entry is a ${kind:-nothing} called ${preview:-nothing}," >&2
	echo "       not the file the scene pastes. The picker would open on the wrong row." >&2
	exit 1
fi
echo "top row: ${preview}, a ${kind} entry"
~/.local/bin/skrepka list --limit 9 < /dev/null | sed 's/^/  /'

# The last entry seeded is also what is left on the clipboard, which would let
# a Ctrl+V land the right file whether or not the picker did anything.
# Clearing the selection takes that away: after this, only choosing the entry
# in the picker can put it back. The history keeps all nine — an empty
# selection is not an entry.
wl-copy --clear
sleep 1
~/.local/bin/skrepka config > "${RUN}/logs/config.txt" 2>&1 < /dev/null || true
STEP

# ---------------------------------------------------------------------------
# The take
# ---------------------------------------------------------------------------
#
# x11grab writes to the container's own disk rather than through the /out bind
# mount: under emulation the mount is slow enough to drop frames at 1280x800.
# It is transcoded to /out afterwards, when nothing is on a clock.

step take << 'STEP'
set -euo pipefail
source /tmp/kde/env
source "${RUN}/steps/scene.sh"
export DISPLAY="${SKREPKA_KDE_OUTER_DISPLAY}"

open_dolphin
paste_mode="$(cat /tmp/kde/paste-mode)"
wallpaper_mode="$(cat /tmp/kde/wallpaper-mode)"

# The whole point of the take is the desktop changing inside it, so the first
# frame has to be the stock wallpaper — not whatever the rehearsal, or someone
# working in this container by hand, left behind. Asking for it back is not
# enough to know it is back: plasmashell decodes on its own schedule and says
# nothing either way, so the check is the patch of desktop it is drawing,
# against the one recorded while the stock wallpaper was up.
stock="$(cat /tmp/kde/wallpaper-default-pixel)"
plasma-apply-wallpaperimage "$(cat /tmp/kde/wallpaper-default)" > /dev/null 2>&1
for _ in $(seq 20); do
	drawn="$(desktop_pixel /tmp/kde/take-start.png)"
	(($(pixel_distance "${drawn}" "${stock}") <= 3)) && break
	sleep 1
done
if (($(pixel_distance "${drawn}" "${stock}") > 3)); then
	echo "FATAL: the desktop is drawing${drawn}, and the stock wallpaper draws${stock}." >&2
	echo "       Filming now would open on a wallpaper that is already the one the" >&2
	echo "       scene is supposed to change to." >&2
	exit 1
fi
cp /tmp/kde/take-start.png "${RUN}/shots/take-start.png"
echo "opening on: /usr/share/wallpapers/Next, drawing${drawn}"

# -draw_mouse 1, unlike every screenshot this session takes: the pointer is
# part of the scene here. Skrepka's own half of it is all keyboard, but setting
# the wallpaper is a right-click and two menu items, and a menu that opens and
# highlights itself with no pointer in the frame reads as a glitch rather than
# as somebody doing something.
nohup ffmpeg -hide_banner -loglevel error -f x11grab -draw_mouse 1 \
	-framerate "${FPS}" -video_size "${SKREPKA_KDE_WIDTH}x${SKREPKA_KDE_HEIGHT}" \
	-i "${SKREPKA_KDE_OUTER_DISPLAY}" \
	-c:v libx264 -preset ultrafast -crf 16 -y /tmp/kde/take.mkv \
	> /tmp/kde/logs/ffmpeg.log 2>&1 &
recorder=$!

sleep 0.9
xdotool key "$(cat /tmp/kde/trigger)"
sleep 2.7
xdotool key Return
if [[ "${paste_mode}" == assisted ]]; then
	sleep 0.5
	# Dolphin's paste, which is Ctrl+V — the same key Skrepka synthesises when
	# it can, and the one a user presses after choosing an entry on a desktop
	# where Skrepka can only copy.
	xdotool key ctrl+v
	sleep 1.2
else
	sleep 1.7
fi

if [[ "${wallpaper_mode}" == menu ]]; then
	set_wallpaper_by_menu
else
	# Off camera, because there is no gesture to film: the command is the
	# fallback for a session whose service menu the rehearsal could not drive.
	plasma-apply-wallpaperimage "${PASTED}" > /dev/null 2>&1 &
	sleep 1.5
fi
sleep 2.2
glide "${PARK_X}" "${PARK_Y}"
sleep 0.8

kill -INT "${recorder}"
wait "${recorder}" 2> /dev/null || true
skrepka-kde-screenshot "${RUN}/shots/take-end.png" > /dev/null < /dev/null
echo "pasted:     $(ls ~/Pictures)"
echo "wallpaper:  $(wallpaper_setting)"
echo "paste mode: ${paste_mode}, wallpaper mode: ${wallpaper_mode}"
echo "raw take:   $(du -h /tmp/kde/take.mkv | cut -f1)"
STEP

# ---------------------------------------------------------------------------
# Out
# ---------------------------------------------------------------------------

step encode << 'STEP'
set -euo pipefail
source "${RUN}/steps/scene.sh"

ffmpeg -hide_banner -loglevel error -i /tmp/kde/take.mkv \
	-c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -movflags +faststart \
	-y "${RUN}/linux.mov" < /dev/null
ffprobe -v error -select_streams v:0 \
	-show_entries stream=width,height,avg_frame_rate,nb_frames \
	-show_entries format=duration -of default=noprint_wrappers=1 \
	"${RUN}/linux.mov" < /dev/null

# And then read the wallpaper out of the file that is being shipped, rather
# than out of the session it came from. The first frame and the last frame are
# the two the GIF loops between, so if the desktop did not visibly change
# between them the take is not the take, whatever the session reported while it
# was being made.
ffmpeg -v error -i "${RUN}/linux.mov" -frames:v 1 \
	-y "${RUN}/shots/frame-first.png" < /dev/null
ffmpeg -v error -sseof -0.3 -i "${RUN}/linux.mov" -update 1 \
	-y "${RUN}/shots/frame-last.png" < /dev/null
first="$(image_pixel "${RUN}/shots/frame-first.png")"
last="$(image_pixel "${RUN}/shots/frame-last.png")"
moved="$(pixel_distance "${first}" "${last}")"
echo "first frame:${first}"
echo "last frame: ${last}"
echo "wallpaper moved by ${moved} across the take"
if ((moved < 40)); then
	echo "FATAL: the desktop looks the same in the first frame and the last one, so" >&2
	echo "       the wallpaper did not change on camera. build/kde/demo/*/shots/" >&2
	echo "       frame-first.png and frame-last.png are the two frames." >&2
	exit 1
fi
STEP

cp "${RUN_DIR}/linux.mov" "${OUTPUT}"
echo
grep -h '^PASTE' "${RUN_DIR}/logs/rehearse.log"
grep -h '^WALLPAPER' "${RUN_DIR}/logs/rehearse.log"
echo "output:   build/demo/linux.mov"
echo "evidence: build/kde/demo/${RUN_ID}/"
