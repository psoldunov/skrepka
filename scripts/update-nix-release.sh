#!/usr/bin/env bash
#
# Points the Nix flake at a release: rewrites `version` and the tarball's
# `hash` in nix/package.nix.
#
#   scripts/update-nix-release.sh 0.3.0 build/deck/skrepka-linux-x86_64.tar.gz
#   scripts/update-nix-release.sh 0.3.0     download the published tarball
#
# Run it after scripts/build-deck.sh and commit what it changes. The tarball
# carries nothing from nix/, so that commit changes no byte of the release and
# is the one to tag; hashing the local file is the same as hashing the asset
# uploaded from it.
#
# The hash is the SRI form fetchurl checks: sha256 of the tarball's bytes,
# base64. It is computed with openssl so neither Nix nor a Linux host is
# needed to run this.

set -euo pipefail

cd "$(dirname "$0")/.."

PACKAGE="nix/package.nix"
ASSET="skrepka-linux-x86_64.tar.gz"

fail() {
	echo "error: $1" >&2
	exit 1
}

VERSION="${1:-}"
TARBALL="${2:-}"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| fail "usage: scripts/update-nix-release.sh VERSION [TARBALL], with VERSION like 0.3.0"

if [[ -z "${TARBALL}" ]]; then
	DOWNLOAD="$(mktemp -d)"
	trap 'rm -f "${DOWNLOAD}/${ASSET}"; rmdir "${DOWNLOAD}"' EXIT
	TARBALL="${DOWNLOAD}/${ASSET}"
	curl -fsSL -o "${TARBALL}" \
		"https://github.com/psoldunov/skrepka/releases/download/v${VERSION}/${ASSET}" \
		|| fail "could not download v${VERSION}/${ASSET}; is the release published?"
fi
[[ -s "${TARBALL}" ]] || fail "${TARBALL} is missing or empty."

HASH="sha256-$(openssl dgst -sha256 -binary "${TARBALL}" | openssl base64 -A)"

# rewrite PATTERN LINE — replaces the one line of nix/package.nix matching the
# extended regex PATTERN with LINE. Exactly one: a second `version =` or
# `hash =` would be a file this script no longer understands.
rewrite() {
	local pattern="$1" line="$2" count next
	count="$(grep -Ec -- "${pattern}" "${PACKAGE}" || true)"
	[[ "${count}" == "1" ]] || fail "expected exactly one line matching '${pattern}' in ${PACKAGE}, found ${count}."
	next="$(mktemp)"
	PATTERN="${pattern}" LINE="${line}" awk '$0 ~ ENVIRON["PATTERN"] { print ENVIRON["LINE"]; next } { print }' \
		"${PACKAGE}" > "${next}"
	# Written through rather than moved, so the file keeps its own mode.
	cat "${next}" > "${PACKAGE}"
	rm -f "${next}"
}

rewrite '^  version = "[^"]*";$' "  version = \"${VERSION}\";"
rewrite '^    hash = "sha256-[^"]*";$' "    hash = \"${HASH}\";"

echo "✓ ${PACKAGE}: version ${VERSION}, ${HASH}"
