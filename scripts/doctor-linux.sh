#!/usr/bin/env bash
#
# The Linux quality gate. The macOS one is scripts/doctor.sh; this is its
# counterpart for the targets that have to compile on Linux.
#
#   scripts/doctor-linux.sh          full run
#   scripts/doctor-linux.sh --fast   skip tests and the dead-code scan
#
# It re-enters itself under whichever Linux toolchain this machine has —
# natively, in the nix sandbox nix/dev-env.nix builds, or in the Linux Swift
# container; scripts/lib/linux-env.sh has the order, and SKREPKA_LINUX_RUNNER
# picks one. From macOS it is always the container. Every runner builds into
# .build-linux, never .build: the two toolchains produce incompatible module
# caches, and sharing one scratch directory forces a full rebuild on every
# switch.
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
		SKIPPED+=("${name} (${binary} not on PATH here)")
		return 0
	fi
	check "${name}" "$@"
}

# ---------------------------------------------------------------------------
# Without a toolchain here, re-enter under one and stop.
# ---------------------------------------------------------------------------

# Returns only when `swift` and the libraries are already on hand; otherwise it
# execs this script again under the nix sandbox or the container.
# scripts/linux.sh, behind the container runner, owns the image pin, the bind
# mount and the host-user mapping, and adds `-it` only when there is a terminal
# to attach — so this works the same from a shell, from CI and from an agent.
# shellcheck source=scripts/lib/linux-env.sh
source scripts/lib/linux-env.sh
linux_env_reenter scripts/doctor-linux.sh "$@"

# ---------------------------------------------------------------------------
# The run itself.
# ---------------------------------------------------------------------------

# swift-format ships inside the Linux toolchain at /usr/bin/swift-format, same
# major version as the macOS one, and takes the same flags the macOS gate uses.
# There is no `xcrun` here, so it is invoked directly.
check "format" swift-format lint --strict --recursive --parallel Sources Tests
check "GNOME extension" scripts/test-gnome-extension.sh

# SwiftLint publishes prebuilt Linux binaries. The build image and the nix
# sandbox both carry 0.65.1; a native toolchain without it reports a skip.
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
	#
	# SKREPKA_REQUIRE_HEADLESS turns a missing compositor from a skip into a
	# failure. The live Wayland and X11 suites gate on
	# `.enabled(if: HeadlessSession.isAvailable(...))`, which is right on a
	# native checkout without sway or Xvfb and wrong for the gate: the build
	# image and the nix sandbox install both on purpose, so a regression that
	# dropped one would disable eighteen tests and still go green. A native
	# toolchain has to have both for this gate to pass. Set for this run only,
	# so a bare `swift test` on a developer's machine still skips them.
	check "test" env SKREPKA_REQUIRE_HEADLESS=1 swift test --scratch-path "${SCRATCH}"

	# Periphery ships no Linux binary — the 3.8.0 artifactbundle declares only
	# x86_64-apple-macosx and arm64-apple-macosx. It does build from source on
	# Linux, and nixpkgs carries such a build, so this check turns on wherever
	# one is on PATH; otherwise the dead-code scan stays a macOS-only check and
	# says so.
	#
	# It reads the index store the test build above just wrote instead of
	# building for itself: left alone it runs its own `swift build` into .build —
	# a second full build, into the directory this gate exists to keep Linux
	# builds out of. Pointed at a store by hand, it reports on everything the
	# store indexed, the dependency checkouts under the scratch path included,
	# hence the exclude.
	index_store="$(swift build --show-bin-path --scratch-path "${SCRATCH}")/index/store"
	optional "dead code" periphery periphery scan --strict --quiet --skip-build \
		--index-store-path "${index_store}" --index-exclude "**/${SCRATCH}/**/*"
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
