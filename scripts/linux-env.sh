#!/usr/bin/env bash
#
# Runs a command with the Linux Swift toolchain, wherever that is on this
# machine — the counterpart of scripts/linux.sh for the edit loop.
#
#   scripts/linux-env.sh                                       an interactive shell
#   scripts/linux-env.sh swift build --product SkrepkaLinux --scratch-path .build-linux
#   SKREPKA_LINUX_RUNNER=container scripts/linux-env.sh swift --version
#
# On Linux it uses a native toolchain when there is one, the nix sandbox
# (nix/dev-env.nix) when there is nix, and the build image otherwise; on macOS
# it is always the build image. scripts/lib/linux-env.sh has the rules.
#
# scripts/linux.sh stays the one that always means the container: the release
# builds in scripts/build-deck.sh go through it on purpose, because the build
# image is what defines the glibc and GTK floor the release tarball promises.
#
# Pass --scratch-path .build-linux to swift yourself. Every Linux script does,
# so a native build, a nix build and a container build of the same checkout
# share one scratch directory and never clobber the macOS .build.

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/linux-env.sh
source scripts/lib/linux-env.sh

runner="$(linux_env_runner)"
linux_env_exec "${runner}" "$@"
