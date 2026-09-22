# shellcheck shell=bash
#
# What scripts/notarize.sh and scripts/make-dmg.sh share: the .env reader, the
# notary credentials, one submission to the notary service, and the names the
# macOS release assets go by. Sourced, never run: it defines functions and a few
# variables, and runs nothing on its own.
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

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

NOTARY_PROFILE="${SKREPKA_NOTARY_PROFILE:-skrepka}"
NOTARY_TIMEOUT="${SKREPKA_NOTARY_TIMEOUT:-30m}"
NOTARY_CREDENTIALS=()
CREDENTIALS_SOURCE=""

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

credentials_hint() {
	# Read the team id out of the keychain rather than duplicating the identity
	# string that scripts/bundle.sh owns. Only used to make the hint
	# copy-pasteable, so an empty result degrades to a placeholder instead of
	# failing.
	local team_id
	team_id="$(security find-identity -v -p codesigning 2> /dev/null |
		sed -n 's/.*"Developer ID Application: .*(\([A-Z0-9]*\))".*/\1/p' | head -1)"
	echo "  either put an App Store Connect API key in .env (see .env.example)," >&2
	echo "  or export the same three variables:" >&2
	echo "    APPLE_API_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8" >&2
	echo "    APPLE_API_KEY_ID=XXXXXXXXXX" >&2
	echo "    APPLE_API_ISSUER=00000000-0000-0000-0000-000000000000" >&2
	echo "  or store a keychain profile once:" >&2
	echo "    xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
	echo "      --apple-id <your-apple-id> --team-id ${team_id:-<team-id>} \\" >&2
	echo "      --password <app-specific-password>" >&2
}

# Chooses the credential and checks it, before anything is built or submitted.
#
# The API key wins when it is complete, because it is the credential that needs
# no keychain and so the only one CI can carry.
#
# A partial set is an error rather than a silent fall back to the keychain: one
# missing variable is a typo or an `.env` that did not load, and quietly
# notarizing as somebody else -- or failing on a profile the user never meant to
# use -- hides the actual mistake.
prepare_notary_credentials() {
	local value count=0
	for value in "${APPLE_API_KEY_PATH:-}" "${APPLE_API_KEY_ID:-}" "${APPLE_API_ISSUER:-}"; do
		[[ -n "${value}" ]] && count=$((count + 1))
	done

	if [[ "${count}" -eq 3 ]]; then
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
	elif [[ "${count}" -gt 0 ]]; then
		echo "error: APPLE_API_KEY_PATH, APPLE_API_KEY_ID and APPLE_API_ISSUER go" >&2
		echo "error: together -- ${count} of the 3 are set. Set the rest, or unset" >&2
		echo "error: all three to fall back to the keychain profile '${NOTARY_PROFILE}'." >&2
		exit 1
	else
		NOTARY_CREDENTIALS=(--keychain-profile "${NOTARY_PROFILE}")
		CREDENTIALS_SOURCE="keychain profile '${NOTARY_PROFILE}'"
	fi

	# `history` is the cheapest authenticated call notarytool has -- it takes no
	# archive and it fails exactly the way `submit` would. Running it first turns
	# a missing credential from a failure after the build into one before it.
	#
	# It also tells apart the two cases an offline keychain lookup cannot:
	#
	#   no profile      exit 69, "No Keychain password item found for profile: ..."
	#   bad password    exit 1,  "HTTP status code: 401. Invalid credentials. ..."
	#
	# The first was measured against notarytool 1.1.2 (41). The second is from
	# notarytool's documented 401 handling and has not been reproduced here -- it
	# needs a stored profile with a deliberately wrong password. Nothing below
	# depends on either number.
	#
	# Two codes for one kind of problem, so the exit status is a fragile test.
	# What both failures do share is an empty stdout -- neither printed a byte of
	# the requested JSON -- while a call that authenticates answers with a list.
	# So the response is the test.
	#
	# Testing the response rather than the status is also what keeps this check
	# from blocking a first release: an account that authenticates but has never
	# submitted anything still answers, whatever it exits with, and nothing here
	# looks inside the list.
	#
	# stderr is deliberately left uncaptured. notarytool's own message is the most
	# useful line on screen, and letting it through unedited means a third kind
	# of failure -- offline, notary outage -- reports as itself instead of being
	# mislabelled a credential problem.
	echo "▸ Checking notary credentials — ${CREDENTIALS_SOURCE}"
	local response
	response="$(xcrun notarytool history \
		"${NOTARY_CREDENTIALS[@]}" \
		--output-format json || true)"

	if [[ -z "${response}" ]]; then
		echo "error: no answer from the notary service using ${CREDENTIALS_SOURCE}." >&2
		echo "error: if the message above is about credentials, supply them" >&2
		echo "error: one of these ways:" >&2
		credentials_hint
		exit 1
	fi
}

