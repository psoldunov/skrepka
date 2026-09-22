#!/usr/bin/env bash
#
# Films Scene 1 of the README demo GIF — a wallpaper copied out of Finder, and
# the picker opened over it — as build/demo/macos.mov, and leaves behind the
# assets Scene 2 needs so both halves show one history rather than two that
# merely look alike.
#
#   scripts/record-demo-macos.sh              stage assets, seed, film
#   scripts/record-demo-macos.sh --no-seed    film against the history as it is
#
# Output:
#
#   build/demo/macos.mov              the take, 1280x800 points at 2x
#   build/demo/wallpaper/<file>       the wallpaper this copies, for Scene 2
#   build/demo/history/*.png          the two image rows, for Scene 2
#
# The frame is 1280x800 points of the main display, centred on where the picker
# opens — the same frame docs/images/picker.png was shot in, so this half and
# the Linux half (scripts/record-demo-linux.sh, 1280x800 native) compose side by
# side without either being rescaled differently. The Finder window is smaller
# than that frame on purpose, so the desktop shows around it: **whatever
# wallpaper is on the desktop behind that window is in the recording**, which
# is the one thing in a take that cannot be reviewed away afterwards. Check the
# first frame before publishing anything made with this.
#
# What it needs, and refuses to start without:
#
#   - Skrepka running. Launch it the way scripts/run.sh does; a binary started
#     from a shell inherits the terminal's TCC grants instead of its own.
#   - Accessibility permission for whatever runs this script, because the take
#     is driven with synthetic key presses. Without it macOS answers
#     "osascript is not allowed to send keystrokes" and nothing is filmed.
#   - Screen Recording permission for the same process, for screencapture -v.
#
# The history it films is seeded here: eight clips, oldest first, plus the
# wallpaper copied on camera. The panel is clamped to
# PickerPlacement.maximumHeight, so seeding that many is what keeps every row in
# frame ours and the operator's own clipboard out of the shot. Text rows are
# seeded with pbcopy and the two image rows with AppleScript, so they are
# attributed to whatever app owns the pasteboard rather than to a real one; only
# the top row, copied from Finder during the take, carries a true attribution.
#
# Why this wallpaper and not the one on the screen: macOS 26's own default,
# Tahoe Day, is not a file anyone can copy — it is a 170 MB .mov inside the
# hidden /System/Library/Desktop Pictures/.wallpapers/. Sonoma.heic sits in the
# same folder, in plain view, and is what a person browsing wallpapers would
# actually reach for.

set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="build/demo"
OUT="${OUT_DIR}/macos.mov"
WALLPAPERS="/System/Library/Desktop Pictures"
# The file copied on camera, and the one Scene 2 pastes and applies.
WALLPAPER="Sonoma.heic"
# The two wallpapers that become image rows. Converted to PNG because that is
# what a pasteboard image and a wl-copy image both want, and because the Linux
# half cannot read a HEIC without the Qt plugin that Scene 2 installs for the
# wallpaper itself.
declare -a IMAGE_ROWS=(
	"Radial Sky Blue.heic:radial-sky-blue.png"
	"iMac Purple.heic:imac-purple.png"
)

# The history, oldest first. `text:` rows go through pbcopy; `image:` rows name
# a PNG in build/demo/history. Shared with scripts/record-demo-linux.sh — the
# two halves are one synced history, so a change here wants the same change
# there, in the same order.
declare -a SEEDS=(
	"text:git rebase --onto master feature~3 feature"
	"text:docs/linux-sync/phase-7-linux-gui.md"
	"image:radial-sky-blue.png"
	"text:swift test --parallel"
	"text:Ship the Linux tarball before Friday"
	"text:#3A86FF"
	"image:imac-purple.png"
	"text:https://github.com/psoldunov/skrepka"
)

