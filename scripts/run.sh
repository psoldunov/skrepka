#!/usr/bin/env bash
#
# Build, bundle, sign and launch Skrepka.
#
# Launches via `open` rather than executing the binary directly: TCC attributes
# permissions to the responsible process, so a shell-launched binary inherits
# the terminal's grants and does NOT exercise the real permission path.

set -euo pipefail

cd "$(dirname "$0")/.."

# SKREPKA_REVEAL=0 because this script launches the app; a Finder window opening
# over the thing you are about to run is noise, not a result.
SKREPKA_REVEAL=0 scripts/bundle.sh

echo "▸ Stopping any running instance"
pkill -x Skrepka 2> /dev/null || true

# Wait for it to actually go: launching while the old process is still
# terminating makes LaunchServices reactivate the dying instance instead.
for _ in $(seq 1 40); do
	pgrep -x Skrepka > /dev/null 2>&1 || break
	sleep 0.1
done

echo "▸ Launching"
open build/Skrepka.app
