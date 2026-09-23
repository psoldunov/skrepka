#!/usr/bin/env bash
#
# Installs packaging/pacstall/skrepka-deb.pacscript with Pacstall in a clean
# container of each Ubuntu and Debian it supports, the way pacstall-programs'
# own CI does, and checks what it installed.
#
#   scripts/test-pacstall.sh     the release the pacscript's pkgver names
#   SKREPKA_DEB=build/deck/skrepka-linux-x86_64.deb scripts/test-pacstall.sh
#                                an unreleased build, before it is published
#
# Publishes nothing. First it runs shfmt and shellcheck as pacstall-programs'
# pre-commit hook does. Then, in each image, it installs Pacstall through its
# own installer, runs `pacstall -PI` on the pacscript and checks that apt
# resolved every dependency, that the three binaries run and find every
# library — libgtk4-layer-shell from the .deb's private copy — and that the
# unit and the D-Bus file point at /usr/bin. `pacstall -PR` must then remove it
# all. Last, Ubuntu 22.04, whose glibc is older than the build's, must be
# refused by the pacscript's `incompatible` before anything is downloaded.
#
# SKREPKA_DEB swaps the pacscript's source for a file:// one, and its hash for
# that file's; everything else is the committed pacscript.
#
# Where Pacstall's sandbox, bubblewrap, cannot run at all — Debian 13's under
# OrbStack's Rosetta translation of amd64 — the install goes without it, and
# that image's result line says so.
#
# SKREPKA_PACSTALL_TEST_IMAGES overrides the images, space-separated, and
# SKREPKA_PACSTALL_REFUSE_IMAGE the one that must refuse; empty skips it.

set -euo pipefail