# notarize FILE LABEL — submits FILE (a zip or a dmg), waits for the verdict,
# and exits the script unless Apple accepted it. LABEL names the files the
# response and the log are kept in, build/notarization-LABEL*.json.
notarize() {
	local file="$1" label="$2"
	local submission="build/notarization-${label}.json"
	local log="build/notarization-${label}-log.json"
	local submit_exit=0 status id

	echo "▸ Submitting ${file} to the notary service — ${CREDENTIALS_SOURCE}"
	# The exit code of `submit --wait` reports whether the submission and the wait
	# worked, which is not the same question as whether Apple accepted the build.
	# Read the status out of the response instead of inferring it.
	xcrun notarytool submit "${file}" \
		"${NOTARY_CREDENTIALS[@]}" \
		--wait --timeout "${NOTARY_TIMEOUT}" \
		--output-format json > "${submission}" || submit_exit=$?

	if ! status="$(plutil -extract status raw -o - "${submission}" 2> /dev/null)"; then
		# The credential check already ran, so credentials are not the suspect
		# here: what is left is the network, the notary service itself, or the
		# wait running past SKREPKA_NOTARY_TIMEOUT. notarytool has printed its own
		# reason to stderr by now; do not paper over it with a guess.
		echo "error: notarytool returned no submission status (exit ${submit_exit})." >&2
		echo "error: the message above is notarytool's. If it is a credential" >&2
		echo "error: failure after all, re-supply them:" >&2
		credentials_hint
		exit 1
	fi

	if [[ "${status}" != "Accepted" ]]; then
		id="$(plutil -extract id raw -o - "${submission}" 2> /dev/null || echo "")"
		echo "error: notarization ${status}." >&2
		if [[ -n "${id}" ]]; then
			# The status alone never says which binary failed or why; the log does.
			echo "▸ Fetching the notary log for ${id}" >&2
			if xcrun notarytool log "${id}" "${NOTARY_CREDENTIALS[@]}" "${log}"; then
				cat "${log}" >&2
				echo "error: full log at ${log}" >&2
			fi
		fi
		exit 1
	fi
}

# mac_asset_name APP — the name the release assets built from APP go by, before
# the extension: skrepka-macos-<arch>, the macOS counterpart of
# skrepka-linux-x86_64. <arch> is read off the executable rather than assumed,
# `universal` when it carries both slices. No version, for the reason the Linux
# assets carry none: /releases/latest/download/ only resolves a name that is the
# same in every release.
mac_asset_name() {
	local app="$1" executable archs
	executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app}/Contents/Info.plist")"
	archs=" $(lipo -archs "${app}/Contents/MacOS/${executable}") "
	if [[ "${archs}" == *" arm64 "* && "${archs}" == *" x86_64 "* ]]; then
		echo "skrepka-macos-universal"
	elif [[ "${archs}" == " arm64 " || "${archs}" == " x86_64 " ]]; then
		echo "skrepka-macos-${archs// /}"
	else
		echo "error: ${app} has unexpected architectures:${archs}" >&2
		exit 1
	fi
}

# write_checksum FILE — FILE.sha256 beside it, in `sha256sum` format with the
# bare file name, as scripts/build-deck.sh writes the Linux assets' checksums.
write_checksum() {
	local file="$1"
	(cd "$(dirname "${file}")" && shasum -a 256 "$(basename "${file}")") > "${file}.sha256"
}
