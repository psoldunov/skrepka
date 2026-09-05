#!/usr/bin/env bash
#
# Produces a build/Skrepka.app that launches on someone else's Mac, plus the
# build/Skrepka.zip to hand them.
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
# the comment on ARCHITECTURES in scripts/bundle.sh.
#
# Credentials come from one of two places, in this order.
#
# An App Store Connect API key, read from .env or from the environment:
#
#   APPLE_API_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
#   APPLE_API_KEY_ID=XXXXXXXXXX
#   APPLE_API_ISSUER=00000000-0000-0000-0000-000000000000
#
# A .p8 issued at appstoreconnect.apple.com, and the same three variables the
# Ensemblr repo's forge.config.ts reads, deliberately: one key notarizes both,
# and an `.env` that already works for one needs no second set of names here.
# Nothing is written to the keychain on this path, which is what makes it the
# one CI can use.
#
# .env is read from the repository root, and SKREPKA_ENV_FILE points somewhere
# else -- at the Ensemblr repo's own .env, say, rather than copying a key path
# into a second file that then drifts. See .env.example for the shape.
#
# Otherwise a notarytool keychain profile, created once:
#
#   xcrun notarytool store-credentials skrepka \
#     --apple-id <your-apple-id> --team-id <team-id> --password <app-specific-password>
#
# where the password is an app-specific one generated at appleid.apple.com, not
# an Apple ID password.
#
# Whichever is used gets checked before anything is built. Submitting is the
# first step that touches the notary service, and it comes after a universal
# release build and a timestamped signature -- minutes of work to find out that
# a credential is missing.

set -euo pipefail

cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Reads KEY=VALUE lines out of an env file. Parsed as data, never sourced:
# `source` executes whatever the file contains, and a file that is edited by
# hand and pasted into from a password manager should not also be a place
# arbitrary shell runs.
#
# A variable already in the environment wins, which is standard .env precedence
# and the property that matters here twice over --
# `APPLE_API_KEY_ID=... scripts/notarize.sh` still overrides the file, and CI
# exporting its own secrets is unaffected by a stale file on the runner.
#
# A missing file is not an error. The keychain-profile path needs no file at
# all, and CI has no .env to read.
read_environment_file() {
	local file="$1"
	local line key value

	if [[ ! -f "${file}" ]]; then
		return 0
	fi

	echo "▸ Reading ${file}"
	# `|| [[ -n "${line}" ]]` so a final line with no trailing newline is still
	# seen -- an editor that does not add one would otherwise drop a credential.
	while IFS= read -r line || [[ -n "${line}" ]]; do
		line="${line%$'\r'}"
		line="${line#"${line%%[![:space:]]*}"}"

		if [[ -z "${line}" || "${line}" == "#"* ]]; then
			continue
		fi

		line="${line#export }"

		if [[ "${line}" != *"="* ]]; then
			continue
		fi

		key="${line%%=*}"
		value="${line#*=}"
		key="${key%"${key##*[![:space:]]}"}"

		# Anything that is not a shell name is a typo, not a variable. Skipping
		# it beats exporting a name nothing will ever read.
		if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
			continue
		fi

		# One matching pair of surrounding quotes, the way a .env gets written.
		# Nothing further: no escapes, no interpolation, no continuation lines.
		# A credential is a literal, and half-implementing shell quoting is how a
		# value silently arrives different from what the file shows.
		if [[ "${value}" == \"*\" || "${value}" == \'*\' ]]; then
			value="${value:1:${#value} - 2}"
		fi

		if [[ -n "${!key:-}" ]]; then
			continue
		fi

		export "${key}=${value}"
	done < "${file}"
}

read_environment_file "${SKREPKA_ENV_FILE:-.env}"

APP_NAME="Skrepka"
APP="build/${APP_NAME}.app"
ZIP="build/${APP_NAME}.zip"
SUBMISSION_JSON="build/notarization.json"
LOG_JSON="build/notarization-log.json"
NOTARY_PROFILE="${SKREPKA_NOTARY_PROFILE:-skrepka}"
NOTARY_TIMEOUT="${SKREPKA_NOTARY_TIMEOUT:-30m}"

# Read the team id out of the keychain rather than duplicating the identity
# string that scripts/bundle.sh owns. Reading it back off the signed .app would
# be equally honest but needs a build first, which is exactly what the check
# below exists to happen before. Only used to make the hint copy-pasteable, so
# an empty result degrades to a placeholder instead of failing.
TEAM_ID="$(security find-identity -v -p codesigning 2> /dev/null |
	sed -n 's/.*"Developer ID Application: .*(\([A-Z0-9]*\))".*/\1/p' | head -1)"

credentials_hint() {
	echo "  either put an App Store Connect API key in .env (see .env.example)," >&2
	echo "  or export the same three variables:" >&2
	echo "    APPLE_API_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8" >&2
	echo "    APPLE_API_KEY_ID=XXXXXXXXXX" >&2
	echo "    APPLE_API_ISSUER=00000000-0000-0000-0000-000000000000" >&2
	echo "  or store a keychain profile once:" >&2
	echo "    xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
	echo "      --apple-id <your-apple-id> --team-id ${TEAM_ID:-<team-id>} \\" >&2
	echo "      --password <app-specific-password>" >&2
}

# The API key wins when it is complete, because it is the credential that needs
# no keychain and so the only one CI can carry.
#
# A partial set is an error rather than a silent fall back to the keychain: one
# missing variable is a typo or an `.env` that did not load, and quietly
# notarizing as somebody else -- or failing on a profile the user never meant to
# use -- hides the actual mistake.
NOTARY_CREDENTIALS=()
CREDENTIALS_SOURCE=""
API_KEY_VARIABLES_SET=0
for value in "${APPLE_API_KEY_PATH:-}" "${APPLE_API_KEY_ID:-}" "${APPLE_API_ISSUER:-}"; do
	[[ -n "${value}" ]] && API_KEY_VARIABLES_SET=$((API_KEY_VARIABLES_SET + 1))
done

if [[ "${API_KEY_VARIABLES_SET}" -eq 3 ]]; then
	# notarytool reports a bad path as a generic authentication failure, which
	# reads like a revoked key rather than a typo. Say which it is.
	if [[ ! -f "${APPLE_API_KEY_PATH}" ]]; then
		echo "error: APPLE_API_KEY_PATH is not a file: ${APPLE_API_KEY_PATH}" >&2
		exit 1
	fi
	NOTARY_CREDENTIALS=(
		--key "${APPLE_API_KEY_PATH}"
		--key-id "${APPLE_API_KEY_ID}"
		--issuer "${APPLE_API_ISSUER}"
	)
	CREDENTIALS_SOURCE="App Store Connect API key ${APPLE_API_KEY_ID}"
elif [[ "${API_KEY_VARIABLES_SET}" -gt 0 ]]; then
	echo "error: APPLE_API_KEY_PATH, APPLE_API_KEY_ID and APPLE_API_ISSUER go" >&2
	echo "error: together -- ${API_KEY_VARIABLES_SET} of the 3 are set. Set the rest, or unset" >&2
	echo "error: all three to fall back to the keychain profile '${NOTARY_PROFILE}'." >&2
	exit 1
else
	NOTARY_CREDENTIALS=(--keychain-profile "${NOTARY_PROFILE}")
	CREDENTIALS_SOURCE="keychain profile '${NOTARY_PROFILE}'"
fi

# `history` is the cheapest authenticated call notarytool has -- it takes no
# archive and it fails exactly the way `submit` would. Running it first turns a
# missing credential from a failure after the build into one before it.
#
# It also tells apart the two cases an offline keychain lookup cannot, both
# measured against notarytool 1.0 rather than assumed:
#
#   no profile      exit 69, "No Keychain password item found for profile: ..."
#   bad password    exit 1,  "HTTP status code: 401. Invalid credentials. ..."
#
# Two codes for one kind of problem, so the exit status is a fragile test. What
# both failures do share is an empty stdout -- neither printed a byte of the
# requested JSON -- while a call that authenticates answers with a list. So the
# response is the test.
#
# Testing the response rather than the status is also what keeps this check from
# blocking a first release: an account that authenticates but has never
# submitted anything still answers, whatever it exits with, and nothing here
# looks inside the list.
#
# stderr is deliberately left uncaptured. notarytool's own message is the most
# useful line on screen, and letting it through unedited means a third kind of
# failure -- offline, notary outage -- reports as itself instead of being
# mislabelled a credential problem.
echo "▸ Checking notary credentials — ${CREDENTIALS_SOURCE}"
CREDENTIALS_RESPONSE="$(xcrun notarytool history \
	"${NOTARY_CREDENTIALS[@]}" \
	--output-format json || true)"

if [[ -z "${CREDENTIALS_RESPONSE}" ]]; then
	echo "error: no answer from the notary service using ${CREDENTIALS_SOURCE}." >&2
	echo "error: if the message above is about credentials, supply them one of" >&2
	echo "error: these two ways:" >&2
	credentials_hint
	exit 1
fi

# Builds and signs with a secure timestamp, and refuses to fall back to ad-hoc
# signing -- an ad-hoc signature can never be notarized.
#
# SKREPKA_REVEAL=0 because the .app at this point has no ticket yet. Revealing it
# here would put the un-notarized build in front of the user, which is the one
# copy of it that must not be sent anywhere.
SKREPKA_NOTARIZE=1 SKREPKA_REVEAL=0 SKREPKA_UNIVERSAL=1 scripts/bundle.sh

echo "▸ Compressing to ${ZIP}"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "▸ Submitting to the notary service — ${CREDENTIALS_SOURCE}"
# The exit code of `submit --wait` reports whether the submission and the wait
# worked, which is not the same question as whether Apple accepted the build.
# Read the status out of the response instead of inferring it.
submit_exit=0
xcrun notarytool submit "${ZIP}" \
	"${NOTARY_CREDENTIALS[@]}" \
	--wait --timeout "${NOTARY_TIMEOUT}" \
	--output-format json > "${SUBMISSION_JSON}" || submit_exit=$?

if ! STATUS="$(plutil -extract status raw -o - "${SUBMISSION_JSON}" 2> /dev/null)"; then
	# The credential check above already ran, so credentials are not the suspect
	# here: what is left is the network, the notary service itself, or the wait
	# running past SKREPKA_NOTARY_TIMEOUT. notarytool has printed its own reason
	# to stderr by now; do not paper over it with a guess.
	echo "error: notarytool returned no submission status (exit ${submit_exit})." >&2
	echo "error: the message above is notarytool's. If it is a credential" >&2
	echo "error: failure after all, re-supply them:" >&2
	credentials_hint
	exit 1
fi

if [[ "${STATUS}" != "Accepted" ]]; then
	SUBMISSION_ID="$(plutil -extract id raw -o - "${SUBMISSION_JSON}" 2> /dev/null || echo "")"
	echo "error: notarization ${STATUS}." >&2
	if [[ -n "${SUBMISSION_ID}" ]]; then
		# The status alone never says which binary failed or why; the log does.
		echo "▸ Fetching the notary log for ${SUBMISSION_ID}" >&2
		if xcrun notarytool log "${SUBMISSION_ID}" \
			"${NOTARY_CREDENTIALS[@]}" "${LOG_JSON}"; then
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
if [[ "${SKREPKA_REVEAL:-1}" == "1" ]]; then
	open -R "${ZIP}" || true
fi
