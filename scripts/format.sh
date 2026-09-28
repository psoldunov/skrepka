#!/usr/bin/env bash
#
# Rewrites Sources and Tests in place with swift-format — the fixer the format
# check in scripts/doctor.sh and scripts/doctor-linux.sh points at.
#
# On macOS it runs Xcode's swift-format, pinned through DEVELOPER_DIR:
# CommandLineTools carries its own, and two versions of it disagree about
# formatting. On Linux it runs the one inside the Swift toolchain
# scripts/linux-env.sh finds, which is the same one doctor-linux.sh checks with.

set -euo pipefail

cd "$(dirname "$0")/.."

ARGS=(format --in-place --recursive --parallel Sources Tests)

if [[ "$(uname -s)" == "Linux" ]]; then
	exec scripts/linux-env.sh swift-format "${ARGS[@]}"
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec xcrun swift-format "${ARGS[@]}"
