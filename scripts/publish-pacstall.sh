#!/usr/bin/env bash
#
# Opens the pull request that puts packaging/pacstall/skrepka-deb.pacscript in
# Pacstall's repository, pacstall/pacstall-programs:
#
#   scripts/publish-pacstall.sh 0.3.0            fork, branch, commit, push,
#                                                and open the pull request
#   scripts/publish-pacstall.sh 0.3.0 --dry-run  every check and the commit,
#                                                but nothing is forked, pushed
#                                                or opened
#
# Run it once the GitHub release is published, after scripts/pin-release.sh
# and scripts/test-pacstall.sh. It refuses to publish unless:
#
#   - VERSION is the one the pacscript pins;
#   - the pacscript is committed exactly as it is on disk, so what Pacstall
#     ships is what this repository records;
#   - the release's .deb matches the .sha256 published beside it, and the
#     pacscript's hash.
#
# The first run's pull request is titled add: `skrepka-deb`; every later one
# upd(skrepka-deb): `old` -> `new`, the titles Pacstall's wiki asks for. Pacup,
# Pacstall's own updater, cannot open those for us: it finds new versions
# through Repology, and no repository Repology reads carries Skrepka.
#
# It works in its own clone of pacstall-programs under build/pacstall, with
# the upstream repository as origin and your fork, created on the first run,
# as `fork`. The branch is skrepka-deb-VERSION, recreated from upstream master
# on every run and force-pushed to the fork with a lease, so a second run for
# the same version replaces the first run's branch and updates its pull
# request rather than opening another. Nothing else is ever pushed.
#
# pacstall-programs' pre-commit hook runs shfmt, shellcheck and its own
# scripts/srcinfo.sh, which writes the .SRCINFO and rebuilds packagelist and
# srclist. This runs the same three in a Debian container, because srcinfo.sh
# wants a newer bash than macOS ships, and commits what they write.
#
# SKREPKA_PACSTALL_PR_NOTE is appended to the pull request's description:
# Pacstall's wiki asks for test output there when their CI cannot show it.
# SKREPKA_PACSTALL_TRAILERS, one per line, end the commit message.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO="$(pwd)"
# shellcheck source=scripts/lib/pacstall.sh
source scripts/lib/pacstall.sh

UPSTREAM="pacstall/pacstall-programs"
CHECKOUT="${PACSTALL_BUILD}/pacstall-programs"
PACKAGE_DIR="packages/${PACSTALL_PKG}"

VERSION=""
DRY_RUN=0
for argument in "$@"; do
	case "${argument}" in
		--dry-run) DRY_RUN=1 ;;
		-*) pacstall_fail "unknown option ${argument}" ;;
		*) VERSION="${argument}" ;;
	esac
done
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| pacstall_fail "usage: scripts/publish-pacstall.sh VERSION [--dry-run], with VERSION like 0.3.0"

programs() { git -C "${CHECKOUT}" "$@"; }

