#!/usr/bin/env bash
#
# Just the Swift Testing suite, for when the whole gate is too slow to be a
# feedback loop. Arguments go to `swift test`:
#
#   scripts/test.sh
#   scripts/test.sh --filter SkrepkaSyncTests
#
# On macOS it pins DEVELOPER_DIR, for the reason scripts/setup.sh gives. On
# Linux it runs under whichever toolchain scripts/linux-env.sh finds and builds
# into .build-linux, like every other Linux script. The live Wayland and X11
# suites run when sway and Xvfb are on hand — they are in the nix sandbox and
# the build image — and skip otherwise; scripts/doctor-linux.sh is the run that
# refuses to skip them.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" == "Linux" ]]; then
	exec scripts/linux-env.sh swift test --parallel --scratch-path .build-linux "$@"
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec swift test --parallel "$@"