# Relative to where this was run, before the cd below moves that.
DEB="${SKREPKA_DEB:-}"
[[ -z "${DEB}" || "${DEB}" == /* ]] || DEB="$(pwd)/${DEB}"

cd "$(dirname "$0")/.."

REPO="$(pwd)"
# shellcheck source=scripts/lib/pacstall.sh
source scripts/lib/pacstall.sh

read -r -a TEST_IMAGES <<< "${SKREPKA_PACSTALL_TEST_IMAGES:-ubuntu:26.04 debian:13}"
REFUSE_IMAGE="${SKREPKA_PACSTALL_REFUSE_IMAGE-ubuntu:22.04}"
STAGE="${PACSTALL_BUILD}/test"

pacstall_require_docker

VERSION="$(pacscript_version)"

# --------------------------------------------------------------------------
# Lint, as pacstall-programs' pre-commit hook does
# --------------------------------------------------------------------------

pacstall_bold "Linting ${PACSTALL_SCRIPT} in ${PACSTALL_TOOLS_IMAGE}"
lint_pacscript
echo "  shfmt and shellcheck are clean"

# --------------------------------------------------------------------------
# Stage the pacscript the containers install
# --------------------------------------------------------------------------

mkdir -p "${STAGE}"
rm -f "${STAGE}/${PACSTALL_PKG}.pacscript" "${STAGE}/${PACSTALL_ASSET}"
if [[ -n "${DEB}" ]]; then
	[[ -s "${DEB}" ]] || pacstall_fail "${DEB} is missing or empty."
	pacscript_sha256 > /dev/null
	cp "${DEB}" "${STAGE}/${PACSTALL_ASSET}"
	DEB_SHA="$(sha256_of "${DEB}")"
	SOURCE="file:///work/${PACSTALL_ASSET}"
	# One line each, as pacscript_version and pacscript_sha256 have checked,
	# so the rewrite cannot miss or double up.
	SOURCE="${SOURCE}" DEB_SHA="${DEB_SHA}" awk '
		/^source=\(/ { print "source=(\"" ENVIRON["SOURCE"] "\")"; next }
		/^sha256sums=\(/ { print "sha256sums=(\"" ENVIRON["DEB_SHA"] "\")"; next }
		{ print }' "${PACSTALL_SCRIPT}" > "${STAGE}/${PACSTALL_PKG}.pacscript"
	echo "Testing ${DEB} (${DEB_SHA:0:12}…) under the pinned pkgver ${VERSION}."
else
	cp "${PACSTALL_SCRIPT}" "${STAGE}/${PACSTALL_PKG}.pacscript"
	echo "Testing the published v${VERSION} .deb the pacscript names."
fi

# run_in IMAGE MODE — a fresh IMAGE with a sudo user and Pacstall installed as
# pacstall-programs' tests.yml installs it, then MODE: `install` installs,
# checks and removes the pacscript; `refuse` expects it to be refused. Pacstall
# refuses to run as root, and its build sandbox wants --privileged, as there.
run_in() {
	local image="$1" mode="$2"
	docker run -i --rm --platform linux/amd64 --privileged \
		-e TERM=xterm -e USER=tester -e LOGNAME=tester -e SUDO_USER=tester \
		-v "${REPO}/${STAGE}:/work:ro" \
		"${image}" bash -s -- "${VERSION}" "${PACSTALL_PKG}" "${mode}" << 'CHECK'
set -euo pipefail
version="$1" pkg="$2" mode="$3"
distro="$(. /etc/os-release && echo "${PRETTY_NAME}")"
fail() {
	echo "error: ${distro}: $1" >&2
	exit 1
}
trap 'echo "error: ${distro}: line ${LINENO} exited $?" >&2' ERR
# Its stdin is not this script's: bash reads the script from stdin, so a
# command reading stdin would eat the lines after it.
as_tester() {
	sudo -E -u tester bash -c "$1" < /dev/null
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null
apt-get install -y -qq --no-install-recommends \
	apt-utils bash ca-certificates curl desktop-file-utils git lsb-release sudo wget \
	> /tmp/apt.log 2>&1 || { tail -30 /tmp/apt.log >&2; fail "apt could not install Pacstall's prerequisites."; }
useradd --create-home --home-dir /home/tester --shell /bin/bash --groups sudo tester
echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester
chmod -R 777 /tmp

as_tester "cd /tmp && curl -fsSL 'https://pacstall.dev/q/install?dnt' -o pacstall-install.sh \
	&& chmod +x pacstall-install.sh && printf 'N\n' | sudo ./pacstall-install.sh" \
	> /tmp/pacstall-install.log 2>&1 \
	|| { tail -30 /tmp/pacstall-install.log >&2; fail "Pacstall's installer failed."; }
# Whole outputs, then matched: under pipefail, a reader that stops early
# (head, grep -q) would fail the writer with SIGPIPE. Pacstall warns on stderr
# whenever stdin is not a terminal, so these two leave stderr out.
pacstall_version="$(as_tester 'pacstall -V' 2> /dev/null)"
pacstall_version="$(sed -n '1s/\x1b\[[0-9;]*m//g; 1s/ *$//p' <<< "${pacstall_version}")"
listed() {
	grep -Fxq "${pkg}" <<< "$(as_tester 'pacstall -L' 2> /dev/null)"
}

# Pacstall sources a pacscript inside bubblewrap. Debian 13's bubblewrap 0.12
# cannot mount anything under Rosetta's amd64 translation, OrbStack's default
# on Apple silicon ("Can't open source /: Function not implemented"), where
# Ubuntu's 0.11 can, and a real x86_64 machine has no such gap. Only there does
# the test go without the sandbox, and it says so.
install="pacstall -PI"
sandbox=""
if ! bwrap --ro-bind / / --proc /proc --dev /dev true 2> /tmp/bwrap.log; then
	grep -q 'Function not implemented' /tmp/bwrap.log || {
		cat /tmp/bwrap.log >&2
		fail "bwrap, Pacstall's sandbox, cannot run here."
	}
	install="pacstall -P -Ns -I"
	sandbox=", without Pacstall's sandbox, which cannot run under this CPU translation"
fi

if [[ "${mode}" == refuse ]]; then
	if as_tester "${install} /work/${pkg}.pacscript" > /tmp/pacstall.log 2>&1; then
		fail "Pacstall installed ${pkg}, which should be incompatible here."
	fi
	grep -q 'This Pacscript does not work on' /tmp/pacstall.log || {
		tail -30 /tmp/pacstall.log >&2
		fail "Pacstall failed, but not because the pacscript is incompatible."
	}
	! dpkg-query -W skrepka > /dev/null 2>&1 || fail "skrepka is installed after a refusal."
	echo "✓ ${distro}: refused by incompatible (Pacstall ${pacstall_version}${sandbox})"
	exit 0
fi

as_tester "${install} /work/${pkg}.pacscript" > /tmp/pacstall.log 2>&1 \
	|| { tail -40 /tmp/pacstall.log >&2; fail "${install} ${pkg}.pacscript failed."; }
listed || fail "pacstall -L does not list ${pkg}."
installed="$(dpkg-query -W -f='${Version}' skrepka)"
[[ "${installed}" == "${version}-"* ]] || fail "dpkg says skrepka ${installed}, not ${version}."

daemon_version="$(skrepkad --version)"
[[ "${daemon_version}" == "skrepkad ${version}"* ]] || fail "skrepkad --version printed '${daemon_version}'."
# The CLI has no --version; help exercises the same startup. skrepka-gui's
# --help prints its usage before GTK is touched, so it needs no display.
skrepka help > /dev/null || fail "skrepka help failed."
skrepka-gui --help > /dev/null || fail "skrepka-gui --help failed."

# grep exits 1 when no library is missing, the good case.
missing="$(ldd /usr/bin/skrepkad /usr/bin/skrepka /usr/bin/skrepka-gui | grep 'not found')" \
	|| [[ $? == 1 ]] || fail "ldd could not read the binaries."
[[ -z "${missing}" ]] || fail "unresolved libraries:
${missing}"
layer_shell="$(ldd /usr/bin/skrepka-gui | awk '$1 == "libgtk4-layer-shell.so.0" { print $3 }')"
[[ "$(readlink -f "${layer_shell}")" == /usr/lib/skrepka/libgtk4-layer-shell.so.0 ]] \
	|| fail "skrepka-gui loads libgtk4-layer-shell from '${layer_shell}', not the .deb's /usr/lib/skrepka."

grep -Fxq 'ExecStart=/usr/bin/skrepkad' /usr/lib/systemd/user/skrepkad.service \
	|| fail "the user unit does not start /usr/bin/skrepkad."
grep -Fxq 'Exec=/usr/bin/skrepkad' /usr/share/dbus-1/services/dev.soldunov.Skrepka.service \
	|| fail "the D-Bus activation file does not start /usr/bin/skrepkad."
for path in \
	/usr/share/applications/dev.soldunov.Skrepka.App.desktop \
	/etc/xdg/autostart/dev.soldunov.Skrepka.App.desktop \
	/usr/share/icons/hicolor/256x256/apps/dev.soldunov.Skrepka.App.png \
	/usr/share/icons/hicolor/scalable/status/skrepka-tray.svg \
	/usr/share/gnome-shell/extensions/skrepka@dev.soldunov/metadata.json \
	/usr/share/doc/skrepka/copyright; do
	[[ -s "${path}" ]] || fail "${path} is missing."
done
desktop-file-validate /usr/share/applications/dev.soldunov.Skrepka.App.desktop \
	|| fail "the launcher entry does not validate."
dpkg --verify skrepka || fail "dpkg --verify skrepka reports modified files."

as_tester "pacstall -PR ${pkg}" > /tmp/pacstall-remove.log 2>&1 \
	|| { tail -30 /tmp/pacstall-remove.log >&2; fail "pacstall -PR ${pkg} failed."; }
[[ ! -e /usr/bin/skrepkad ]] || fail "pacstall -PR ${pkg} left /usr/bin/skrepkad behind."
! listed || fail "pacstall -L still lists ${pkg} after removal."

echo "✓ ${distro}: skrepka ${installed}, ${daemon_version}, installed and removed by Pacstall ${pacstall_version}${sandbox}"
CHECK
}

for image in "${TEST_IMAGES[@]}"; do
	pacstall_bold "Installing ${PACSTALL_PKG} with Pacstall in ${image}"
	run_in "${image}" install
done

if [[ -n "${REFUSE_IMAGE}" ]]; then
	pacstall_bold "Expecting ${REFUSE_IMAGE} to refuse ${PACSTALL_PKG}"
	run_in "${REFUSE_IMAGE}" refuse
fi

pacstall_green "✓ ${PACSTALL_PKG} ${VERSION} installs, runs and removes with Pacstall on ${TEST_IMAGES[*]}"
