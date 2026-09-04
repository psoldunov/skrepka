#!/usr/bin/env bash
#
# The quality gate. Run after every change to Swift source; a green doctor is
# the definition of done.
#
#   scripts/doctor.sh          full run
#   scripts/doctor.sh --fast   skip tests and the dead-code scan (pre-commit)

set -uo pipefail

cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

FAILED=()
SKIPPED=()

bold() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

# check <name> <command...>
check() {
	local name="$1"
	shift
	bold "${name}"
	if "$@"; then
		return 0
	fi
	FAILED+=("${name}")
}

# optional <name> <binary> <command...> — skips with a note if the tool is absent
optional() {
	local name="$1" binary="$2"
	shift 2
	if ! command -v "${binary}" > /dev/null 2>&1; then
		SKIPPED+=("${name} (${binary} not installed — brew install ${binary})")
		return 0
	fi
	check "${name}" "$@"
}

check "format" xcrun swift-format lint --strict --recursive --parallel Sources Tests
optional "lint" swiftlint swiftlint lint --strict --quiet
check "build" swift build

if ((!FAST)); then
	check "test" swift test --parallel
	optional "dead code" periphery periphery scan --strict --quiet
fi

printf '\n'
if ((${#SKIPPED[@]})); then
	for note in "${SKIPPED[@]}"; do
		yellow "⚠ skipped: ${note}"
	done
fi

if ((${#FAILED[@]})); then
	red "✗ doctor failed: ${FAILED[*]}"
	echo "fix formatting with: xcrun swift-format format --in-place --recursive --parallel Sources Tests"
	exit 1
fi

green "✓ doctor clean"
