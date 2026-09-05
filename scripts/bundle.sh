#!/usr/bin/env bash
#
# Assembles and signs build/Skrepka.app from the SwiftPM executable.
#
# SwiftPM cannot emit an .app bundle (its only product kinds are library,
# executable and plugin), so the bundle is assembled by hand.
#
# Signing uses a Developer ID identity on purpose. An ad-hoc signature pins the
# designated requirement to the binary's cdhash, which changes on every source
# edit, so TCC treats each rebuild as a new app and the Accessibility grant is
# re-prompted every single build. A Developer ID requirement names only the
# bundle id and team, so the grant survives rebuilds.
#
# SwiftPM resource bundles cannot be made to work inside a signed .app, and the
# warning below is the honest report of that. The accessor SwiftPM generates for
# `Bundle.module` probes exactly two paths and then calls fatalError --
#
#   Bundle.main.bundleURL/<Package>_<Target>.bundle    # = Skrepka.app/<...>.bundle
#   /absolute/path/to/.build/<triple>/<config>/<...>.bundle
#
# `Bundle.main.bundleURL` is the .app itself (measured, not assumed), so the
# first path is the bundle ROOT, beside Contents/ -- and codesign refuses to
# seal anything there: "unsealed contents present in the bundle root". That was
# tried three ways: a plain copy, signing the nested bundle before the app, and
# a symlink into Contents/Resources. All three fail the same way. The second
# path is the build machine's own .build, which is why the missing copy went
# unnoticed here and crashed on every other Mac -- KeyboardShortcuts.Recorder
# trapped in Bundle.module the moment Settings opened.
#
# So no resource bundle is shipped, and Skrepka reaches none: the one dependency
# that has resources, KeyboardShortcuts, is used for hotkey registration and
# storage only. Its Recorder and `Shortcut.description` both go through
# Bundle.module, and Sources/Skrepka/Settings/ShortcutRecorderView.swift and
# Sources/Skrepka/Platform/ShortcutFormatter.swift replace them.

set -euo pipefail

cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="Skrepka"
CONFIGURATION="${CONFIGURATION:-release}"
APP="build/${APP_NAME}.app"
SIGN_IDENTITY="${SKREPKA_SIGN_IDENTITY:-Developer ID Application: Philipp Soldunov (MSU5X4VMMP)}"

# Architecture. The edit loop builds for this Mac only; SKREPKA_UNIVERSAL=1 asks
# for the arm64 + x86_64 binary that a build leaving the machine needs, and
# scripts/notarize.sh sets it.
#
# Only four Intel Macs run macOS 26 at all -- the 2019 Mac Pro, the 2019 16-inch
# MacBook Pro, the 2020 13-inch MacBook Pro with four Thunderbolt 3 ports and
# the 2020 27-inch iMac -- and 26 is the last release that supports any of them.
# A small set, but an arm64-only .app does not launch on one, and the recipient
# sees a Finder error rather than anything this app can explain.
#
# The array is always populated because /usr/bin/env bash here is bash 3.2,
# where "${EMPTY[@]}" under `set -u` is an unbound-variable error. Naming the
# host arch explicitly is free: `--arch $(uname -m)` resolves to the same
# .build/<triple>/<config> bin path as passing nothing, so the incremental
# cache that scripts/setup.sh warms is untouched (measured with
# `swift build --show-bin-path`, both ways).
if [[ "${SKREPKA_UNIVERSAL:-0}" == "1" ]]; then
	ARCHITECTURES=(arm64 x86_64)
else
	ARCHITECTURES=("$(uname -m)")
fi

ARCHITECTURE_ARGUMENTS=()
for architecture in "${ARCHITECTURES[@]}"; do
	ARCHITECTURE_ARGUMENTS+=(--arch "${architecture}")
done

echo "▸ Building (${CONFIGURATION}, ${ARCHITECTURES[*]})"
swift build -c "${CONFIGURATION}" "${ARCHITECTURE_ARGUMENTS[@]}"
BIN_PATH="$(swift build -c "${CONFIGURATION}" \
	"${ARCHITECTURE_ARGUMENTS[@]}" --show-bin-path)/${APP_NAME}"

