#!/usr/bin/env bash
#
# Saves a PNG of the whole headless Plasma session.
#
#   skrepka-kde-screenshot /tmp/kde/shots/desktop.png
#
# Reads the Xvfb display KWin's X11-windowed backend draws into, with ffmpeg's
# x11grab — not spectacle or org.kde.KWin.ScreenShot2, neither of which exists
# while KWin composites with QPainter (see skrepka-kde-session). What it
# captures is exactly KWin's composited output, the cursor included, because
# KWin draws the cursor itself on this backend.

set -euo pipefail

if [[ $# -ne 1 ]]; then
	echo "usage: skrepka-kde-screenshot <file.png>" >&2
	exit 64
fi

# shellcheck source=/dev/null
source /tmp/kde/env
mkdir -p "$(dirname "$1")"
ffmpeg -hide_banner -loglevel error -f x11grab \
	-video_size "${SKREPKA_KDE_WIDTH}x${SKREPKA_KDE_HEIGHT}" \
	-i "${SKREPKA_KDE_OUTER_DISPLAY}" -frames:v 1 -y "$1"
echo "$1"
