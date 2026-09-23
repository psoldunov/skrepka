# shellcheck shell=bash
#
# What scripts/test-pacstall.sh and scripts/publish-pacstall.sh share: the
# pacscript's pinned version and hash, the .deb it names, and the linters
# pacstall-programs runs on every pacscript. Sourced, never run: it defines
# functions and a few variables, and runs nothing on its own. The sourcing
# script has already cd'd to the repository root and set REPO.

PACSTALL_PKG="skrepka-deb"
PACSTALL_SCRIPT="packaging/pacstall/${PACSTALL_PKG}.pacscript"
PACSTALL_ASSET="skrepka-linux-x86_64.deb"
PACSTALL_RELEASES="https://github.com/psoldunov/skrepka/releases/download"
# shellcheck disable=SC2034 # the sourcing scripts' scratch directory
PACSTALL_BUILD="build/pacstall"

# Debian 13 carries shfmt, shellcheck and a bash new enough for
# pacstall-programs' scripts/srcinfo.sh, which macOS's bash 3.2 is not.
PACSTALL_TOOLS_IMAGE="${SKREPKA_PACSTALL_TOOLS_IMAGE:-debian:13}"

pacstall_fail() {
	echo "error: $1" >&2
	exit 1
}

pacstall_bold() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
pacstall_green() { printf '\033[32m%s\033[0m\n' "$1"; }

pacstall_require_docker() {
	if ! docker info > /dev/null 2>&1; then
		pacstall_fail "docker is not reachable (OrbStack exposes it at ~/.orbstack/run/docker.sock)."
	fi
}

# pacscript_version — the pacscript's pkgver. Exactly one pkgver= line, as
# scripts/pin-release.sh writes it.
pacscript_version() {
	local version
	version="$(sed -n 's/^pkgver="\([^"]*\)"$/\1/p' "${PACSTALL_SCRIPT}")"
	[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| pacstall_fail "${PACSTALL_SCRIPT} should have exactly one pkgver= line, and it has '${version}'."
	printf '%s\n' "${version}"
}

# pacscript_sha256 — the one hash in the pacscript's sha256sums.
pacscript_sha256() {
	local sum
	sum="$(sed -n 's/^sha256sums=("\([0-9a-f]\{64\}\)")$/\1/p' "${PACSTALL_SCRIPT}")"
	[[ "${sum}" =~ ^[0-9a-f]{64}$ ]] \
		|| pacstall_fail "${PACSTALL_SCRIPT} should have exactly one sha256sums=(\"…\") line, and it has '${sum}'."
	printf '%s\n' "${sum}"
}

# sha256_of FILE — the file's SHA-256, lowercase hex, with no file name.
sha256_of() {
	openssl dgst -sha256 -r "$1" | awk '{ print $1 }'
}

# fetch_release_deb VERSION DEST — downloads the .deb the release VERSION
# carries to DEST, and checks it against the .sha256 published beside it. That
# checksum comes from the same release, so it catches a damaged download, not
# a replaced release.
fetch_release_deb() {
	local version="$1" dest="$2" published
	curl -fL --progress-bar -o "${dest}" "${PACSTALL_RELEASES}/v${version}/${PACSTALL_ASSET}" \
		|| pacstall_fail "could not download v${version}/${PACSTALL_ASSET}; is the release published?"
	published="$(curl -fsSL "${PACSTALL_RELEASES}/v${version}/${PACSTALL_ASSET}.sha256" | awk '{ print $1 }')" \
		|| pacstall_fail "could not download v${version}/${PACSTALL_ASSET}.sha256."
	[[ "$(sha256_of "${dest}")" == "${published}" ]] \
		|| pacstall_fail "v${version}/${PACSTALL_ASSET} does not match its published .sha256."
}

# lint_pacscript — shfmt and shellcheck, with the options pacstall-programs'
# .pre-commit-config.yaml and .shellcheckrc give them, in the tools image. A
# pacscript that fails here fails their pre-commit hook the same way.
lint_pacscript() {
	docker run -i --rm --platform linux/amd64 \
		-v "${REPO}/${PACSTALL_SCRIPT}:/work/${PACSTALL_PKG}.pacscript:ro" \
		"${PACSTALL_TOOLS_IMAGE}" bash -s -- "${PACSTALL_PKG}" << 'LINT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null
apt-get install -y -qq --no-install-recommends shfmt shellcheck > /dev/null
cd /work
shfmt -d -i 2 -bn -ci -sr -s "$1.pacscript"
shellcheck --enable=all --shell=bash \
	--exclude=SC2034,SC2103,SC2154,SC2164,SC2312 "$1.pacscript"
LINT
}