if [[ ! -x "${BIN_PATH}" ]]; then
	echo "error: executable not found at ${BIN_PATH}" >&2
	exit 1
fi

# Every slice this asked for has to actually be in the file. The x86_64 one is
# the slice nobody here can launch, so a build that silently produced only
# arm64 would pass every other check in this script, notarize, and then fail on
# the one Mac it was built for.
BUILT_SLICES="$(lipo -archs "${BIN_PATH}")"
for architecture in "${ARCHITECTURES[@]}"; do
	if [[ " ${BUILT_SLICES} " != *" ${architecture} "* ]]; then
		echo "error: ${BIN_PATH} has no ${architecture} slice (found: ${BUILT_SLICES})." >&2
		exit 1
	fi
done

echo "▸ Assembling ${APP}"
if [[ -d "${APP}" ]]; then
	chmod -R u+w "${APP}"
	find "${APP}" -mindepth 1 -delete
	rmdir "${APP}"
fi
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_PATH}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Bundled resources (app icon, and anything else dropped in Resources).
if compgen -G "Sources/${APP_NAME}/Resources/*" > /dev/null; then
	cp -R Sources/"${APP_NAME}"/Resources/* "${APP}/Contents/Resources/"
fi

# SwiftPM resource bundles are deliberately NOT copied in: no placement both
# resolves and signs (see the header). Naming them here is the standing warning
# that any new code reaching Bundle.module will trap off this machine.
BIN_DIR="$(dirname "${BIN_PATH}")"
if compgen -G "${BIN_DIR}/*.bundle" > /dev/null; then
	for resource_bundle in "${BIN_DIR}"/*.bundle; do
		echo "warning: $(basename "${resource_bundle}") cannot be shipped; do not use its Bundle.module." >&2
	done
fi

echo "▸ Signing as: ${SIGN_IDENTITY}"
if ! security find-identity -v -p codesigning | grep -qF "${SIGN_IDENTITY}"; then
	if [[ "${SKREPKA_NOTARIZE:-0}" == "1" ]]; then
		echo "error: '${SIGN_IDENTITY}' is not in the keychain." >&2
		echo "error: an ad-hoc signature cannot be notarized; refusing to build one." >&2
		exit 1
	fi
	echo "warning: identity not found, falling back to ad-hoc signing." >&2
	echo "warning: Accessibility permission will be re-prompted on every rebuild." >&2
	SIGN_IDENTITY="-"
fi

# A secure timestamp costs a network round-trip to Apple's timestamp server on
# every single build, so the edit loop does without one. Two things need it,
# and both only matter for a build that leaves this machine:
#
#   * The notary service rejects a submission with "The signature does not
#     include a secure timestamp."
#   * Gatekeeper accepts an expired Developer ID certificate only when a
#     trusted timestamp proves the signing happened while it was still valid.
#     Without one, every copy stops launching the day the certificate expires.
#
# scripts/notarize.sh sets SKREPKA_NOTARIZE=1 and pays the round-trip.
if [[ "${SKREPKA_NOTARIZE:-0}" == "1" ]]; then
	TIMESTAMP_ARGUMENT=(--timestamp)
else
	TIMESTAMP_ARGUMENT=(--timestamp=none)
fi

codesign --force --options runtime "${TIMESTAMP_ARGUMENT[@]}" \
	--sign "${SIGN_IDENTITY}" "${APP}"
codesign --verify --strict "${APP}"

echo "✓ ${APP}"

# Building this script on its own means the .app IS the thing you wanted, so
# hand it over. The two scripts that call bundle.sh as a step set
# SKREPKA_REVEAL=0: run.sh launches the app instead, and notarize.sh reveals its
# own artifact once the ticket is stapled.
#
# `|| true` because a build with no window server -- CI, ssh -- has no Finder to
# reveal into, and a signed .app that already exists is not worth failing over.
if [[ "${SKREPKA_REVEAL:-1}" == "1" ]]; then
	open -R "${APP}" || true
fi
