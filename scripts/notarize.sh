#!/usr/bin/env bash
#
# Produces a build/Skrepka.app that launches on someone else's Mac, and the two
# release assets to hand them, named the way the Linux ones are:
#
#   build/skrepka-macos-universal.zip   the stapled app, zipped
#   build/skrepka-macos-universal.dmg   the same app on a notarized disk image,
#                                       made by scripts/make-dmg.sh
#   a .sha256 beside each
#
# Nothing here involves the App Store. Notarization is the Developer ID path:
# Apple scans the binary, returns a ticket, and Gatekeeper stops blocking it.
# Without a ticket, `spctl -a -t exec build/Skrepka.app` answers
#
#   rejected
#   source=Unnotarized Developer ID
#
# and since macOS 15 there is no Control-click bypass -- the recipient hits a
# hard block on first launch and has to go digging in System Settings ->
# Privacy & Security to allow it.
#
# Three details that are easy to get wrong, and all three cost a full round-trip
# to Apple to discover:
#
#   * The notary service takes a ZIP, PKG or DMG. A bare .app cannot be
#     submitted, hence the `ditto` step.
#   * The ticket is attached to the .app by `stapler`, not by the submission.
#     So the archive that was submitted does NOT contain the ticket, and the
#     zip has to be rebuilt AFTER stapling. Ship the second one.
#   * The signature needs a secure timestamp, which scripts/bundle.sh omits by
#     default. SKREPKA_NOTARIZE=1 turns it on.
#
# The build is universal (SKREPKA_UNIVERSAL=1) because this is the copy that
# goes to other people's Macs, and four Intel models still run macOS 26. See
# the comment on ARCHITECTURES in scripts/bundle.sh. The asset names say so
# because scripts/lib/mac-release.sh reads the slices off the built binary.
#
# Credentials are an App Store Connect API key from .env or the environment, or
# a notarytool keychain profile; scripts/lib/mac-release.sh documents both and
# the order they are tried in. Whichever is used gets checked before anything
# is built. Submitting is the first step that touches the notary service, and it
# comes after a universal release build and a timestamped signature -- minutes
# of work to find out that a credential is missing.

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/mac-release.sh
source scripts/lib/mac-release.sh

read_environment_file "${SKREPKA_ENV_FILE:-.env}"
prepare_notary_credentials

APP="build/Skrepka.app"

# Builds and signs with a secure timestamp, and refuses to fall back to ad-hoc
# signing -- an ad-hoc signature can never be notarized.
#
# SKREPKA_REVEAL=0 because the .app at this point has no ticket yet. Revealing it
# here would put the un-notarized build in front of the user, which is the one
# copy of it that must not be sent anywhere.
SKREPKA_NOTARIZE=1 SKREPKA_REVEAL=0 SKREPKA_UNIVERSAL=1 scripts/bundle.sh

ZIP="build/$(mac_asset_name "${APP}").zip"

echo "▸ Compressing to ${ZIP}"
rm -f "${ZIP}" "${ZIP}.sha256"
ditto -c -k --keepParent "${APP}" "${ZIP}"

notarize "${ZIP}" zip

echo "▸ Stapling the ticket"
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"

# The submitted archive predates the ticket, so it is not the one to ship.
echo "▸ Recompressing ${ZIP} with the stapled ticket"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"

# The real gate, and the only check that answers the question the recipient's
# Mac will ask. Exits non-zero on a rejection, which fails the script.
echo "▸ Gatekeeper verdict"
spctl --assess --verbose=4 --type exec "${APP}"

write_checksum "${ZIP}"

echo "✓ ${APP}"
echo "✓ ${ZIP} — notarized and stapled, safe to send"

# The disk image, from the app just stapled. Its own script, so an image can be
# made again from this build without notarizing the app a second time. It
# reveals what it built in Finder unless told not to, which is this script's
# SKREPKA_REVEAL to pass on: the image is the thing to hand someone, and it sits
# in build/ beside the zip and the app.
scripts/make-dmg.sh
