#!/usr/bin/env bash
#
# The Linux quality gate. The macOS one is scripts/doctor.sh; this is its
# counterpart for the targets that have to compile on Linux.
#
#   scripts/doctor-linux.sh          full run
#   scripts/doctor-linux.sh --fast   skip tests and the dead-code scan
#
# Run it from macOS and it re-enters itself inside the Linux Swift container.
# Run it on Linux and it runs natively. Either way it builds into .build-linux,
# never .build: the two toolchains produce incompatible module caches, and
# sharing one scratch directory forces a full rebuild on every switch.
#
# One thing it deliberately does NOT do, verified 2026-09-05 against Swift
# 6.3.3 on aarch64-unknown-linux-gnu and recorded in docs/linux-sync/
# open-questions.md under OQ-13: `swift build --target A --target B`.
# `--target` is singular. SwiftPM accepts the repeated flag, silently builds
# only the LAST one, and exits 0 — so a gate written that way goes green
# without ever compiling half of what it claims to. The `SkrepkaLinux` product
# covers both portable targets in one invocation instead.

set -uo pipefail

cd "$(dirname "$0")/.."

FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

SCRATCH=".build-linux"

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
		SKIPPED+=("${name} (${binary} not on PATH in this container)")
		return 0
	fi
	check "${name}" "$@"
}

# ---------------------------------------------------------------------------
# On macOS, re-enter inside the container and stop.
# ---------------------------------------------------------------------------

if [[ "$(uname -s)" != "Linux" ]]; then
	bold "delegating to the Linux container"
	# scripts/linux.sh owns the image pin, the bind mount and the host-user
	# mapping, and adds `-it` only when there is a terminal to attach — so this
	# works the same from a shell, from CI and from an agent.
	exec scripts/linux.sh scripts/doctor-linux.sh "$@"
fi

# ---------------------------------------------------------------------------
# Native Linux run.
# ---------------------------------------------------------------------------

# swift-format ships inside the Linux toolchain at /usr/bin/swift-format, same
# major version as the macOS one, and takes the same flags the macOS gate uses.
# There is no `xcrun` here, so it is invoked directly.
check "format" swift-format lint --strict --recursive --parallel Sources Tests

# SwiftLint publishes a prebuilt Linux aarch64 binary but it is not in the
# stock swift image, so from macOS this always skips. Bake it into a derived
# image and point SKREPKA_LINUX_IMAGE at that to turn the check on.
optional "lint" swiftlint swiftlint lint --strict --quiet

# `SkrepkaLinux` is the two portable targets in one product. It has to be
# declared `type: .static` for this to work at all: `--product` refuses an
# automatic library product and falls back to building everything, app target
# included.
check "build" swift build --product SkrepkaLinux --scratch-path "${SCRATCH}"

if ((!FAST)); then
	# `swift test` has no `--product` and no `--target`; it builds the whole
	# package. That works here only because Package.swift fences the macOS-only
	# app target out on Linux.
	#
	# Deliberately unfiltered. `SkrepkaCoreTests` compiles and passes here too —
	# the files that cannot are guarded at file scope — so filtering to
	# SkrepkaSyncTests would run 55 of the 144 tests this platform can actually
	# run, and report the other 89 as neither passed nor skipped.
	check "test" swift test --scratch-path "${SCRATCH}"

	# Periphery ships no Linux binary — the 3.8.0 artifactbundle declares only
	# x86_64-apple-macosx and arm64-apple-macosx. It does build from source on
	# Linux, so this check turns on for anyone who does that; otherwise the
	# dead-code scan stays a macOS-only check and says so.
	optional "dead code" periphery periphery scan --strict --quiet
fi

printf '\n'
if ((${#SKIPPED[@]})); then
	for note in "${SKIPPED[@]}"; do
		yellow "⚠ skipped: ${note}"
	done
fi

if ((${#FAILED[@]})); then
	red "✗ doctor-linux failed: ${FAILED[*]}"
	echo "fix formatting with: swift-format format --in-place --recursive --parallel Sources Tests"
	exit 1
fi

# Same reason as doctor.sh: "clean" has to distinguish every gate passing from
# some of them never running, or a regression lands under a green tick.
if ((${#SKIPPED[@]})); then
	green "✓ doctor-linux clean (${#SKIPPED[@]} skipped)"
	if [[ -n "${SKREPKA_STRICT:-}" ]]; then
		red "✗ SKREPKA_STRICT is set and ${#SKIPPED[@]} check(s) did not run"
		exit 1
	fi
	exit 0
fi

green "✓ doctor-linux clean"
