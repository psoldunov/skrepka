#!/usr/bin/env bash
#
# Produces a build/Clippy.app that launches on someone else's Mac, plus the
# build/Clippy.zip to hand them.
#
# Nothing here involves the App Store. Notarization is the Developer ID path:
# Apple scans the binary, returns a ticket, and Gatekeeper stops blocking it.
# Without a ticket, `spctl -a -t exec build/Clippy.app` answers
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
#     default. CLIPPY_NOTARIZE=1 turns it on.
#
# The build is universal (CLIPPY_UNIVERSAL=1) because this is the copy that
# goes to other people's Macs, and four Intel models still run macOS 26. See
# the comment on ARCHITECTURES in scripts/bundle.sh.
#
# Credentials come from a notarytool keychain profile, created once:
#
#   xcrun notarytool store-credentials clippy \
#     --apple-id <your-apple-id> --team-id <team-id> --password <app-specific-password>
#
# An app-specific password is generated at appleid.apple.com, not your Apple ID
# password. An App Store Connect API key works too -- store-credentials takes
# `--key`/`--key-id`/`--issuer` instead.

set -euo pipefail

cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="Clippy"
APP="build/${APP_NAME}.app"
ZIP="build/${APP_NAME}.zip"
SUBMISSION_JSON="build/notarization.json"
LOG_JSON="build/notarization-log.json"
NOTARY_PROFILE="${CLIPPY_NOTARY_PROFILE:-clippy}"
NOTARY_TIMEOUT="${CLIPPY_NOTARY_TIMEOUT:-30m}"

# Builds and signs with a secure timestamp, and refuses to fall back to ad-hoc
# signing -- an ad-hoc signature can never be notarized.
#
# CLIPPY_REVEAL=0 because the .app at this point has no ticket yet. Revealing it
# here would put the un-notarized build in front of the user, which is the one
# copy of it that must not be sent anywhere.
CLIPPY_NOTARIZE=1 CLIPPY_REVEAL=0 CLIPPY_UNIVERSAL=1 scripts/bundle.sh

# Read back from the artifact rather than duplicating the identity string that
# scripts/bundle.sh owns. Only used to make the error hint below copy-pasteable.
TEAM_ID="$(codesign -dvv "${APP}" 2>&1 | sed -n 's/^TeamIdentifier=//p')"

echo "▸ Compressing to ${ZIP}"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "▸ Submitting to the notary service as profile '${NOTARY_PROFILE}'"
# The exit code of `submit --wait` reports whether the submission and the wait
# worked, which is not the same question as whether Apple accepted the build.
# Read the status out of the response instead of inferring it.
submit_exit=0
xcrun notarytool submit "${ZIP}" \
	--keychain-profile "${NOTARY_PROFILE}" \
	--wait --timeout "${NOTARY_TIMEOUT}" \
	--output-format json > "${SUBMISSION_JSON}" || submit_exit=$?

if ! STATUS="$(plutil -extract status raw -o - "${SUBMISSION_JSON}" 2> /dev/null)"; then
	echo "error: notarytool returned no submission status (exit ${submit_exit})." >&2
	echo "error: the keychain profile '${NOTARY_PROFILE}' is the usual cause. Create it with:" >&2
	echo "  xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
	echo "    --apple-id <your-apple-id> --team-id ${TEAM_ID:-<team-id>} --password <app-specific-password>" >&2
	exit 1
fi

if [[ "${STATUS}" != "Accepted" ]]; then
	SUBMISSION_ID="$(plutil -extract id raw -o - "${SUBMISSION_JSON}" 2> /dev/null || echo "")"
	echo "error: notarization ${STATUS}." >&2
	if [[ -n "${SUBMISSION_ID}" ]]; then
		# The status alone never says which binary failed or why; the log does.
		echo "▸ Fetching the notary log for ${SUBMISSION_ID}" >&2
		if xcrun notarytool log "${SUBMISSION_ID}" \
			--keychain-profile "${NOTARY_PROFILE}" "${LOG_JSON}"; then
			cat "${LOG_JSON}" >&2
			echo "error: full log at ${LOG_JSON}" >&2
		fi
	fi
	exit 1
fi

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

echo "✓ ${APP}"
echo "✓ ${ZIP} — notarized and stapled, safe to send"

# The zip and not the .app: this script's product is the thing you hand to
# someone, and the zip is the copy that carries the stapled ticket. Both sit in
# build/, so the folder that opens holds the app either way.
#
# `|| true` for the same reason as in bundle.sh -- no window server, no Finder,
# and the artifacts are already on disk.
if [[ "${CLIPPY_REVEAL:-1}" == "1" ]]; then
	open -R "${ZIP}" || true
fi
