# shellcheck shell=bash
#
# What scripts/test-copr.sh and scripts/publish-copr.sh share: the version the
# spec names, the two sources it lists, fetched and checked, and the source RPM
# built from them. Sourced, never run: it defines functions and a few
# variables, and runs nothing on its own. The sourcing script has already cd'd
# to the repository root and set REPO.
#
# Both scripts build the source RPM here rather than letting COPR fetch the
# spec's Source0 URL itself, so what COPR builds is the same file the tests
# built from, byte for byte.

COPR_SPEC="packaging/copr/skrepka.spec"
COPR_ASSET="skrepka-linux-x86_64"
COPR_BUILD="build/copr"
COPR_SOURCES="${COPR_BUILD}/sources"
COPR_SRPMS="${COPR_BUILD}/srpm"
COPR_RELEASES="https://github.com/psoldunov/skrepka/releases/download"
COPR_RAW="https://raw.githubusercontent.com/psoldunov/skrepka"

# Fedora 43 rather than a newer one for rpmbuild, because rpmbuild unpacks
# Source0 with tar: under OrbStack's Rosetta translation of amd64, Fedora 44's
# tar (1.35-8.fc44) fails every extraction with "Function not implemented",
# and 43's (1.35-6.fc43) does not. Checked 2026-09-22. `dnf install` of the
# result works under translation on 44, 45 and rawhide alike.
COPR_BUILD_IMAGE="${SKREPKA_COPR_BUILD_IMAGE:-fedora:43}"

copr_fail() {
	echo "error: $1" >&2
	exit 1
}

copr_bold() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
copr_green() { printf '\033[32m%s\033[0m\n' "$1"; }

copr_require_docker() {
	if ! docker info > /dev/null 2>&1; then
		copr_fail "docker is not reachable (OrbStack exposes it at ~/.orbstack/run/docker.sock)."
	fi
}

# spec_version — the spec's Version. Exactly one Version: line, as
# scripts/pin-release.sh writes it.
spec_version() {
	local versions
	versions="$(awk '$1 == "Version:" { print $2 }' "${COPR_SPEC}")"
	[[ "${versions}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| copr_fail "${COPR_SPEC} should have exactly one Version: line, and it has '${versions}'."
	printf '%s\n' "${versions}"
}

# spec_release — the spec's Release, without the dist tag: 1, unless a
# packaging-only fix bumped it.
spec_release() {
	local release
	release="$(awk '$1 == "Release:" { print $2 }' "${COPR_SPEC}")"
	release="${release%\%\{?dist\}}"
	[[ "${release}" =~ ^[0-9]+$ ]] || copr_fail "${COPR_SPEC} has no Release: line of the form N%{?dist}."
	printf '%s\n' "${release}"
}

sha256_of() {
	if command -v sha256sum > /dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

# fetch_sources VERSION [TARBALL] — puts Source0 and Source1 in COPR_SOURCES
# under the names the spec gives them.
#
# Without TARBALL, Source0 is the published release asset, checked against the
# .sha256 published beside it, and Source1 is LICENSE at the release's tag, so
# both prove the release and its tag exist. A copy already downloaded is kept
# when it still matches. With TARBALL — an unreleased build from
# scripts/build-deck.sh — Source0 is that file and Source1 the checkout's
# LICENSE, and nothing is downloaded.
fetch_sources() {
	local version="$1" tarball="${2:-}"
	local source0="${COPR_SOURCES}/${COPR_ASSET}-${version}.tar.gz"
	local expected actual
	mkdir -p "${COPR_SOURCES}"

	if [[ -n "${tarball}" ]]; then
		[[ -s "${tarball}" ]] || copr_fail "${tarball} is missing or empty."
		cp "${tarball}" "${source0}"
		cp "${REPO}/LICENSE" "${COPR_SOURCES}/LICENSE"
		return
	fi

	expected="$(curl -fsSL "${COPR_RELEASES}/v${version}/${COPR_ASSET}.tar.gz.sha256" | awk '{ print $1 }')" \
		|| copr_fail "could not download v${version}/${COPR_ASSET}.tar.gz.sha256; is the release published?"
	[[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || copr_fail "the published .sha256 for v${version} holds no SHA-256."

	if [[ ! -s "${source0}" || "$(sha256_of "${source0}")" != "${expected}" ]]; then
		copr_bold "Downloading ${COPR_ASSET}.tar.gz v${version}"
		curl -fL --progress-bar -o "${source0}" "${COPR_RELEASES}/v${version}/${COPR_ASSET}.tar.gz" \
			|| copr_fail "could not download v${version}/${COPR_ASSET}.tar.gz."
	fi
	actual="$(sha256_of "${source0}")"
	[[ "${actual}" == "${expected}" ]] \
		|| copr_fail "${source0} has SHA-256 ${actual}; the release publishes ${expected}."

	curl -fsSL -o "${COPR_SOURCES}/LICENSE" "${COPR_RAW}/v${version}/LICENSE" \
		|| copr_fail "could not download LICENSE at tag v${version}; is the tag pushed?"
}

# in_build_image SCRIPT — runs SCRIPT under bash in COPR_BUILD_IMAGE, as amd64,
# with rpmbuild, rpmlint and the spec's BuildRequires installed, and the
# repository mounted read-write at its host path, as scripts/linux.sh mounts
# it. HOST_UID and HOST_GID let SCRIPT hand what it writes back to whoever ran
# this: dnf needs root, and a Linux host would otherwise get root-owned files.
in_build_image() {
	docker run --rm --platform linux/amd64 \
		-v "${REPO}:${REPO}" \
		-w "${REPO}" \
		-e "HOST_UID=$(id -u)" \
		-e "HOST_GID=$(id -g)" \
		"${COPR_BUILD_IMAGE}" \
		bash -euo pipefail -c "
dnf -q -y install rpm-build rpmlint systemd-rpm-macros desktop-file-utils > /tmp/dnf.log 2>&1 \\
	|| { cat /tmp/dnf.log >&2; exit 1; }
$1"
}

# build_srpm VERSION — the source RPM for the pinned spec, from the sources
# fetch_sources left, into COPR_SRPMS; prints its path. Without a dist tag in
# its name: COPR rebuilds it once per chroot, each with that chroot's own.
build_srpm() {
	local version="$1" srpm
	srpm="${COPR_SRPMS}/skrepka-${version}-$(spec_release).src.rpm"
	rm -rf "${COPR_SRPMS}"
	mkdir -p "${COPR_SRPMS}"
	copr_bold "Building $(basename "${srpm}")" >&2
	in_build_image "
rpmbuild -bs \
	--define '_sourcedir ${REPO}/${COPR_SOURCES}' \
	--define '_srcrpmdir ${REPO}/${COPR_SRPMS}' \
	--define 'dist %{nil}' \
	'${COPR_SPEC}' > /dev/null
chown -R \"\${HOST_UID}:\${HOST_GID}\" '${COPR_SRPMS}'" >&2
	[[ -s "${srpm}" ]] || copr_fail "rpmbuild wrote no ${srpm}."
	printf '%s\n' "${srpm}"
}
