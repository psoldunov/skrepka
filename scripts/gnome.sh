#!/usr/bin/env bash
# Drive a live headless Ubuntu GNOME session.
#   scripts/gnome.sh up [--fresh] | down | shot NAME | key MOD+KEY
#   scripts/gnome.sh type TEXT | click X Y | eval JAVASCRIPT | windows
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$(pwd)
IMAGE=${SKREPKA_GNOME_IMAGE:-skrepka-gnome:26.04}
CONTAINER=${SKREPKA_GNOME_CONTAINER:-skrepka-gnome}
READY_TIMEOUT=180

if ! docker info >/dev/null 2>&1; then
    echo "docker is not reachable (OrbStack socket: ~/.orbstack/run/docker.sock)." >&2
    exit 1
fi
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "${IMAGE} is not built; run scripts/gnome-image.sh" >&2
    exit 1
fi
running() { [[ $(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null) == true ]]; }
down() { docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true; }
up() {
    if running; then return; fi
    down
    mkdir -p "${REPO}/build/gnome"
    docker run -d --name "${CONTAINER}" --platform linux/amd64 \
        --cap-add SYS_NICE --shm-size 512m \
        -v "${REPO}/build/gnome:/out" \
        "${IMAGE}" skrepka-gnome-session >/dev/null
    local waited=0
    until docker exec "${CONTAINER}" test -f /tmp/gnome/ready 2>/dev/null; do
        if ! running; then
            echo "GNOME session exited while starting:" >&2
            docker logs "${CONTAINER}" 2>&1 | tail -40 >&2
            exit 1
        fi
        if ((waited >= READY_TIMEOUT)); then
            echo "GNOME session was not ready after ${READY_TIMEOUT}s" >&2
            docker logs "${CONTAINER}" 2>&1 | tail -40 >&2
            exit 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    docker logs "${CONTAINER}" 2>&1 | tail -1
}
TTY_ARGS=(-i)
[[ -t 0 && -t 1 ]] && TTY_ARGS=(-it)
in_session() {
    docker exec "${TTY_ARGS[@]}" -u ubuntu "${CONTAINER}" \
        bash -c 'source /tmp/gnome/env && exec "$@"' bash "$@"
}

case ${1:-} in
    up) [[ ${2:-} == --fresh ]] && down; up ;;
    down) down ;;
    shot)
        [[ -n ${2:-} ]] || { echo "usage: scripts/gnome.sh shot NAME" >&2; exit 64; }
        up; in_session skrepka-gnome-screenshot "/out/${2%.png}.png" >/dev/null
        echo "build/gnome/${2%.png}.png"
        ;;
    key) [[ $# -eq 2 ]] || exit 64; up; in_session skrepka-gnome-input key "$2" ;;
    type) [[ $# -eq 2 ]] || exit 64; up; in_session skrepka-gnome-input type "$2" ;;
    click) [[ $# -eq 3 ]] || exit 64; up; in_session skrepka-gnome-input click "$2" "$3" ;;
    right-click) [[ $# -eq 3 ]] || exit 64; up; in_session skrepka-gnome-input click "$2" "$3" secondary ;;
    double-click) [[ $# -eq 3 ]] || exit 64; up; in_session skrepka-gnome-input double-click "$2" "$3" ;;
    eval) [[ $# -eq 2 ]] || exit 64; up; in_session skrepka-gnome-eval "$2" ;;
    windows) up; in_session skrepka-gnome-windows ;;
    "") up; in_session bash ;;
    *) up; in_session "$@" ;;
esac
