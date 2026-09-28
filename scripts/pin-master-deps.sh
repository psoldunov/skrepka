#!/usr/bin/env bash
#
# Re-hashes the SwiftPM checkouts the flake's `master` package builds from,
# into nix/pins.json:
#
#   scripts/pin-master-deps.sh
#
# Run it and commit what it changes whenever Package.resolved changes. Until
# then `nix build .#master` stops with a hash mismatch rather than building
# against the old checkouts: nix/master.nix names the fixed-output derivation
# after Package.resolved, so a stale hash cannot be silently reused.
#
# Builds the placeholder hash on purpose and reads the real one out of Nix's
# mismatch error, which is the only place Nix reports it. Linux with nix only,
# since the checkouts are resolved inside nix/dev-env.nix's sandbox. Reads the
# flake from the working tree, so a new or changed file has to be at least
# `git add`ed for Nix to see it.

set -euo pipefail

cd "$(dirname "$0")/.."

readonly SYSTEM=x86_64-linux
readonly PINS=nix/pins.json
readonly FAKE_HASH=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

fail() {
	echo "error: $1" >&2
	exit 1
}

command -v nix > /dev/null 2>&1 || fail "nix is not on PATH."
command -v jq > /dev/null 2>&1 || fail "jq is not on PATH."

# set_pin HASH — writes HASH into pins.json as this system's deps hash. jq
# finishes before the file is opened, and writing through the existing file
# keeps its mode.
set_pin() {
	local next
	# shellcheck disable=SC2016 # jq's own variables, bound by --arg
	next="$(jq --arg system "${SYSTEM}" --arg hash "$1" '.deps[$system] = $hash' "${PINS}")"
	printf '%s\n' "${next}" > "${PINS}"
}

# shellcheck disable=SC2016 # jq's own variable, bound by --arg
PREVIOUS="$(jq -r --arg system "${SYSTEM}" '.deps[$system]' "${PINS}")"
LOG="$(mktemp)"

# Puts the previous pin back and drops the build log. Runs on every exit while
# the placeholder is in pins.json, so an error or an interrupt never leaves it
# there.
restore_pin() {
	set_pin "${PREVIOUS}"
	rm -f "${LOG}"
}
trap restore_pin EXIT

set_pin "${FAKE_HASH}"

if nix build ".#packages.${SYSTEM}.master.deps" --no-link 2> "${LOG}"; then
	fail "the placeholder hash built, which should be impossible; left the pin as it was."
fi

HASH="$(sed -nE 's/.*got: +(sha256-[A-Za-z0-9+/]+=*).*/\1/p' "${LOG}" | tail -n 1)"
if [[ -z "${HASH}" ]]; then
	cat "${LOG}" >&2
	fail "the deps build failed before reporting a hash; left the pin as it was."
fi

trap - EXIT
rm -f "${LOG}"
set_pin "${HASH}"
echo "Pinned the ${SYSTEM} SwiftPM checkouts to ${HASH}."
