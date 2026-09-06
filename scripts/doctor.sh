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

# optional_note <name> <binary> <note> <command...> — as optional, but says
# something more useful than "brew install it" when the tool is absent.
optional_note() {
	local name="$1" binary="$2" note="$3"
	shift 3
	if ! command -v "${binary}" > /dev/null 2>&1; then
		SKIPPED+=("${name} — ${note}")
		return 0
	fi
	check "${name}" "$@"
}

check "format" xcrun swift-format lint --strict --recursive --parallel Sources Tests

# SwiftLint is not in the toolchain and is easy not to have installed, which
# used to mean a Mac developer got a green gate for code the Linux gate refuses.
# scripts/doctor-linux.sh runs SwiftLint 0.65.1 out of skrepka-linux:6.3
# unconditionally, so the check is covered — but only if this says so, because a
# skip that reads like an optional extra is how the coverage gets forgotten.
optional_note "lint" swiftlint \
	"swiftlint not installed. scripts/doctor-linux.sh runs it in the container; run that too, or brew install swiftlint" \
	swiftlint lint --strict --quiet
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

# "clean" has to distinguish five gates passing from three passing and two never
# running, or a lint regression lands under a green tick — which is exactly what
# happened: swiftlint has been absent on this machine for the whole branch and
# every run still said "doctor clean". The count is not decoration.
if ((${#SKIPPED[@]})); then
	green "✓ doctor clean (${#SKIPPED[@]} skipped)"
	# SKREPKA_STRICT is for CI, where a missing tool is a broken image rather
	# than a laptop without a Homebrew package.
	if [[ -n "${SKREPKA_STRICT:-}" ]]; then
		red "✗ SKREPKA_STRICT is set and ${#SKIPPED[@]} check(s) did not run"
		exit 1
	fi
	exit 0
fi

green "✓ doctor clean"
