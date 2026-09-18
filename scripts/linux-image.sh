#!/usr/bin/env bash
#
# Builds the Linux build image scripts/linux.sh runs against.
#
#   scripts/linux-image.sh                    build skrepka-linux:6.3 for the host
#   SKREPKA_LINUX_ARCH=amd64 scripts/linux-image.sh   build the amd64 variant
#
# scripts/linux.sh requires this image and does not fall back to stock
# swift:6.3-noble: the stock image resolves neither CSQLite nor the Phase 5
# wayland and X11 system libraries, so the fallback produced a pkg-config
# failure that read as a broken repository. Run this first on a fresh clone.
#
# SKREPKA_LINUX_ARCH — one of arm64 or amd64. When unset, the image is built
# for whatever `docker info` reports as OSArch, tagged plainly
# skrepka-linux:${SWIFT_VERSION}. When set, `--platform linux/${arch}` is
# passed to `docker build` and the tag carries the arch as a suffix, so an
# aarch64 host can carry both variants side by side without either overwriting
# the other. The amd64 variant is what scripts/build-deck.sh runs against
# because the Steam Deck is x86_64 only and Swift on Linux is not a cross
# compiler.
#
# SKREPKA_LINUX_IMAGE overrides the tag either variant produces.

set -euo pipefail

cd "$(dirname "$0")/.."

SWIFT_VERSION="${SKREPKA_SWIFT_VERSION:-6.3}"

# `docker info` reports the daemon's own arch (linux/arm64/v8, linux/amd64…);
# splitting on the second slash is the field docker itself uses for --platform
# elsewhere, so a plain build with no arch override matches what docker would
# have picked anyway.
HOST_ARCH="$(docker info --format '{{.OSType}}/{{.Architecture}}' 2> /dev/null | cut -d/ -f2)"
case "${HOST_ARCH}" in
	aarch64) HOST_ARCH="arm64" ;;
	x86_64) HOST_ARCH="amd64" ;;
esac

ARCH="${SKREPKA_LINUX_ARCH:-${HOST_ARCH:-}}"
case "${ARCH:-}" in
	arm64 | amd64) ;;
	"")
		echo "cannot determine host arch, and SKREPKA_LINUX_ARCH is unset." >&2
		echo "Set SKREPKA_LINUX_ARCH to arm64 or amd64." >&2
		exit 1
		;;
	*)
		echo "SKREPKA_LINUX_ARCH must be arm64 or amd64, not ${ARCH}." >&2
		exit 1
		;;
esac

# The plain tag stays skrepka-linux:${SWIFT_VERSION} whenever the arch matches
# the host — every existing caller keeps working — and the amd64 build on an
# arm64 host gets its own tag so the two coexist.
if [[ -n "${SKREPKA_LINUX_IMAGE:-}" ]]; then
	IMAGE="${SKREPKA_LINUX_IMAGE}"
elif [[ "${ARCH}" == "${HOST_ARCH}" ]]; then
	IMAGE="skrepka-linux:${SWIFT_VERSION}"
else
	IMAGE="skrepka-linux:${SWIFT_VERSION}-${ARCH}"
fi

if ! docker info > /dev/null 2>&1; then
	echo "docker is not reachable." >&2
	echo "OrbStack exposes its socket at ~/.orbstack/run/docker.sock; under a" >&2
	echo "sandbox that path has to be granted before this script can run." >&2
	exit 1
fi

echo "building ${IMAGE} from docker/Dockerfile.linux (linux/${ARCH})"
docker build \
	--platform "linux/${ARCH}" \
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
docker run --rm --platform "linux/${ARCH}" "${IMAGE}" bash -lc '
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
