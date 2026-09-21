#!/usr/bin/env bash
#
# Builds skrepka-kde:3.8 — a headless KDE Plasma 6.4.3 Wayland session made
# from SteamOS 3.8's own packages — from docker/Dockerfile.kde.
#
#   scripts/kde-image.sh
#
# The image exists to test the Linux desktop app against what a Steam Deck in
# Desktop Mode runs: KWin as compositor and global-shortcut daemon,
# plasmashell as tray host, xdg-desktop-portal-kde as the portal backend. See
# the Dockerfile's header for where the packages come from and
# docker/kde/session.sh for how the session is assembled; scripts/kde.sh runs
# commands inside it and scripts/kde-smoke.sh runs the Deck checks.
#
# Always linux/amd64 — SteamOS ships nothing else — so on an Apple Silicon host
# the build and everything in the container run under Rosetta. A first build
# downloads about 560 packages from Valve's mirror and takes around six minutes.
#
# SKREPKA_KDE_IMAGE overrides the tag; scripts/kde.sh reads the same variable.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! docker info > /dev/null 2>&1; then
	echo "docker is not reachable." >&2
	echo "OrbStack exposes its socket at ~/.orbstack/run/docker.sock; under a" >&2
	echo "sandbox that path has to be granted before this script can run." >&2
	exit 1
fi

IMAGE="${SKREPKA_KDE_IMAGE:-skrepka-kde:3.8}"

docker build --platform linux/amd64 \
	-f docker/Dockerfile.kde \
	-t "${IMAGE}" \
	.

echo "built ${IMAGE}"
docker run --rm --platform linux/amd64 "${IMAGE}" \
	pacman -Q kwin plasma-workspace kglobalacceld xdg-desktop-portal \
	xdg-desktop-portal-kde gtk4 glib2 qt6-base mesa
