#!/usr/bin/env bash
#
# Builds the .deb and the .rpm a GitHub release carries, from the stage
# scripts/build-deck.sh leaves in build/deck/skrepka-linux-x86_64/:
#
#   build/deck/skrepka-linux-x86_64.deb   Ubuntu 24.04+, Debian 13+
#   build/deck/skrepka-linux-x86_64.rpm   Fedora 39+, openSUSE Tumbleweed
#   a .sha256 beside each
#
#   scripts/build-packages.sh     after scripts/build-deck.sh, which runs it
#
# Nothing is compiled here. The packages carry the release tarball's own files,
# so they cannot drift from what install.sh installs: this script lays them out
# under build/deck/pkgroot the way a system install wants them — /usr/bin,
# /usr/lib/skrepka, /usr/lib/systemd/user, /usr/share, /etc/xdg/autostart — and
# nFPM, in its own container, packs that tree as packaging/nfpm.yaml maps it.
#
# The asset names carry no version for the reason the tarball's do not:
# /releases/latest/download/ only resolves a name that is the same in every
# release. The package version inside comes from the staged skrepkad itself.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO="$(pwd)"
NFPM_IMAGE="goreleaser/nfpm:v2.47.0"
STAGE_ROOT="build/deck"
STAGE="${STAGE_ROOT}/skrepka-linux-x86_64"
PKGROOT="${STAGE_ROOT}/pkgroot"
ASSET="${STAGE_ROOT}/skrepka-linux-x86_64"
EXTENSION_UUID="skrepka@dev.soldunov"
# The five files install.sh copies into the extension directory.
EXTENSION_FILES=(metadata.json extension.js dbus.js limits.js README.md)

bold() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
fail() {
	echo "error: $1" >&2
	exit 1
}

for binary in skrepkad skrepka skrepka-gui; do
	[[ -x "${STAGE}/bin/${binary}" ]] || fail "${STAGE}/bin/${binary} is missing; run scripts/build-deck.sh first."
done
[[ -f "${STAGE}/lib/libgtk4-layer-shell.so.0" ]] || fail "${STAGE}/lib/libgtk4-layer-shell.so.0 is missing."

if ! docker info > /dev/null 2>&1; then
	fail "docker is not reachable (OrbStack exposes it at ~/.orbstack/run/docker.sock)."
fi

# --------------------------------------------------------------------------
# Version: what the staged daemon says it is
# --------------------------------------------------------------------------

# Asked of the binary rather than read from DaemonVersion.swift, so a package
# can only ever claim the version of the build inside it. It is x86_64, so it
# runs in the amd64 image scripts/build-deck.sh just built with.
VERSION_LINE="$(SKREPKA_LINUX_ARCH=amd64 scripts/linux.sh "${STAGE}/bin/skrepkad" --version)"
VERSION="${VERSION_LINE#skrepkad }"
VERSION="${VERSION%%[[:space:]]*}"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "skrepkad --version printed '${VERSION_LINE}'."

# --------------------------------------------------------------------------
# Lay out the tree
# --------------------------------------------------------------------------

# replace_line FILE OUT FROM TO — FILE with its one line equal to FROM replaced
# by TO, written to OUT. Exactly one: a unit or service file whose line was
# renamed or duplicated is an error here, not a package with a stale path.
replace_line() {
	local file="$1" out="$2" from="$3" to="$4" count
	count="$(grep -Fxc -- "${from}" "${file}" || true)"
	[[ "${count}" == "1" ]] || fail "expected exactly one '${from}' line in ${file}, found ${count}."
	FROM="${from}" TO="${to}" awk '$0 == ENVIRON["FROM"] { print ENVIRON["TO"]; next } { print }' \
		"${file}" > "${out}"
}

bold "Laying out ${PKGROOT}"
rm -rf "${PKGROOT}"
mkdir -p \
	"${PKGROOT}/usr/bin" \
	"${PKGROOT}/usr/lib/skrepka" \
	"${PKGROOT}/usr/lib/systemd/user" \
	"${PKGROOT}/usr/share/dbus-1/services" \
	"${PKGROOT}/usr/share/applications" \
	"${PKGROOT}/usr/share/icons" \
	"${PKGROOT}/usr/share/gnome-shell/extensions/${EXTENSION_UUID}" \
	"${PKGROOT}/usr/share/doc/skrepka" \
	"${PKGROOT}/usr/share/licenses/skrepka" \
	"${PKGROOT}/etc/xdg/autostart"

