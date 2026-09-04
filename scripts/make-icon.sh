#!/usr/bin/env bash
#
# Regenerates Sources/Clippy/Resources/AppIcon.icns from scripts/make-icon.swift.
#
# The artwork is vector code, not a checked-in design file, so the .icns is a
# build product that happens to be committed: bundle.sh copies whatever sits in
# Sources/Clippy/Resources into the app, and CFBundleIconFile names AppIcon.

set -euo pipefail

cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VARIANT="${1:-sand}"
ICONSET="$(mktemp -d)/AppIcon.iconset"
OUTPUT="Sources/Clippy/Resources/AppIcon.icns"

echo "▸ Rendering artwork"
swift scripts/make-icon.swift "${ICONSET}" "${VARIANT}"

echo "▸ Packing ${OUTPUT}"
mkdir -p "$(dirname "${OUTPUT}")"
iconutil --convert icns "${ICONSET}" --output "${OUTPUT}"

echo "✓ ${OUTPUT}"