die() {
	echo "$1" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

[[ "$(uname -s)" == Darwin ]] || die "this films macOS; run scripts/record-demo-linux.sh for the other half"
pgrep -x Skrepka > /dev/null || die "Skrepka is not running: open it, then run this again"
[[ -f "${WALLPAPERS}/${WALLPAPER}" ]] || die "no ${WALLPAPERS}/${WALLPAPER} on this Mac"

# A key press that does nothing, purely to find out whether this process may
# send one at all. Escape with no panel open is the most harmless key there is.
if ! osascript -e 'tell application "System Events" to key code 53' 2> /dev/null; then
	die "keystrokes are refused: grant Accessibility to whatever runs this script
(System Settings > Privacy & Security > Accessibility), then run it again"
fi

mkdir -p "${OUT_DIR}/history" "${OUT_DIR}/wallpaper"

# ---------------------------------------------------------------------------
# The assets Scene 2 reads
# ---------------------------------------------------------------------------

cp -f "${WALLPAPERS}/${WALLPAPER}" "${OUT_DIR}/wallpaper/${WALLPAPER}"
for row in "${IMAGE_ROWS[@]}"; do
	source_name="${row%%:*}"
	png="${OUT_DIR}/history/${row##*:}"
	[[ -f "${png}" ]] && continue
	sips -s format png --resampleWidth 1400 "${WALLPAPERS}/${source_name}" --out "${png}" > /dev/null
done

# ---------------------------------------------------------------------------
# The frame
# ---------------------------------------------------------------------------

# Where the frame goes is the picker's own arithmetic, read back from the main
# display rather than guessed: Sources/Skrepka/Picker/PickerPlacement.swift
# centres a 660-point panel horizontally and pins its top edge 18% of the way
# down the visible screen. The frame is centred on that panel. AppleScript
# cannot answer this — `bounds of window of desktop` returns the union of every
# display, which on a two-display Mac is not the main one.
FRAME_W=1280
FRAME_H=800
PANEL_H=540 # PickerPlacement.maximumHeight: this history is longer than that

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
read -r FRAME_X FRAME_Y <<< "$(xcrun swift - "${FRAME_W}" "${FRAME_H}" "${PANEL_H}" << 'SWIFT'
import AppKit

let arguments = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard arguments.count == 3, let screen = NSScreen.main else {
    FileHandle.standardError.write(Data("no main display\n".utf8))
    exit(1)
}
let (frameWidth, frameHeight, panelHeight) = (arguments[0], arguments[1], arguments[2])
let full = screen.frame
let visible = screen.visibleFrame
// Both rects are bottom-left origin; screencapture -R is top-left.
let menuBarHeight = full.maxY - visible.maxY
let panelTop = menuBarHeight + visible.height * 0.18
print(
    Int(((full.width - frameWidth) / 2).rounded()),
    Int((panelTop - (frameHeight - panelHeight) / 2).rounded())
)
SWIFT
)"
[[ -n "${FRAME_X}" && -n "${FRAME_Y}" ]] || die "could not work out where the picker opens"

# Centred in the frame and smaller than it, so the picker opens over the middle
# of the window and the desktop shows around all four sides. Scene 2 centres
# its Dolphin window the same way, so the two panes of the GIF read as a pair.
WINDOW_W=1040
WINDOW_H=540
WINDOW_X=$((FRAME_X + (FRAME_W - WINDOW_W) / 2))
WINDOW_Y=$((FRAME_Y + (FRAME_H - WINDOW_H) / 2))

# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------

if [[ "${1:-}" != "--no-seed" ]]; then
	echo "seeding ${#SEEDS[@]} clips…"
	for seed in "${SEEDS[@]}"; do
		case "${seed}" in
			text:*)
				printf '%s' "${seed#text:}" | pbcopy
				;;
			image:*)
				png="$(cd "${OUT_DIR}/history" && pwd)/${seed#image:}"
				[[ -f "${png}" ]] || die "no ${png} to seed an image row from"
				osascript -e "set the clipboard to (read (POSIX file \"${png}\") as «class PNGf»)" > /dev/null
				;;
			*) die "seed neither text: nor image: — ${seed}" ;;
		esac
		sleep 1.4
	done
fi

# ---------------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------------