cp "${STAGE}/bin/skrepkad" "${STAGE}/bin/skrepka" "${STAGE}/bin/skrepka-gui" "${PKGROOT}/usr/bin/"
# One regular file under the soname, as install.sh installs it: the tarball's
# .so and .so.0 are symlinks to the versioned file, and only the soname is
# ever looked up.
cp -L "${STAGE}/lib/libgtk4-layer-shell.so.0" "${PKGROOT}/usr/lib/skrepka/libgtk4-layer-shell.so.0"

# The unit ships pointing at ~/.local/bin and the D-Bus file at a bare name,
# both of which install.sh rewrites; a system install rewrites them to /usr/bin.
# The D-Bus specification wants an absolute Exec=.
replace_line "${STAGE}/packaging/systemd/skrepkad.service" \
	"${PKGROOT}/usr/lib/systemd/user/skrepkad.service" \
	"ExecStart=%h/.local/bin/skrepkad" "ExecStart=/usr/bin/skrepkad"
replace_line "${STAGE}/packaging/dbus/dev.soldunov.Skrepka.service" \
	"${PKGROOT}/usr/share/dbus-1/services/dev.soldunov.Skrepka.service" \
	"Exec=skrepkad" "Exec=/usr/bin/skrepkad"

# The launcher and autostart entries name skrepka-gui bare, which /usr/bin on
# every session's PATH resolves; install.sh rewrites them only because
# ~/.local/bin is not on every session's PATH.
cp "${STAGE}/packaging/desktop/dev.soldunov.Skrepka.App.desktop" "${PKGROOT}/usr/share/applications/"
cp "${STAGE}/packaging/autostart/dev.soldunov.Skrepka.App.desktop" "${PKGROOT}/etc/xdg/autostart/"
cp -R "${STAGE}/packaging/icons/hicolor" "${PKGROOT}/usr/share/icons/hicolor"

grep -Fq "\"uuid\": \"${EXTENSION_UUID}\"" "${STAGE}/gnome-extension/metadata.json" \
	|| fail "${STAGE}/gnome-extension/metadata.json does not declare ${EXTENSION_UUID}."
for file in "${EXTENSION_FILES[@]}"; do
	cp "${STAGE}/gnome-extension/${file}" "${PKGROOT}/usr/share/gnome-shell/extensions/${EXTENSION_UUID}/"
done

cp "${REPO}/LICENSE" "${PKGROOT}/usr/share/doc/skrepka/copyright"
cp "${REPO}/LICENSE" "${PKGROOT}/usr/share/licenses/skrepka/LICENSE"

# --------------------------------------------------------------------------
# Pack
# --------------------------------------------------------------------------

# nFPM is one static Go binary in a multi-arch image, so it runs natively on
# either host. Same bind mount and host-user mapping as scripts/linux.sh, so
# the packages land owned by whoever ran this.
pack() {
	local packager="$1" target="$2"
	bold "Packing ${target} (${packager}, version ${VERSION})"
	rm -f "${target}"
	docker run --rm \
		-u "$(id -u):$(id -g)" \
		-e "SKREPKA_VERSION=${VERSION}" \
		-v "${REPO}:${REPO}" \
		-w "${REPO}" \
		"${NFPM_IMAGE}" \
		package --config packaging/nfpm.yaml --packager "${packager}" --target "${target}"
	[[ -s "${target}" ]] || fail "nFPM wrote no ${target}."
}

pack deb "${ASSET}.deb"
pack rpm "${ASSET}.rpm"

# The same checksum format build-deck.sh writes beside the tarballs: the bare
# asset name, so `sha256sum -c` works from the directory both were downloaded to.
write_checksum() {
	local name
	name="$(basename "$1")"
	if command -v sha256sum > /dev/null 2>&1; then
		(cd "${STAGE_ROOT}" && sha256sum "${name}") > "$1.sha256"
	else
		(cd "${STAGE_ROOT}" && shasum -a 256 "${name}") > "$1.sha256"
	fi
}
write_checksum "${ASSET}.deb"
write_checksum "${ASSET}.rpm"

green "✓ ${ASSET}.deb ($(du -h "${ASSET}.deb" | awk '{print $1}'))"
green "✓ ${ASSET}.rpm ($(du -h "${ASSET}.rpm" | awk '{print $1}'))"
green "✓ a .sha256 beside each"