# pacscript_full_version FILE — pkgver, with -pkgrel when the file sets one.
pacscript_full_version() {
	local version release
	version="$(sed -n 's/^pkgver="\([^"]*\)"$/\1/p' "$1")"
	release="$(sed -n 's/^pkgrel="\([^"]*\)"$/\1/p' "$1")"
	printf '%s%s\n' "${version}" "${release:+-${release}}"
}

# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

PINNED="$(pacscript_version)"
[[ "${PINNED}" == "${VERSION}" ]] \
	|| pacstall_fail "${PACSTALL_SCRIPT} pins ${PINNED}, not ${VERSION}; run scripts/pin-release.sh ${VERSION} first."

if ! git ls-files --error-unmatch "${PACSTALL_SCRIPT}" > /dev/null 2>&1 \
	|| ! git diff --quiet HEAD -- "${PACSTALL_SCRIPT}"; then
	[[ "${DRY_RUN}" == 1 ]] || pacstall_fail "${PACSTALL_SCRIPT} has changes that are not committed; commit it first."
	echo "note: ${PACSTALL_SCRIPT} has uncommitted changes; a real run refuses to publish it."
fi

gh auth status > /dev/null 2>&1 || pacstall_fail "gh is not logged in; run gh auth login."
OWNER="$(gh api user --jq .login)"

pacstall_require_docker

pacstall_bold "Checking the v${VERSION} .deb against the pacscript"
mkdir -p "${PACSTALL_BUILD}"
DEB="${PACSTALL_BUILD}/${PACSTALL_ASSET%.deb}-${VERSION}.deb"
fetch_release_deb "${VERSION}" "${DEB}"
[[ "$(sha256_of "${DEB}")" == "$(pacscript_sha256)" ]] \
	|| pacstall_fail "the v${VERSION} .deb is not the one ${PACSTALL_SCRIPT} pins; run scripts/pin-release.sh ${VERSION}."
echo "  $(pacscript_sha256)"

# --------------------------------------------------------------------------
# The branch
# --------------------------------------------------------------------------

pacstall_bold "Branching from ${UPSTREAM} master in ${CHECKOUT}"
if [[ ! -d "${CHECKOUT}/.git" ]]; then
	git clone --quiet --filter=blob:none "https://github.com/${UPSTREAM}.git" "${CHECKOUT}"
fi
programs fetch --quiet origin master
BRANCH="${PACSTALL_PKG}-${VERSION}"
# The clone is this script's alone, so whatever an interrupted run left in it
# is discarded with the old branch.
programs checkout --quiet --force -B "${BRANCH}" origin/master

PUBLISHED="${CHECKOUT}/${PACKAGE_DIR}/${PACSTALL_PKG}.pacscript"
if [[ -f "${PUBLISHED}" ]]; then
	OLD="$(pacscript_full_version "${PUBLISHED}")"
	NEW="$(pacscript_full_version "${PACSTALL_SCRIPT}")"
	if cmp -s "${PUBLISHED}" "${PACSTALL_SCRIPT}"; then
		pacstall_green "✓ ${UPSTREAM} already carries this pacscript, ${OLD}; nothing to publish."
		exit 0
	fi
	[[ "${OLD}" != "${NEW}" ]] \
		|| pacstall_fail "${UPSTREAM} has a different ${OLD} pacscript; bump pkgrel for a pacscript-only fix."
	TITLE="upd(${PACSTALL_PKG}): \`${OLD}\` -> \`${NEW}\`"
	BODY="Skrepka ${VERSION}: https://github.com/psoldunov/skrepka/releases/tag/v${VERSION}"
else
	TITLE="add: \`${PACSTALL_PKG}\`"
	BODY="## Progress

- [x] Edit packagelist
- [x] Add initial pacscript
- [x] Add maintainer to pacscript

[Skrepka](https://github.com/psoldunov/skrepka) is a clipboard history manager for the Linux desktop and macOS: it records what you copy, opens a searchable picker on a global shortcut, and syncs history with paired machines over the local network.

\`${PACSTALL_PKG}\` installs the \`.deb\` each GitHub release carries, unchanged. It needs glibc 2.38 and GTK 4.12, so it is incompatible with jammy and bookworm. The pacscript is maintained in Skrepka's repository, in [\`packaging/pacstall/\`](https://github.com/psoldunov/skrepka/tree/master/packaging/pacstall), where each release pins it and a container test installs it with Pacstall."
fi
[[ -z "${SKREPKA_PACSTALL_PR_NOTE:-}" ]] || BODY="${BODY}

${SKREPKA_PACSTALL_PR_NOTE}"

mkdir -p "${CHECKOUT}/${PACKAGE_DIR}"
cp "${PACSTALL_SCRIPT}" "${PUBLISHED}"

pacstall_bold "Running pacstall-programs' pre-commit checks in ${PACSTALL_TOOLS_IMAGE}"
docker run -i --rm --platform linux/amd64 \
	-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
	-v "${REPO}/${CHECKOUT}:/programs" \
	"${PACSTALL_TOOLS_IMAGE}" bash -s -- "${PACKAGE_DIR}/${PACSTALL_PKG}.pacscript" << 'PRECOMMIT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null
apt-get install -y -qq --no-install-recommends git shfmt shellcheck > /dev/null
git config --global --add safe.directory /programs
cd /programs
shfmt -d -i 2 -bn -ci -sr -s "$1"
# Their .shellcheckrc, at the root of the clone, applies.
shellcheck "$1"
./scripts/srcinfo.sh write "$1"
LC_ALL=C ./scripts/srcinfo.sh build packagelist
LC_ALL=C ./scripts/srcinfo.sh build srclist
chown -R "${HOST_UID}:${HOST_GID}" /programs
PRECOMMIT

programs add -- "${PACKAGE_DIR}" packagelist srclist
CHANGED="$(programs status --porcelain)"
# grep exits 1 when every change is an expected one, which is the good case.
UNEXPECTED="$(grep -Ev "^[AM]  (${PACKAGE_DIR}/|packagelist$|srclist$)" <<< "${CHANGED}")" \
	|| [[ $? == 1 ]] || pacstall_fail "could not read the clone's git status."
[[ -z "${UNEXPECTED}" ]] || pacstall_fail "the pre-commit checks changed more than ${PACSTALL_PKG}:
${UNEXPECTED}"

MESSAGE="${TITLE}"
[[ -z "${SKREPKA_PACSTALL_TRAILERS:-}" ]] || MESSAGE="${MESSAGE}

${SKREPKA_PACSTALL_TRAILERS}"
programs commit --quiet -m "${MESSAGE}"
programs show --stat --format='%s' HEAD

if [[ "${DRY_RUN}" == 1 ]]; then
	echo
	echo "Dry run: would push ${BRANCH} to ${OWNER}/pacstall-programs and open"
	echo "  ${TITLE}"
	echo "against ${UPSTREAM}. The commit is in ${CHECKOUT}."
	exit 0
fi

# --------------------------------------------------------------------------
# Fork, push, open
# --------------------------------------------------------------------------

FORK="${OWNER}/pacstall-programs"
if ! gh repo view "${FORK}" > /dev/null 2>&1; then
	pacstall_bold "Forking ${UPSTREAM} to ${FORK}"
	gh repo fork "${UPSTREAM}" --clone=false --default-branch-only
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		gh repo view "${FORK}" > /dev/null 2>&1 && break
		sleep 3
	done
fi
if [[ "$(gh config get git_protocol 2> /dev/null)" == ssh ]]; then
	FORK_URL="git@github.com:${FORK}.git"
else
	FORK_URL="https://github.com/${FORK}.git"
fi
if programs remote get-url fork > /dev/null 2>&1; then
	programs remote set-url fork "${FORK_URL}"
else
	programs remote add fork "${FORK_URL}"
fi

# The lease names what the fork's branch holds right now, or nothing when
# there is no such branch yet, so the push replaces only this script's own
# earlier run of the same version.
pacstall_bold "Pushing ${BRANCH} to ${FORK}"
LEASE="$(programs ls-remote fork "refs/heads/${BRANCH}" | awk '{ print $1 }')"
programs push --quiet --force-with-lease="refs/heads/${BRANCH}:${LEASE}" fork "${BRANCH}"

EXISTING="$(gh pr list --repo "${UPSTREAM}" --head "${BRANCH}" --author "${OWNER}" --state open --json url --jq '.[0].url // empty')"
if [[ -n "${EXISTING}" ]]; then
	pacstall_green "✓ updated ${EXISTING}"
else
	URL="$(gh pr create --repo "${UPSTREAM}" --base master --head "${OWNER}:${BRANCH}" \
		--title "${TITLE}" --body "${BODY}")"
	pacstall_green "✓ opened ${URL}"
fi
