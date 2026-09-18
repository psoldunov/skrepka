#!/usr/bin/env bash
#
# Runs a command inside the Linux Swift container against this checkout.
#
#   scripts/linux.sh                       an interactive shell
#   scripts/linux.sh swift build --product SkrepkaLinux
#   scripts/linux.sh swift test --filter SkrepkaSyncTests
#   SKREPKA_LINUX_ARCH=amd64 scripts/linux.sh uname -m   the amd64 variant
#
# The container mounts the repository read-write at the same path it has on the
# host, so paths in compiler diagnostics are clickable on both sides. It builds
# into .build-linux rather than .build: the two toolchains produce incompatible
# module caches, and sharing one scratch directory forces a full rebuild on
# every switch.
#
# SKREPKA_LINUX_IMAGE overrides the image. Pinned to 6.3 rather than to what
# the macOS toolchain ships: Xcode 27 ships Swift 6.4, and there is no
# `swift:6.4-noble` on Docker Hub as of 2026-09-18, so the image stays on 6.3
# until the base is published. The two compilers no longer agree on the
# language exactly; the source in this tree still has to compile against
# both.
#
# SKREPKA_LINUX_ARCH — arm64 or amd64 — runs the command in that variant of the
# image, skrepka-linux:6.3-<arch>, with a matching `--platform`, emulated when it
# is not the host's arch. scripts/linux-image.sh builds it under that tag on
# every host. Unset, the plain tag: the host's own arch.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

# skrepka-linux:6.3 is the stock image plus libsqlite3-dev and SwiftLint — see
# docker/Dockerfile.linux, built by scripts/linux-image.sh.
#
# There is no falling back to the stock image, and this comment used to claim
# there was: it said a fresh clone "gets a gate with two more skips in it and no
# SQLite". That is not a state the gate can reach. `doctor-linux.sh` runs
# `swift build --product SkrepkaLinux` as a mandatory check, SkrepkaLinux pulls
# in SkrepkaCore, and SkrepkaCore depends on CSQLite `.when(platforms:
# [.linux])`. Confirmed by running it:
#
#     $ docker run --rm swift:6.3-noble sh -c 'pkg-config --exists sqlite3 || echo NO'
#     NO
#
# so the fallback produced a pkg-config resolution failure that reads as a
# broken repository. Saying "build the image first" is the smaller surprise.
#
# Docker's reachability is asked first: with the daemon down, `docker image
# inspect` fails too, and the message would blame a missing image.
if ! docker info > /dev/null 2>&1; then
	echo "docker is not reachable." >&2
	echo "OrbStack exposes its socket at ~/.orbstack/run/docker.sock; under a" >&2
	echo "sandbox that path has to be granted before this script can run." >&2
	exit 1
fi

SWIFT_VERSION="${SKREPKA_SWIFT_VERSION:-6.3}"
PLATFORM_ARGS=()
case "${SKREPKA_LINUX_ARCH:-}" in
	"")
		DEFAULT_IMAGE="skrepka-linux:${SWIFT_VERSION}"
		;;
	arm64 | amd64)
		DEFAULT_IMAGE="skrepka-linux:${SWIFT_VERSION}-${SKREPKA_LINUX_ARCH}"
		PLATFORM_ARGS=(--platform "linux/${SKREPKA_LINUX_ARCH}")
		;;
	*)
		echo "SKREPKA_LINUX_ARCH must be arm64 or amd64, not ${SKREPKA_LINUX_ARCH}." >&2
		exit 1
		;;
esac

if [[ -z "${SKREPKA_LINUX_IMAGE:-}" ]] \
	&& ! docker image inspect "${DEFAULT_IMAGE}" > /dev/null 2>&1; then
	echo "${DEFAULT_IMAGE} is not built yet." >&2
	echo "Build it with: ${SKREPKA_LINUX_ARCH:+SKREPKA_LINUX_ARCH=${SKREPKA_LINUX_ARCH} }scripts/linux-image.sh" >&2
	echo "It carries libsqlite3-dev and SwiftLint, which the stock swift image" >&2
	echo "does not — the Linux build cannot resolve CSQLite without them." >&2
	echo "Set SKREPKA_LINUX_IMAGE to override." >&2
	exit 1
fi
IMAGE="${SKREPKA_LINUX_IMAGE:-${DEFAULT_IMAGE}}"

# `-it` only when there is a terminal to attach. Passing it unconditionally
# makes every non-interactive caller — CI, doctor-linux.sh, an agent's shell —
# fail with "cannot attach stdin to a TTY-enabled container", which reads as a
# broken build rather than a broken invocation.
# Decided per invocation, from this call's own stdout, and that is what lets a
# caller capture output or redirect bytes through it: a pty turns every LF into
# CRLF, and GNU tar refuses to write an archive to a terminal at all.
# The `${A[@]+"${A[@]}"}` form is deliberate: under `set -u`, bash 3.2 — which
# is what /bin/bash still is on macOS — treats a plain `"${A[@]}"` on an empty
# array as an unbound variable.
TTY_ARGS=()
[[ -t 0 && -t 1 ]] && TTY_ARGS=(-it)

# `Package.resolved` is put back exactly as it was found, for the reason
# doctor-linux.sh gives: the Linux manifest resolves a different graph — no
# KeyboardShortcuts, plus dbus and its dependencies — and SwiftPM rewrites the
# tracked lockfile to match. Any `swift` command run through here used to leave
# that Linux lockfile staged for the next commit. Not `exec`, so the trap runs.
RESOLVED_BACKUP=""
if [[ -f Package.resolved ]]; then
	RESOLVED_BACKUP="$(mktemp)"
	cp Package.resolved "${RESOLVED_BACKUP}"
	trap 'if [[ -n "${RESOLVED_BACKUP}" ]]; then cp "${RESOLVED_BACKUP}" Package.resolved; rm -f "${RESOLVED_BACKUP}"; fi' EXIT
fi

# SwiftPM writes into .build-linux and ~/.cache as the container's user. Running
# as the host user keeps every artefact owned by whoever ran the script, so a
# later macOS build is not blocked by root-owned files in the tree.
docker run --rm ${TTY_ARGS[@]+"${TTY_ARGS[@]}"} \
	${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} \
	-u "$(id -u):$(id -g)" \
	-e HOME=/tmp/skrepka-linux-home \
	-v "${REPO}:${REPO}" \
	-w "${REPO}" \
	"${IMAGE}" \
	"${@:-bash}"
