# shellcheck shell=bash
#
# Where a Linux Swift command runs. Sourced by scripts/linux-env.sh and by every
# Linux script that needs the toolchain; not run on its own.
#
# Three runners, chosen in this order unless SKREPKA_LINUX_RUNNER names one:
#
#   native     `swift` 6.3 or newer is already on PATH, and pkg-config finds the
#              system libraries Package.swift's C targets name. True on a
#              Linux box set up for this package, and true inside the other two
#              runners, which is what stops a script that re-enters itself from
#              looping. A toolchain alone is not enough: a general-purpose
#              Swift install with no GTK or Wayland headers would be picked and
#              then fail halfway through the first build.
#   nix        a Linux host with `nix`: the FHS sandbox nix/dev-env.nix builds,
#              holding Swift 6.3.3 and the Ubuntu 24.04-era libraries the
#              targets link. Built once into .build-nix/dev-env and reused
#              until flake.nix, flake.lock or nix/dev-env.nix changes.
#   container  scripts/linux.sh and the skrepka-linux build image. The only
#              runner on macOS, and the fallback on a Linux host with Docker
#              but neither of the others.
#
# The nix runner's out-link lives in .build-nix rather than .build-linux on
# purpose: `swift package clean --scratch-path .build-linux` empties the whole
# scratch directory, the out-link with it.

SKREPKA_LINUX_MIN_SWIFT="6.3"

# The pkg-config modules behind Package.swift's `.systemLibrary` targets:
# CSQLite, CWaylandClient, CX11 and CGtk4.
SKREPKA_LINUX_PKG_CONFIG_MODULES=(sqlite3 wayland-client xfixes gtk4-layer-shell-0)

# linux_env_repository — the repository root, whatever the caller's cwd.
linux_env_repository() {
	(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
}

# linux_env_swift_ok — whether the `swift` on PATH is new enough to build this
# package. `swift --version` prints "Swift version 6.3.3 (swift-6.3.3-RELEASE)"
# on Linux; `sort -V` compares the version against the floor.
linux_env_swift_ok() {
	command -v swift > /dev/null 2>&1 || return 1
	local output version
	output="$(swift --version 2> /dev/null)" || return 1
	version="$(printf '%s\n' "${output}" | sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)*).*/\1/p' | head -n 1)"
	[[ -n "${version}" ]] || return 1
	[[ "$(printf '%s\n%s\n' "${SKREPKA_LINUX_MIN_SWIFT}" "${version}" | sort -V | head -n 1)" == "${SKREPKA_LINUX_MIN_SWIFT}" ]]
}

# linux_env_native_ok — whether this machine can build the package as it is.
linux_env_native_ok() {
	linux_env_swift_ok || return 1
	command -v pkg-config > /dev/null 2>&1 || return 1
	pkg-config --exists "${SKREPKA_LINUX_PKG_CONFIG_MODULES[@]}"
}

# linux_env_runner — prints native, nix, container or none.
linux_env_runner() {
	# Already inside the nix sandbox or the container: whatever is on PATH is
	# the toolchain, even if SKREPKA_LINUX_RUNNER asks for the runner we are in.
	if [[ -n "${SKREPKA_LINUX_ENV:-}" ]]; then
		echo native
		return 0
	fi
	case "${SKREPKA_LINUX_RUNNER:-}" in
		native | nix | container)
			echo "${SKREPKA_LINUX_RUNNER}"
			return 0
			;;
		"") ;;
		*)
			echo "SKREPKA_LINUX_RUNNER must be native, nix or container, not ${SKREPKA_LINUX_RUNNER}." >&2
			return 1
			;;
	esac
	if [[ "$(uname -s)" != "Linux" ]]; then
		echo container
	elif linux_env_native_ok; then
		echo native
	elif command -v nix > /dev/null 2>&1 && [[ "$(uname -m)" == "x86_64" ]]; then
		echo nix
	elif command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
		echo container
	else
		echo none
	fi
}

# linux_env_nix_launcher — builds the nix sandbox if it is missing or stale and
# prints the path of its launcher.
#
# Staleness is a hash of the three files that define the sandbox, not their
# mtimes: a checkout or a rebase touches mtimes without changing anything, and
# the out-link's own mtime is the store's epoch.
linux_env_nix_launcher() {
	local repository link stamp wanted
	repository="$(linux_env_repository)"
	link="${repository}/.build-nix/dev-env"
	stamp="${repository}/.build-nix/dev-env.inputs"
	wanted="$(cd "${repository}" && cat flake.nix flake.lock nix/dev-env.nix | sha256sum | cut -d ' ' -f 1)"

	if [[ ! -x "${link}/bin/skrepka-dev" ]] || [[ "$(cat "${stamp}" 2> /dev/null)" != "${wanted}" ]]; then
		mkdir -p "${repository}/.build-nix"
		echo "▸ building the Linux dev environment (nix/dev-env.nix)" >&2
		echo "  The first build downloads the Swift toolchain, about 1 GB; later ones are instant." >&2
		# The flake reference is the git checkout, so nix sees tracked files
		# only — nix/dev-env.nix has to be committed or `git add`ed to count.
		nix --extra-experimental-features 'nix-command flakes' \
			build "${repository}#linux-dev-env" --out-link "${link}" >&2 || return 1
		printf '%s\n' "${wanted}" > "${stamp}"
	fi
	printf '%s\n' "${link}/bin/skrepka-dev"
}

# linux_env_exec <runner> <command…> — runs the command under that runner and
# never returns. With no command, an interactive shell.
linux_env_exec() {
	local runner="$1"
	shift
	local repository launcher
	repository="$(linux_env_repository)"
	case "${runner}" in
		native)
			if (($# == 0)); then
				exec bash
			fi
			exec "$@"
			;;
		nix)
			launcher="$(linux_env_nix_launcher)" || exit 1
			exec "${launcher}" "$@"
			;;
		container)
			exec "${repository}/scripts/linux.sh" "$@"
			;;
		*)
			echo "No Linux toolchain to run this with. Any one of these works:" >&2
			echo "  - Swift ${SKREPKA_LINUX_MIN_SWIFT} or newer on PATH (https://www.swift.org/install/linux/)" >&2
			echo "    and the -dev packages docker/Dockerfile.linux installs" >&2
			echo "  - nix, which builds nix/dev-env.nix (x86_64 only)" >&2
			echo "  - Docker, with scripts/linux-image.sh run once to build the image" >&2
			echo "SKREPKA_LINUX_RUNNER=native|nix|container picks one explicitly." >&2
			exit 1
			;;
	esac
}

# linux_env_reenter <script> <args…> — returns if this process already has the
# toolchain; otherwise re-runs the script under the resolved runner and never
# returns. For scripts that start with it, so the rest of the file can assume
# `swift` is on PATH.
linux_env_reenter() {
	local runner
	runner="$(linux_env_runner)" || exit 1
	if [[ "${runner}" == "native" ]]; then
		return 0
	fi
	printf '\033[1m▸ running %s under the %s runner\033[0m\n' "$1" "${runner}" >&2
	linux_env_exec "${runner}" "$@"
}
