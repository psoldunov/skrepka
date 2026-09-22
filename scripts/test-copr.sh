#!/usr/bin/env bash
#
# Builds the COPR package from packaging/copr/skrepka.spec the way COPR does —
# a source RPM, then a binary one rebuilt from it — and installs it in a clean
# container of every Fedora the COPR project builds for.
#
#   scripts/test-copr.sh      the release the spec's Version names
#   SKREPKA_TARBALL=build/deck/skrepka-linux-x86_64.tar.gz scripts/test-copr.sh
#                             an unreleased build, before it is published
#
# Needs no COPR account and publishes nothing. In each Fedora it checks that
# dnf resolves every dependency, that the three binaries run and find every
# library — gtk4-layer-shell from Fedora, not a bundled copy — and that the
# unit and the D-Bus file point at /usr/bin. On one of them it then upgrades
# the GitHub release's .rpm to this package, the path a user who installed
# that one takes when they enable the COPR repository: this build's release
# carries a dist tag, so it sorts above the GitHub package's plain one.
#
# SKREPKA_COPR_TEST_IMAGES overrides the Fedoras, space-separated.

set -euo pipefail

# Relative to where this was run, before the cd below moves that.
TARBALL="${SKREPKA_TARBALL:-}"
[[ -z "${TARBALL}" || "${TARBALL}" == /* ]] || TARBALL="$(pwd)/${TARBALL}"

cd "$(dirname "$0")/.."

REPO="$(pwd)"
# shellcheck source=scripts/lib/copr.sh
source scripts/lib/copr.sh

COPR_RPMS="${COPR_BUILD}/rpms"
read -r -a TEST_IMAGES <<< "${SKREPKA_COPR_TEST_IMAGES:-fedora:43 fedora:44 fedora:45 fedora:rawhide}"
UPGRADE_IMAGE="fedora:44"

copr_require_docker

VERSION="$(spec_version)"
fetch_sources "${VERSION}" "${TARBALL}"
SRPM="$(build_srpm "${VERSION}")"

# --------------------------------------------------------------------------
# Rebuild, as COPR does, and lint
# --------------------------------------------------------------------------

copr_bold "Rebuilding the binary RPM from $(basename "${SRPM}") in ${COPR_BUILD_IMAGE}"
rm -rf "${COPR_RPMS}"
mkdir -p "${COPR_RPMS}"
in_build_image "
rpmbuild --rebuild --define '_rpmdir ${REPO}/${COPR_RPMS}' '${SRPM}' > /tmp/rpmbuild.log 2>&1 \
	|| { tail -40 /tmp/rpmbuild.log >&2; exit 1; }
grep -A5 'RPM build warnings' /tmp/rpmbuild.log || true
# rpmlint exits non-zero for warnings too, so its summary line decides:
# errors fail the test, warnings are only printed. skrepka.rpmlintrc filters
# the findings accepted on purpose, and says why.
rpmlint -r packaging/copr/skrepka.rpmlintrc '${SRPM}' '${REPO}/${COPR_RPMS}'/x86_64/*.rpm \\
	| tee /tmp/rpmlint.log || true
grep -Eq ' 0 errors' /tmp/rpmlint.log
chown -R \"\${HOST_UID}:\${HOST_GID}\" '${COPR_RPMS}'"

RPM_PATH="$(find "${COPR_RPMS}/x86_64" -name "skrepka-${VERSION}-*.x86_64.rpm" | head -1)"
[[ -s "${RPM_PATH}" ]] || copr_fail "rpmbuild wrote no binary RPM under ${COPR_RPMS}/x86_64."
RPM_NAME="$(basename "${RPM_PATH}")"

# --------------------------------------------------------------------------
# Install and check, in every Fedora
# --------------------------------------------------------------------------

# check_installed IMAGE [GITHUB_RPM] — installs RPM_NAME in a fresh IMAGE and
# checks it. With GITHUB_RPM, an absolute path, that is installed first and
# RPM_NAME upgrades it.
check_installed() {
	local image="$1" github_rpm="${2:-}"
	local mounts=(-v "${REPO}/${COPR_RPMS}/x86_64:/rpms:ro")
	[[ -n "${github_rpm}" ]] && mounts+=(-v "${github_rpm}:/github.rpm:ro")
	docker run -i --rm --platform linux/amd64 "${mounts[@]}" "${image}" \
		bash -s -- "${VERSION}" "${RPM_NAME}" "${github_rpm:+/github.rpm}" << 'CHECK'
set -euo pipefail
version="$1" rpm_name="$2" github_rpm="$3"
fedora="Fedora $(rpm -E %fedora)"
fail() {
	echo "error: ${fedora}: $1" >&2
	exit 1
}
install_rpm() {
	dnf -y install "$1" > /tmp/dnf.log 2>&1 || {
		tail -30 /tmp/dnf.log >&2
		fail "dnf could not install $1"
	}
}

if [[ -n "${github_rpm}" ]]; then
	install_rpm "${github_rpm}"
	[[ -f /usr/lib/skrepka/libgtk4-layer-shell.so.0 ]] || fail "the GitHub .rpm installed no private libgtk4-layer-shell."
	before="$(rpm -q skrepka)"
fi
install_rpm "/rpms/${rpm_name}"
installed="$(rpm -q skrepka)"
[[ "${installed}.rpm" == "${rpm_name}" ]] || fail "rpm -q skrepka says ${installed}, not ${rpm_name%.rpm}."
if [[ -n "${github_rpm}" ]]; then
	[[ ! -e /usr/lib/skrepka ]] || fail "the upgrade left /usr/lib/skrepka behind."
	echo "  upgraded ${before} → ${installed}"
fi

[[ "$(skrepkad --version)" == "skrepkad ${version}"* ]] || fail "skrepkad --version printed '$(skrepkad --version)'."
# The CLI has no --version; help exercises the same startup. skrepka-gui's
# --help prints its usage before GTK is touched, so it needs no display.
skrepka help > /dev/null || fail "skrepka help failed."
skrepka-gui --help > /dev/null || fail "skrepka-gui --help failed."

missing="$(ldd /usr/bin/skrepkad /usr/bin/skrepka /usr/bin/skrepka-gui | grep 'not found' || true)"
[[ -z "${missing}" ]] || fail "unresolved libraries:
${missing}"
# ldd names it by the path the loader searched — /lib64 on Fedora, a symlink
# to /usr/lib64 — so the owning package, not the path, is the check.
layer_shell="$(ldd /usr/bin/skrepka-gui | awk '$1 == "libgtk4-layer-shell.so.0" { print $3 }')"
owner="$(rpm -qf --qf '%{NAME}\n' "$(readlink -f "${layer_shell}")" 2>&1 || true)"
[[ "${owner}" == "gtk4-layer-shell" ]] \
	|| fail "skrepka-gui loads libgtk4-layer-shell from '${layer_shell}', owned by '${owner}', not Fedora's gtk4-layer-shell."

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
	/usr/share/licenses/skrepka/LICENSE; do
	[[ -s "${path}" ]] || fail "${path} is missing."
done
rpm -V skrepka || fail "rpm -V skrepka reports modified files."

echo "✓ ${fedora}: ${installed}, $(skrepkad --version)"
CHECK
}

for image in "${TEST_IMAGES[@]}"; do
	copr_bold "Installing ${RPM_NAME} in ${image}"
	check_installed "${image}"
done

# The GitHub release's .rpm to upgrade from: the one scripts/build-deck.sh left
# beside SKREPKA_TARBALL, or the published one.
if [[ -n "${TARBALL}" ]]; then
	GITHUB_RPM="${TARBALL%.tar.gz}.rpm"
	[[ -s "${GITHUB_RPM}" ]] || GITHUB_RPM=""
else
	GITHUB_RPM="${REPO}/${COPR_SOURCES}/${COPR_ASSET}-${VERSION}.rpm"
	if [[ ! -s "${GITHUB_RPM}" ]]; then
		curl -fL --progress-bar -o "${GITHUB_RPM}" "${COPR_RELEASES}/v${VERSION}/${COPR_ASSET}.rpm" \
			|| GITHUB_RPM=""
	fi
fi
if [[ -n "${GITHUB_RPM}" ]]; then
	copr_bold "Upgrading the GitHub .rpm to ${RPM_NAME} in ${UPGRADE_IMAGE}"
	check_installed "${UPGRADE_IMAGE}" "${GITHUB_RPM}"
else
	echo "No GitHub .rpm for v${VERSION} to upgrade from; skipped the upgrade check."
fi

copr_green "✓ ${RPM_NAME} installs and runs on ${TEST_IMAGES[*]}"
