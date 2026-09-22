#!/usr/bin/env bash
# Build the amd64 Ubuntu 26.04 / GNOME 50 headless desktop image.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! docker info >/dev/null 2>&1; then
    echo "docker is not reachable (OrbStack socket: ~/.orbstack/run/docker.sock)." >&2
    exit 1
fi

IMAGE=${SKREPKA_GNOME_IMAGE:-skrepka-gnome:26.04}
start=$SECONDS
docker build --platform linux/amd64 -f docker/Dockerfile.gnome -t "${IMAGE}" .
echo "built ${IMAGE} in $((SECONDS - start))s"

# These are the flags docker/gnome/session.sh relies on. The image's installed
# help is the source of truth, not a remembered GNOME release API.
help=$(docker run --rm --platform linux/amd64 "${IMAGE}" gnome-shell --help 2>&1)
for flag in --headless --virtual-monitor; do
    grep -q -- "${flag}" <<<"${help}" || { echo "gnome-shell lacks ${flag}" >&2; exit 1; }
done
# GNOME 50 deliberately hides --unsafe-mode from --help; invoking it with
# --version verifies that the installed option parser accepts it. Mutter 50.1
# source: src/core/meta-context-main.c, option table entry "unsafe-mode".
docker run --rm --platform linux/amd64 "${IMAGE}" \
    gnome-shell --unsafe-mode --version >/dev/null

docker run --rm --platform linux/amd64 "${IMAGE}" bash -lc '
    gnome-shell --version
    dpkg-query -W \
        mutter-common gnome-shell xdg-desktop-portal xdg-desktop-portal-gnome \
        gnome-shell-ubuntu-extensions libgtk-4-1 libglib2.0-0t64 \
        libgl1-mesa-dri mesa-vulkan-drivers
'
