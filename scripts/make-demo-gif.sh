#!/usr/bin/env bash
#
# Composes the two halves of the README demo into a GIF, in either of the two
# layouts the README might want.
#
#   scripts/make-demo-gif.sh               side by side  -> docs/images/demo.gif
#   scripts/make-demo-gif.sh --sequential  one, then the other
#                                          -> docs/images/demo-sequential.gif
#   scripts/make-demo-gif.sh --both        both files
#
# Side by side is the Mac on the left and the Linux desktop on the right, each
# captioned with the OS it is, both playing in one frame: the Linux pane holds
# its first frame until LINUX_ENTRY seconds in, so the copy and the Mac picker
# read first and the Linux picker answers them while the Mac panel is still on
# screen. Sequential is the full-width Mac take and then the full-width Linux
# take, with nothing written over either — more legible, and it runs as long as
# both halves put together.
#
# Neither layout speeds a half up or cuts into one. The only edit is when each
# starts.
#
# It needs both takes to exist already:
#
#   build/demo/macos.mov   scripts/record-demo-macos.sh   1280x800 points at 2x
#   build/demo/linux.mov   scripts/record-demo-linux.sh   1280x800 native
#
# ffmpeg here has no drawtext (no libfreetype), so the side-by-side captions are
# rendered by ImageMagick into transparent PNGs and overlaid.
#
# Tuning, in rough order of what to reach for if a file is too big: FPS, the
# widths, then COLOURS. GitHub serves a README image at about 900 points wide,
# so width beyond that is spent on Retina sharpness rather than on legibility.

set -euo pipefail

cd "$(dirname "$0")/.."

MAC_IN="build/demo/macos.mov"
LINUX_IN="build/demo/linux.mov"
SIDE_BY_SIDE_OUT="docs/images/demo.gif"
SEQUENTIAL_OUT="docs/images/demo-sequential.gif"
WORK="build/demo/compose"

PANE_W=640
PANE_H=400
GUTTER=14
MARGIN=14
LABEL_H=26
LABEL_SIZE=15
# The sequential layout gives one desktop the whole width, so it can be smaller
# on paper than the two panes together and still read larger than either.
SEQUENTIAL_W=960
SEQUENTIAL_H=600
FPS=15
COLOURS=192
# Seconds into the composed clip at which the Linux half starts playing.
LINUX_ENTRY="${LINUX_ENTRY:-4.0}"
# Seconds of stillness at the end, so the loop has somewhere to land.
TAIL=1.0

BACKDROP="#0d0d10"
LABEL_COLOUR="#9a9aa6"
FONT="/System/Library/Fonts/SFNS.ttf"

die() {
	echo "$1" >&2
	exit 1
}

LAYOUT="${1:---side-by-side}"
case "${LAYOUT}" in
	--side-by-side | --sequential | --both) ;;
	*) die "usage: scripts/make-demo-gif.sh [--side-by-side|--sequential|--both]" ;;
esac

for input in "${MAC_IN}" "${LINUX_IN}"; do
	[[ -f "${input}" ]] || die "no ${input}: film it first (scripts/record-demo-macos.sh, scripts/record-demo-linux.sh)"
done
command -v magick > /dev/null || die "ImageMagick is needed for the captions: brew install imagemagick"

mkdir -p "${WORK}" "$(dirname "${SIDE_BY_SIDE_OUT}")"

duration() {
	ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"
}

MAC_D="$(duration "${MAC_IN}")"
LINUX_D="$(duration "${LINUX_IN}")"

# ---------------------------------------------------------------------------
# A GIF, from a filter graph
# ---------------------------------------------------------------------------

# Three passes rather than one graph. Composing, reading the palette and
# applying it in a single filter_complex means ffmpeg holds every composed
# frame in memory until palettegen has seen the last one, and on a clip this
# size the kernel kills it; lossless FFV1 in between costs a file and no
# quality.
#
# The palette is read from the whole take rather than from one frame: a palette
# built from frame one would have no idea the picker is about to open.
render() {
	local out="$1" total="$2" filter="$3"
	shift 3
	local composed="${WORK}/composed.mkv" palette="${WORK}/palette.png"

	ffmpeg -hide_banner -loglevel warning -y \
		-i "${MAC_IN}" -i "${LINUX_IN}" "$@" \
		-filter_complex "${filter}" \
		-c:v ffv1 -t "${total}" "${composed}"

	ffmpeg -hide_banner -loglevel warning -y -i "${composed}" \
		-vf "palettegen=max_colors=${COLOURS}:stats_mode=diff" "${palette}"

	ffmpeg -hide_banner -loglevel warning -y -i "${composed}" -i "${palette}" \
		-lavfi "paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
		-loop 0 "${out}"

	echo "${out} — $(du -h "${out}" | cut -f1), $(ffprobe -v error \
		-show_entries stream=width,height -of csv=p=0:s=x "${out}" | head -1) at ${FPS} fps, ${total}s"
}

