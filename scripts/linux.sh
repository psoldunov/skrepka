#!/usr/bin/env bash
#
# Runs a command inside the Linux Swift container against this checkout.
#
#   scripts/linux.sh                       an interactive shell
#   scripts/linux.sh swift build --product SkrepkaLinux
#   scripts/linux.sh swift test --filter SkrepkaSyncTests
#
# The container mounts the repository read-write at the same path it has on the
# host, so paths in compiler diagnostics are clickable on both sides. It builds
# into .build-linux rather than .build: the two toolchains produce incompatible
# module caches, and sharing one scratch directory forces a full rebuild on
# every switch.
#
# SKREPKA_LINUX_IMAGE overrides the image. It is pinned to the same Swift
# version the macOS toolchain ships, because "compiles on Linux" is only a
# useful claim when the two compilers agree on the language.

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
DEFAULT_IMAGE="skrepka-linux:6.3"
if [[ -z "${SKREPKA_LINUX_IMAGE:-}" ]] \
	&& ! docker image inspect "${DEFAULT_IMAGE}" > /dev/null 2>&1; then
	echo "${DEFAULT_IMAGE} is not built yet." >&2
	echo "Build it with: scripts/linux-image.sh" >&2
	echo "It carries libsqlite3-dev and SwiftLint, which the stock swift image" >&2
	echo "does not — the Linux build cannot resolve CSQLite without them." >&2
	echo "Set SKREPKA_LINUX_IMAGE to override." >&2
	exit 1
fi
IMAGE="${SKREPKA_LINUX_IMAGE:-${DEFAULT_IMAGE}}"

if ! docker info > /dev/null 2>&1; then
	echo "docker is not reachable." >&2
	echo "OrbStack exposes its socket at ~/.orbstack/run/docker.sock; under a" >&2
	echo "sandbox that path has to be granted before this script can run." >&2
	exit 1
fi

# `-it` only when there is a terminal to attach. Passing it unconditionally
# makes every non-interactive caller — CI, doctor-linux.sh, an agent's shell —
# fail with "cannot attach stdin to a TTY-enabled container", which reads as a
# broken build rather than a broken invocation.
# The `${A[@]+"${A[@]}"}` form is deliberate: under `set -u`, bash 3.2 — which
# is what /bin/bash still is on macOS — treats a plain `"${A[@]}"` on an empty
# array as an unbound variable.
TTY_ARGS=()
[[ -t 0 && -t 1 ]] && TTY_ARGS=(-it)

# SwiftPM writes into .build-linux and ~/.cache as the container's user. Running
# as the host user keeps every artefact owned by whoever ran the script, so a
# later macOS build is not blocked by root-owned files in the tree.
exec docker run --rm ${TTY_ARGS[@]+"${TTY_ARGS[@]}"} \
	-u "$(id -u):$(id -g)" \
	-e HOME=/tmp/skrepka-linux-home \
	-v "${REPO}:${REPO}" \
	-w "${REPO}" \
	"${IMAGE}" \
	"${@:-bash}"
