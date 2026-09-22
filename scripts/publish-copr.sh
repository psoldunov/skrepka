#!/usr/bin/env bash
#
# Publishes the Fedora package on COPR, as <your COPR user>/skrepka:
#
#   scripts/publish-copr.sh 0.3.0            build the source RPM, upload it,
#                                            and wait for every chroot
#   scripts/publish-copr.sh 0.3.0 --dry-run  every check and the source RPM,
#                                            but nothing is created or uploaded
#
# Run it once the GitHub release is published, after scripts/pin-release.sh
# and scripts/test-copr.sh. It refuses to publish unless:
#
#   - VERSION is the one packaging/copr/skrepka.spec pins;
#   - the spec is committed exactly as it is on disk, so what COPR builds is
#     what the repository records;
#   - the release's tarball matches the .sha256 published beside it, and the
#     tag has a LICENSE to fetch.
#
# The source RPM is built here, the same way scripts/test-copr.sh builds it,
# and uploaded, rather than handing COPR a spec URL: the tested file is the
# published one, and a release tagged before the spec existed can still be
# published. It is about the size of the tarball, so each run uploads ~95 MB.
#
# copr-cli runs in a Fedora container, so nothing is installed on this
# machine. It reads the API token from ~/.config/copr, mounted read-only, or
# the file SKREPKA_COPR_CONFIG names; packaging/README.md says how to get one
# and how to renew it when it expires. The first run creates the project, for
# every Fedora COPR builds for, set to follow Fedora's branching so the next
# release gets a chroot of its own when it branches from rawhide.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO="$(pwd)"
# shellcheck source=scripts/lib/copr.sh
source scripts/lib/copr.sh

PROJECT="skrepka"
CHROOTS=(fedora-43-x86_64 fedora-44-x86_64 fedora-45-x86_64 fedora-rawhide-x86_64)
COPR_CLI_IMAGE="fedora:44"
CONFIG="${SKREPKA_COPR_CONFIG:-${HOME}/.config/copr}"

DESCRIPTION="Clipboard history for the Linux desktop, synced with your other \
machines and Macs over the local network. The x86_64 release of \
[Skrepka](https://github.com/psoldunov/skrepka), packaged for Fedora."
INSTRUCTIONS="\`sudo dnf copr enable OWNER/${PROJECT}\`, then \
\`sudo dnf install ${PROJECT}\`. Start Skrepka from the launcher once, or log \
out and back in. See [Install on Linux](https://github.com/psoldunov/skrepka#linux)."

VERSION=""
DRY_RUN=0
for argument in "$@"; do
	case "${argument}" in
		--dry-run) DRY_RUN=1 ;;
		-*) copr_fail "unknown option ${argument}" ;;
		*) VERSION="${argument}" ;;
	esac
done
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| copr_fail "usage: scripts/publish-copr.sh VERSION [--dry-run], with VERSION like 0.3.0"

# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

PINNED="$(spec_version)"
[[ "${PINNED}" == "${VERSION}" ]] \
	|| copr_fail "${COPR_SPEC} pins ${PINNED}, not ${VERSION}; run scripts/pin-release.sh ${VERSION} first."

if ! git ls-files --error-unmatch "${COPR_SPEC}" > /dev/null 2>&1 \
	|| ! git diff --quiet HEAD -- "${COPR_SPEC}"; then
	[[ "${DRY_RUN}" == 1 ]] || copr_fail "${COPR_SPEC} has changes that are not committed; commit it first."
	echo "note: ${COPR_SPEC} has uncommitted changes; a real run refuses to publish it."
fi

[[ -r "${CONFIG}" ]] \
	|| copr_fail "no COPR credentials at ${CONFIG}; packaging/README.md says how to get an API token."
if [[ -n "$(find "${CONFIG}" \( -perm -040 -o -perm -004 \) -print)" ]]; then
	echo "warning: ${CONFIG} is readable by other users; chmod 600 it, it holds your COPR API token." >&2
fi

copr_require_docker
fetch_sources "${VERSION}"
SRPM="$(build_srpm "${VERSION}")"

# --------------------------------------------------------------------------
# Publish
# --------------------------------------------------------------------------

if [[ "${DRY_RUN}" == 1 ]]; then
	copr_bold "Dry run: checking the COPR account, creating and uploading nothing"
else
	copr_bold "Publishing $(basename "${SRPM}") to COPR"
fi

# The script runs in the container; its arguments carry everything it needs.
docker run -i --rm --platform linux/amd64 \
	-v "${CONFIG}:/root/.config/copr:ro" \
	-v "${REPO}/${COPR_SRPMS}:/srpm:ro" \
	"${COPR_CLI_IMAGE}" \
	bash -s -- "${DRY_RUN}" "${PROJECT}" "/srpm/$(basename "${SRPM}")" \
	"${DESCRIPTION}" "${INSTRUCTIONS}" "${CHROOTS[@]}" << 'PUBLISH'
set -euo pipefail
dry_run="$1" project="$2" srpm="$3" description="$4" instructions="$5"
shift 5
chroots=("$@")
fail() {
	echo "error: $1" >&2
	exit 1
}

dnf -q -y install copr-cli > /tmp/dnf.log 2>&1 || {
	cat /tmp/dnf.log >&2
	fail "dnf could not install copr-cli."
}

owner="$(copr-cli whoami)" \
	|| fail "COPR refused the API token. It may have expired: get a new one at https://copr.fedorainfracloud.org/api/."
full="${owner}/${project}"
echo "COPR user: ${owner}"

if existing="$(copr-cli get "${full}" 2>&1)"; then
	echo "Project ${full} exists."
elif [[ "${existing}" == *"does not exist"* ]]; then
	create=(copr-cli create "${project}" --follow-fedora-branching on
		--description "${description}" --instructions "${instructions//OWNER/${owner}}")
	for chroot in "${chroots[@]}"; do
		create+=(--chroot "${chroot}")
	done
	if [[ "${dry_run}" == 1 ]]; then
		echo "Would create ${full} for ${chroots[*]}:"
		printf ' %q' "${create[@]}"
		echo
	else
		echo "Creating ${full} for ${chroots[*]}"
		"${create[@]}"
	fi
else
	fail "copr-cli get ${full} failed: ${existing}"
fi

# Waits for every chroot and exits 4 when any of them failed.
if [[ "${dry_run}" == 1 ]]; then
	echo "Would run: copr-cli build ${full} ${srpm}"
else
	copr-cli build "${full}" "${srpm}"
fi
echo "https://copr.fedorainfracloud.org/coprs/${full}/"
PUBLISH

if [[ "${DRY_RUN}" == 1 ]]; then
	copr_green "✓ dry run passed for ${VERSION}"
else
	copr_green "✓ skrepka ${VERSION} is built on COPR for ${CHROOTS[*]}"
fi
