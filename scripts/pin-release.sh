#!/usr/bin/env bash
#
# Points every recipe that repackages the Linux release at one release:
#
#   nix/package.nix              `version` and the tarball's SRI `hash`
#   packaging/copr/skrepka.spec  Version, Release back to 1, and its one
#                                %changelog entry
#
#   scripts/pin-release.sh 0.3.0 build/deck/skrepka-linux-x86_64.tar.gz
#   scripts/pin-release.sh 0.3.0     download the published tarball
#
# Run it after scripts/build-deck.sh and commit what it changes. The tarball
# carries nothing from nix/ or packaging/copr/, so that commit changes no byte
# of the release and is the one to tag; hashing the local file is the same as
# hashing the asset uploaded from it.
#
# The Nix hash is the SRI form fetchurl checks: sha256 of the tarball's bytes,
# base64. It is computed with openssl so neither Nix nor a Linux host is
# needed to run this. The spec needs no hash: scripts/publish-copr.sh checks
# the tarball against the release's own .sha256 before it builds the source
# package COPR receives.
#
# Pinning the version the spec already names leaves its %changelog date alone,
# so a second run changes nothing.

set -euo pipefail

cd "$(dirname "$0")/.."

NIX_PACKAGE="nix/package.nix"
SPEC="packaging/copr/skrepka.spec"
ASSET="skrepka-linux-x86_64.tar.gz"
MAINTAINER="Philipp Soldunov <69530789+psoldunov@users.noreply.github.com>"

fail() {
	echo "error: $1" >&2
	exit 1
}

VERSION="${1:-}"
TARBALL="${2:-}"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| fail "usage: scripts/pin-release.sh VERSION [TARBALL], with VERSION like 0.3.0"

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

# rewrite FILE PATTERN LINE — replaces the one line of FILE matching the
# extended regex PATTERN with LINE. Exactly one: a second match would be a
# file this script no longer understands.
rewrite() {
	local file="$1" pattern="$2" line="$3" count next
	count="$(grep -Ec -- "${pattern}" "${file}" || true)"
	[[ "${count}" == "1" ]] || fail "expected exactly one line matching '${pattern}' in ${file}, found ${count}."
	next="$(mktemp)"
	PATTERN="${pattern}" LINE="${line}" awk '$0 ~ ENVIRON["PATTERN"] { print ENVIRON["LINE"]; next } { print }' \
		"${file}" > "${next}"
	# Written through rather than moved, so the file keeps its own mode.
	cat "${next}" > "${file}"
	rm -f "${next}"
}

rewrite "${NIX_PACKAGE}" '^  version = "[^"]*";$' "  version = \"${VERSION}\";"
rewrite "${NIX_PACKAGE}" '^    hash = "sha256-[^"]*";$' "    hash = \"${HASH}\";"
echo "✓ ${NIX_PACKAGE}: version ${VERSION}, ${HASH}"

PINNED="$(awk '$1 == "Version:" { print $2 }' "${SPEC}")"
if [[ "${PINNED}" == "${VERSION}" ]]; then
	echo "✓ ${SPEC}: already version ${VERSION}"
	exit 0
fi

# The weekday and date format rpm's %changelog requires, in English whatever
# the locale.
TODAY="$(LC_ALL=C date -u '+%a %b %d %Y')"
rewrite "${SPEC}" '^Version:        [^ ]+$' "Version:        ${VERSION}"
rewrite "${SPEC}" '^Release:        [0-9]+%\{\?dist\}$' "Release:        1%{?dist}"
rewrite "${SPEC}" '^\* [A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{2} [0-9]{4} .* - [0-9.]+-[0-9]+$' \
	"* ${TODAY} ${MAINTAINER} - ${VERSION}-1"
rewrite "${SPEC}" '^- Skrepka [0-9.]+: https://.*/CHANGELOG\.md$' \
	"- Skrepka ${VERSION}: https://github.com/psoldunov/skrepka/blob/v${VERSION}/CHANGELOG.md"
echo "✓ ${SPEC}: version ${VERSION}-1, changelog dated ${TODAY}"