# ---------------------------------------------------------------------------
# Side by side
# ---------------------------------------------------------------------------

side_by_side() {
	# No -size on the captions: with one, ImageMagick scales the text to fill
	# the box rather than honouring the point size, and a caption meant to sit
	# quietly above its pane comes out as a headline.
	local caption_args=(-background none -fill "${LABEL_COLOUR}" -font "${FONT}" -pointsize "${LABEL_SIZE}")
	magick "${caption_args[@]}" "label:macOS 26" "${WORK}/mac-label.png"
	magick "${caption_args[@]}" "label:SteamOS 3.8 · KDE Plasma 6" "${WORK}/linux-label.png"

	local total canvas_w canvas_h linux_x pane_y label_y
	total="$(awk -v a="${MAC_D}" -v b="${LINUX_ENTRY}" -v c="${LINUX_D}" -v t="${TAIL}" \
		'BEGIN { end = (a > b + c) ? a : b + c; printf "%.2f", end + t }')"
	canvas_w=$((MARGIN * 2 + PANE_W * 2 + GUTTER))
	canvas_h=$((MARGIN * 2 + LABEL_H + PANE_H))
	linux_x=$((MARGIN + PANE_W + GUTTER))
	pane_y=$((MARGIN + LABEL_H))
	label_y=$((MARGIN + 2))

	echo "side by side: macOS ${MAC_D}s, Linux ${LINUX_D}s entering at ${LINUX_ENTRY}s, composed ${total}s"

	render "${SIDE_BY_SIDE_OUT}" "${total}" "
color=c=${BACKDROP}:s=${canvas_w}x${canvas_h}:d=${total}:r=${FPS}[bg];
[0:v]scale=${PANE_W}:${PANE_H}:flags=lanczos,fps=${FPS},
     tpad=stop_duration=${total}:stop_mode=clone,trim=0:${total},setpts=PTS-STARTPTS[mac];
[1:v]scale=${PANE_W}:${PANE_H}:flags=lanczos,fps=${FPS},
     tpad=start_duration=${LINUX_ENTRY}:start_mode=clone:stop_duration=${total}:stop_mode=clone,
     trim=0:${total},setpts=PTS-STARTPTS[linux];
[bg][mac]overlay=${MARGIN}:${pane_y}:shortest=1[a];
[a][linux]overlay=${linux_x}:${pane_y}[b];
[b][2:v]overlay=${MARGIN}:${label_y}[c];
[c][3:v]overlay=${linux_x}:${label_y}
" -loop 1 -t "${total}" -i "${WORK}/mac-label.png" \
		-loop 1 -t "${total}" -i "${WORK}/linux-label.png"
}

# ---------------------------------------------------------------------------
# One, then the other
# ---------------------------------------------------------------------------

sequential() {
	local total
	total="$(awk -v a="${MAC_D}" -v b="${LINUX_D}" -v t="${TAIL}" 'BEGIN { printf "%.2f", a + b + t }')"

	echo "sequential: macOS ${MAC_D}s then Linux ${LINUX_D}s, composed ${total}s"

	# concat wants both inputs at one size, one frame rate and one aspect, which
	# is what the scale/fps/setsar pairs are for rather than for looks.
	render "${SEQUENTIAL_OUT}" "${total}" "
[0:v]scale=${SEQUENTIAL_W}:${SEQUENTIAL_H}:flags=lanczos,fps=${FPS},setsar=1,setpts=PTS-STARTPTS[mac];
[1:v]scale=${SEQUENTIAL_W}:${SEQUENTIAL_H}:flags=lanczos,fps=${FPS},setsar=1,setpts=PTS-STARTPTS[linux];
[mac][linux]concat=n=2:v=1:a=0,tpad=stop_duration=${TAIL}:stop_mode=clone
"
}

[[ "${LAYOUT}" == "--sequential" ]] || side_by_side
[[ "${LAYOUT}" == "--side-by-side" ]] || sequential
