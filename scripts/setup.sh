#!/usr/bin/env bash
#
# Workspace setup: resolve the pinned dependency graph, then warm the debug
# build so the first Doctor or Test press is incremental.
#
# Pins DEVELOPER_DIR exactly as scripts/doctor.sh and scripts/bundle.sh do.
# This is not belt-and-braces: `xcode-select -p` points at CommandLineTools,
# and the CommandLineTools toolchain ships no libSwiftDataMacros.dylib — that
# plugin lives only under Xcode's MacOSX platform directory:
#
#   Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/
#     usr/lib/swift/host/plugins/libSwiftDataMacros.dylib
#
# so an unpinned `swift build` fails on every @Model in Sources/SkrepkaCore/
# Store/ with "plugin for module 'SwiftDataMacros' not found". A SwiftPM
# scratch directory is also keyed to the toolchain that wrote it, so alternating
# between a pinned script and an unpinned one forces a full rebuild each time.

set -euo pipefail

cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -d "${DEVELOPER_DIR}" ]]; then
	echo "error: DEVELOPER_DIR does not exist: ${DEVELOPER_DIR}" >&2
	echo "Skrepka needs a full Xcode 26 install; CommandLineTools cannot build it." >&2
	exit 1
fi

echo "▸ Resolving dependencies"
swift package resolve

echo "▸ Warming the debug build"
swift build

echo "✓ setup complete"
