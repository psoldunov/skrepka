#!/usr/bin/env bash
#
# Wraps a notarized build/Skrepka.app in a disk image a release can carry:
#
#   build/skrepka-macos-universal.dmg          Skrepka.app and a link to
#                                              /Applications, to drag it onto
#   build/skrepka-macos-universal.dmg.sha256   in `sha256sum` format
#
#   scripts/make-dmg.sh     after scripts/notarize.sh, which runs it
#
# The image is signed with the identity that signed the app, then notarized and
# stapled in its own right. The app inside is already notarized and stapled, so
# it launches wherever it is copied to; the image's own ticket is what lets
# Gatekeeper open the .dmg without a warning the moment it is downloaded. Both
# tickets cost a round-trip to Apple, and the app's is not repeated here: this
# refuses an app that has none.
#
# Run it alone to make the image again from the last notarized build without
# notarizing the app a second time.
#
# No styled Finder window — background picture, icon positions. Laying one out
# means scripting Finder with AppleScript against a mounted image, which needs a
# logged-in GUI session and breaks headless; the plain window with the app and
# the Applications link is the part a user needs.

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/mac-release.sh
source scripts/lib/mac-release.sh

APP="build/Skrepka.app"
VOLUME_NAME="Skrepka"

if [[ ! -d "${APP}" ]]; then
	echo "error: ${APP} is missing; run scripts/notarize.sh first." >&2
	exit 1
fi
if ! xcrun stapler validate "${APP}" > /dev/null 2>&1; then
	echo "error: ${APP} carries no notarization ticket; run scripts/notarize.sh" >&2
	echo "error: first — an image of an un-notarized app would be refused anyway." >&2
	exit 1
fi

read_environment_file "${SKREPKA_ENV_FILE:-.env}"
prepare_notary_credentials

ASSET="build/$(mac_asset_name "${APP}")"
DMG="${ASSET}.dmg"

# The identity the app was signed with, read off its signature, so the image
# and the app cannot disagree and the identity string stays scripts/bundle.sh's.
IDENTITY="$(codesign -dvv "${APP}" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)"
if [[ -z "${IDENTITY}" ]]; then
	echo "error: ${APP} is not signed with a Developer ID identity." >&2
	exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

echo "▸ Laying out the image"
# ditto, not cp: it keeps the bundle's extended attributes and the stapled
# ticket exactly as they are, as the zip scripts/notarize.sh builds does.
ditto "${APP}" "${STAGING}/Skrepka.app"
ln -s /Applications "${STAGING}/Applications"

echo "▸ Creating ${DMG}"
# UDZO, zlib-compressed read-only: every macOS and every tool that inspects a
# .dmg on other systems reads it. HFS+ rather than hdiutil's choice of the day,
# so the format does not change under the script with a macOS update.
hdiutil create \
	-volname "${VOLUME_NAME}" \
	-srcfolder "${STAGING}" \
	-fs HFS+ \
	-format UDZO \
	-ov \
	"${DMG}" > /dev/null

echo "▸ Signing ${DMG} as: ${IDENTITY}"
codesign --force --timestamp --sign "${IDENTITY}" "${DMG}"
codesign --verify --strict "${DMG}"

notarize "${DMG}" dmg

echo "▸ Stapling the ticket"
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"

# What a recipient's Mac asks of a downloaded image before it mounts it.
echo "▸ Gatekeeper verdict"
spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG}"

write_checksum "${DMG}"

echo "✓ ${DMG} — notarized and stapled, safe to send"
echo "✓ ${DMG}.sha256"

# `|| true`: no window server, no Finder, and the image is already on disk.
if [[ "${SKREPKA_REVEAL:-1}" == "1" ]]; then
	open -R "${DMG}" || true
fi
