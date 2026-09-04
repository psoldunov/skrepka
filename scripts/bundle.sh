#!/usr/bin/env bash
#
# Assembles and signs build/Clippy.app from the SwiftPM executable.
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
#   Bundle.main.bundleURL/<Package>_<Target>.bundle    # = Clippy.app/<...>.bundle
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
# So no resource bundle is shipped, and Clippy reaches none: the one dependency
# that has resources, KeyboardShortcuts, is used for hotkey registration and
# storage only. Its Recorder and `Shortcut.description` both go through
# Bundle.module, and Sources/Clippy/Settings/ShortcutRecorderView.swift and
# Sources/Clippy/Platform/ShortcutFormatter.swift replace them.

set -euo pipefail

cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="Clippy"
CONFIGURATION="${CONFIGURATION:-release}"
APP="build/${APP_NAME}.app"
SIGN_IDENTITY="${CLIPPY_SIGN_IDENTITY:-Developer ID Application: Philipp Soldunov (MSU5X4VMMP)}"

echo "▸ Building (${CONFIGURATION})"
swift build -c "${CONFIGURATION}"
BIN_PATH="$(swift build -c "${CONFIGURATION}" --show-bin-path)/${APP_NAME}"

if [[ ! -x "${BIN_PATH}" ]]; then
	echo "error: executable not found at ${BIN_PATH}" >&2
	exit 1
fi

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
	if [[ "${CLIPPY_NOTARIZE:-0}" == "1" ]]; then
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
# scripts/notarize.sh sets CLIPPY_NOTARIZE=1 and pays the round-trip.
if [[ "${CLIPPY_NOTARIZE:-0}" == "1" ]]; then
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
# CLIPPY_REVEAL=0: run.sh launches the app instead, and notarize.sh reveals its
# own artifact once the ticket is stapled.
#
# `|| true` because a build with no window server -- CI, ssh -- has no Finder to
# reveal into, and a signed .app that already exists is not worth failing over.
if [[ "${CLIPPY_REVEAL:-1}" == "1" ]]; then
	open -R "${APP}" || true
fi
