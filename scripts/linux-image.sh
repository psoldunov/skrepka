#!/usr/bin/env bash
#
# Builds the Linux build image scripts/linux.sh runs against.
#
#   scripts/linux-image.sh          build (or rebuild) skrepka-linux:6.3
#
# scripts/linux.sh uses this image when it exists and falls back to stock
# swift:6.3-noble when it does not, so a fresh clone works without running this
# first — it simply gets a gate with two more skips in it and no SQLite.
#
# Set SKREPKA_LINUX_IMAGE to override the tag both scripts use.

set -euo pipefail

cd "$(dirname "$0")/.."

SWIFT_VERSION="${SKREPKA_SWIFT_VERSION:-6.3}"
IMAGE="${SKREPKA_LINUX_IMAGE:-skrepka-linux:${SWIFT_VERSION}}"

if ! docker info > /dev/null 2>&1; then
	echo "docker is not reachable." >&2
	echo "OrbStack exposes its socket at ~/.orbstack/run/docker.sock; under a" >&2
	echo "sandbox that path has to be granted before this script can run." >&2
	exit 1
fi

echo "building ${IMAGE} from docker/Dockerfile.linux"
docker build \
	--build-arg "SWIFT_VERSION=${SWIFT_VERSION}" \
	-f docker/Dockerfile.linux \
	-t "${IMAGE}" \
	docker

echo
echo "built ${IMAGE}:"
docker run --rm "${IMAGE}" bash -lc 'swift --version | head -1; swiftlint version | sed "s/^/swiftlint /"; pkg-config --modversion sqlite3 | sed "s/^/sqlite3 /"'