# Finder's other windows are closed for the take and opened again afterwards:
# one left behind shows through at the edge of the frame, and its toolbar and
# title say where the operator keeps their files. Their folders come back, in
# the order they were in; their exact positions do not, which is the price of
# not filming them.
PRIOR_WINDOWS="$(osascript << 'EOF'
tell application "Finder"
	set paths to ""
	repeat with w in (every Finder window)
		try
			set paths to paths & (POSIX path of (target of w as alias)) & linefeed
		end try
	end repeat
	close every Finder window
	return paths
end tell
EOF
)"

reopen_finder_windows() {
	[[ -n "${PRIOR_WINDOWS}" ]] || return 0
	while IFS= read -r folder; do
		[[ -n "${folder}" ]] || continue
		osascript -e "tell application \"Finder\" to open (POSIX file \"${folder}\" as alias)" > /dev/null 2>&1 || true
	done <<< "${PRIOR_WINDOWS}"
}
trap reopen_finder_windows EXIT

# A window of this script's own, in icon view so the wallpapers are pictures
# rather than file names, and with the sidebar closed — a sidebar carries the
# operator's own favourites, and those are not for a README.
osascript > /dev/null << EOF
tell application "Finder"
	activate
	set demoWindow to make new Finder window
	set target of demoWindow to (POSIX file "${WALLPAPERS}") as alias
	set current view of demoWindow to icon view
	set toolbar visible of demoWindow to true
	set sidebar width of demoWindow to 0
	set bounds of demoWindow to {${WINDOW_X}, ${WINDOW_Y}, $((WINDOW_X + WINDOW_W)), $((WINDOW_Y + WINDOW_H))}
end tell
EOF

sleep 1.5

# The pointer is in the recording whether or not anything is clicked, and it
# also decides which display the picker opens on
# (PickerPlacement.screenUnderPointer), so it is parked just outside the frame
# on the same display rather than moved to another one.
xcrun swift - "$((FRAME_X - 40))" "$((FRAME_Y + FRAME_H / 2))" > /dev/null << 'SWIFT'
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard arguments.count == 2 else { exit(1) }
CGWarpMouseCursorPosition(CGPoint(x: arguments[0], y: arguments[1]))
SWIFT

sleep 1

# ---------------------------------------------------------------------------
# The take
# ---------------------------------------------------------------------------
#
# 0.0  still, a folder of wallpapers
# 2.0  the file is selected, and Finder scrolls to it
# 3.4  cmd+C copies it
# 4.6  cmd+shift+V opens the picker, the file on top with its thumbnail
# 10.0 end, with the picker still open
#
# The take ends on the open picker on purpose. In the composed GIF this half
# holds its last frame while the Linux half plays, so an open panel there means
# both machines show the same history at the same time — which is the thing the
# GIF is about. Escape comes after the camera stops.
#
# screencapture -V films for a fixed number of seconds rather than until it is
# signalled, so the beats above are wall-clock offsets into that window.

DURATION=10
# screencapture will not write over a file that is already there; it answers
# "Failed to save to final location" and films nothing.
rm -f "${OUT}"
screencapture -x -v -V "${DURATION}" -R "${FRAME_X},${FRAME_Y},${FRAME_W},${FRAME_H}" "${OUT}" &
CAPTURE=$!

key() { osascript -e "tell application \"System Events\" to key code $1 ${2:-}" > /dev/null; }

sleep 2
# Selected through Finder rather than clicked: a click needs the pointer in the
# frame, and where the icon lands depends on the window's scroll position.
osascript > /dev/null << EOF
tell application "Finder"
	set target of front window to (POSIX file "${WALLPAPERS}") as alias
	select file "${WALLPAPER}" of folder ((POSIX file "${WALLPAPERS}") as alias)
end tell
EOF
sleep 1.4
key 8 "using {command down}" # cmd+C
sleep 1.2
key 9 "using {command down, shift down}" # cmd+shift+V, the picker
wait "${CAPTURE}"
key 53 # esc, off camera

osascript -e 'tell application "Finder" to close front window' > /dev/null 2>&1 || true

echo "${OUT} — copied ${WALLPAPER}; Scene 2 reads ${OUT_DIR}/wallpaper and ${OUT_DIR}/history"
ffprobe -v error -show_entries stream=width,height,r_frame_rate,duration -of default=noprint_wrappers=1 "${OUT}" || true
