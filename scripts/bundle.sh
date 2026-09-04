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

echo "▸ Signing as: ${SIGN_IDENTITY}"
if ! security find-identity -v -p codesigning | grep -qF "${SIGN_IDENTITY}"; then
	echo "warning: identity not found, falling back to ad-hoc signing." >&2
	echo "warning: Accessibility permission will be re-prompted on every rebuild." >&2
	SIGN_IDENTITY="-"
fi

codesign --force --options runtime --timestamp=none \
	--sign "${SIGN_IDENTITY}" "${APP}"
codesign --verify --strict "${APP}"

echo "✓ ${APP}"
