#!/usr/bin/env bash
#
# Builds the Linux build image scripts/linux.sh runs against.
#
#   scripts/linux-image.sh          build (or rebuild) skrepka-linux:6.3
#
# scripts/linux.sh requires this image and does not fall back to stock
# swift:6.3-noble: the stock image resolves neither CSQLite nor the Phase 5
# wayland and X11 system libraries, so the fallback produced a pkg-config
# failure that read as a broken repository. Run this first on a fresh clone.
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
# Every line here is a thing the gate needs and would otherwise discover as a
# link failure halfway through a build.
# The host's `set -euo pipefail` does not cross into `bash -lc`, so the block
# sets its own: without it only the last command decides the container's exit
# status, and a missing wayland-client would print an empty version and let the
# build report success. Every tool's status is tested by capturing its output
# into a variable rather than piping it, because `set -e` ignores a failure on
# the left of a pipe and `pipefail` would turn `head`'s early exit into one.
docker run --rm "${IMAGE}" bash -lc '
	set -euo pipefail
	swift_version=$(swift --version 2>&1)
	printf "%s\n" "${swift_version}" | sed -n "1p"
	swiftlint_version=$(swiftlint version)
	printf "swiftlint %s\n" "${swiftlint_version}"
	for lib in sqlite3 wayland-client x11 xfixes; do
		version=$(pkg-config --print-errors --modversion "${lib}")
		printf "%s %s\n" "${lib}" "${version}"
	done
	scanner_version=$(wayland-scanner --version 2>&1)
	printf "scanner %s\n" "${scanner_version}"
	sway_version=$(sway --version)
	printf "headless %s\n" "${sway_version}"
	# Xvfb has no --version; it prints usage and exits non-zero for anything it
	# does not recognise, so the package database is what can answer.
	dpkg-query -W -f "headless Xvfb \${Version}\n" xvfb'
