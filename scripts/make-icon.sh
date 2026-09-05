#!/usr/bin/env bash
#
# Regenerates Sources/Skrepka/Resources/AppIcon.icns from scripts/make-icon.swift.
#
#   scripts/make-icon.sh [variant]            packs AppIcon.icns
#   scripts/make-icon.sh --preview <dir>      renders every variant into <dir>
#
# The artwork is vector code, not a checked-in design file, so the .icns is a
# build product that happens to be committed: bundle.sh copies whatever sits in
# Sources/Skrepka/Resources into the app, and CFBundleIconFile names AppIcon.
#
# The renderer is compiled rather than interpreted because it shares the mark
# with the app — PaperclipPath.swift is linked in beside it, and
# `swift <file>.swift` takes only one file.

set -euo pipefail

cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "▸ Building the renderer"
xcrun swiftc -O -parse-as-library \
	scripts/make-icon.swift \
	Sources/SkrepkaCore/Branding/PaperclipPath.swift \
	-o "${WORK}/make-icon"

if [[ "${1:-}" == "--preview" ]]; then
	if [[ $# -ne 2 ]]; then
		echo "usage: $0 --preview <directory>" >&2
		exit 2
	fi
	"${WORK}/make-icon" --preview "$2"
	exit 0
fi

ICONSET="${WORK}/AppIcon.iconset"
OUTPUT="Sources/Skrepka/Resources/AppIcon.icns"

# No variant named: the renderer falls back to its own first variant, so the
# shipping palette is stated once, in make-icon.swift.
echo "▸ Rendering artwork"
"${WORK}/make-icon" "${ICONSET}" ${1:+"$1"}

echo "▸ Packing ${OUTPUT}"
mkdir -p "$(dirname "${OUTPUT}")"
iconutil --convert icns "${ICONSET}" --output "${OUTPUT}"

echo "✓ ${OUTPUT}"
