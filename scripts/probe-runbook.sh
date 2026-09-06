#!/usr/bin/env bash
#
# Two skrepka-sync-probe peers, driven against each other over loopback.
#
# This is the half of docs/linux-sync/phase-3-runbook.md that does not need a
# person at the keyboard: pairing and refusing a pairing, history in both
# directions, live push and the platform rule that governs it, pins, deletions
# that stay deleted, and unpairing. The steps that need a real pasteboard, a
# password manager or a second physical machine are not here and cannot be —
# see the runbook.
#
# It is deliberately NOT part of scripts/doctor.sh. It starts two processes,
# opens sockets, and waits on wall-clock time; a gate that does those things
# fails for reasons that have nothing to do with the change under test.
#
#   scripts/probe-runbook.sh              both scenarios
#   scripts/probe-runbook.sh cross        cross-platform pair only
#   scripts/probe-runbook.sh apple        two-Apple-devices pair only
#   KEEP=1 scripts/probe-runbook.sh       leave the working directory behind

set -uo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

BIN="${BIN:-.build/debug/skrepka-sync-probe}"
SCENARIO="${1:-all}"

bold() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
pass() { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m  ✗ %s\033[0m\n' "$1"; FAILED=$((FAILED + 1)); }

FAILED=0

if [[ ! -x "${BIN}" ]]; then
	echo "building the probe…"
	swift build --product skrepka-sync-probe > /dev/null || exit 1
	BIN=$(swift build --product skrepka-sync-probe --show-bin-path)/skrepka-sync-probe
fi
BIN="$(cd "$(dirname "${BIN}")" && pwd)/$(basename "${BIN}")"

# Two peers, each reading commands from a fifo held open for the run.
#
# `exec <>` rather than `exec >`: opening a fifo write-only blocks until a reader
# arrives, and the reader is the process this has not started yet.
# start_peers <alpha-platform> <beta-platform> [existing-workdir]
#
# Passing a directory relaunches two peers against stores they already have,
# which is what makes "they reconnect without asking again" testable.
start_peers() {
	WORK="${3:-$(mktemp -d "${TMPDIR:-/tmp}/skrepka-probe.XXXXXX")}"
	rm -f "${WORK}/a.in" "${WORK}/b.in"
	mkfifo "${WORK}/a.in" "${WORK}/b.in"
	exec 3<> "${WORK}/a.in"
	exec 4<> "${WORK}/b.in"

	(cd "${WORK}" && "${BIN}" run --dir ./a --name alpha --platform "$1" --pair --confirm-pairing \
		> a.out 2>&1 < a.in) &
	PEER_A=$!
	(cd "${WORK}" && "${BIN}" run --dir ./b --name beta --platform "$2" \
		> b.out 2>&1 < b.in) &
	PEER_B=$!
	sleep 2

	A_PAIR=$(grep -o 'pairing  port [0-9]*' "${WORK}/a.out" | head -1 | awk '{print $3}')
	A_SYNC=$(grep -o 'sync     port [0-9]*' "${WORK}/a.out" | head -1 | awk '{print $3}')
}

# stop_peers [keep]
#
# `keep` leaves the working directory for a relaunch. Otherwise it goes, unless
# KEEP is set in the environment.
stop_peers() {
	say_a quit
	say_b quit
	sleep 1
	kill "${PEER_A}" "${PEER_B}" 2> /dev/null
	wait 2> /dev/null
	exec 3>&- 4>&-
	if [[ -n "${1:-}" ]]; then return; fi
	if [[ -n "${KEEP:-}" ]]; then
		echo "  logs: ${WORK}"
	else
		rm -r "${WORK}"
	fi
}

say_a() { printf '%s\n' "$*" >&3; }
say_b() { printf '%s\n' "$*" >&4; }

# expect <name> <file> <pattern>
expect() {
	if grep -q -- "$3" "${WORK}/$2"; then pass "$1"; else fail "$1 (no /$3/ in $2)"; fi
}

# refute <name> <file> <pattern>
refute() {
	if grep -q -- "$3" "${WORK}/$2"; then fail "$1 (found /$3/ in $2)"; else pass "$1"; fi
}

# MARK: - Cross-platform: the pair live push exists for

scenario_cross() {
	bold "cross-platform pair — linux ↔ macos"
	start_peers linux macos

	say_b "connect 127.0.0.1 ${A_PAIR} ${A_SYNC}"
	sleep 3
	expect "step 1 — both ends derive the same code" a.out "pairing request"
	CODE=$(grep -o 'code    [0-9A-F-]*' "${WORK}/a.out" | head -1 | awk '{print $2}')
	say_a accept
	sleep 4
	expect "step 1 — the code the initiator saw is the same one" b.out "code was ${CODE}"
	expect "step 1 — the initiator pinned the peer" b.out "paired with"
	# The platform arrives in `hello`, which a pairing connection may not carry,
	# so this is only true once the first handshake has replaced what pairing
	# recorded — which is the whole point of the check.
	say_b peers
	sleep 2
	expect "the handshake replaces the unknown platform pairing recorded" b.out "alpha (linux)"

	say_a "add hello from alpha"
	sleep 3
	expect "step 4 — a live push lands on the cross-platform peer" b.out "^live push  "
	say_b "add hello from beta"
	sleep 3
	say_a sync
	say_b sync
	sleep 4
	say_a list
	say_b list
	sleep 2
	expect "step 3 — history reaches alpha" a.out "hello from beta"
	expect "step 3 — history reaches beta" b.out "hello from alpha"

	say_b "pin b4b7"
	sleep 1
	say_a sync
	sleep 4
	say_a list
	sleep 2
	expect "step 6 — a pin propagates" a.out "pinned"

	say_a "delete a3a3"
	sleep 1
	say_a sync
	say_b sync
	sleep 5
	say_b sync
	sleep 4
	say_b list
	sleep 2
	if [[ $(grep -c 'hello from alpha' "${WORK}/b.out") -le 3 ]]; then
		pass "step 7 — a deletion is not resurrected by a later sync"
	else
		fail "step 7 — the deleted item came back"
	fi

	# Relaunched against the same two stores, so this is about what survived
	# being written down: the device identity, the pin, and the history.
	local kept="${WORK}"
	local identity
	identity=$(grep -o '^device   [0-9a-f]*' "${WORK}/a.out" | head -1 | awk '{print $2}')
	stop_peers keep
	start_peers linux macos "${kept}"
	sleep 3
	say_a peers
	say_b peers
	say_a list
	sleep 3
	# The log is truncated by the relaunch, so what this reads is the new run's
	# own `device` line. Equal to the old one means the certificate came back off
	# disk; a different one means it was regenerated, and every peer that pinned
	# the old one is now talking to a stranger.
	expect "step 1 — the identity survives a relaunch" a.out "^device   ${identity}"
	expect "step 1 — the pin survives, and no sheet is raised again" b.out "^  paired  "
	refute "step 1 — nothing asked to pair a second time" b.out "pairing request"
	expect "history survives a relaunch" a.out "hello from beta"

	stop_peers
}

# MARK: - Two Apple devices: the pair live push must stay out of

scenario_apple() {
	bold "two Apple devices — macos ↔ macos"
	start_peers macos macos

	say_b "connect 127.0.0.1 ${A_PAIR} ${A_SYNC}"
	sleep 3
	say_a reject
	sleep 3
	say_a peers
	say_b peers
	sleep 2
	expect "step 2 — the refusal reaches the initiator" b.out "declined the pairing"
	refute "step 2 — nothing is paired on the refusing end" a.out "^  paired  "
	refute "step 2 — nothing is paired on the asking end" b.out "^  paired  "

	say_b "connect 127.0.0.1 ${A_PAIR} ${A_SYNC}"
	sleep 3
	say_a accept
	sleep 4
	say_b "add hello from beta"
	sleep 3
	say_a sync
	sleep 4
	say_a list
	sleep 2
	expect "step 11 — history still crosses between two Macs" a.out "hello from beta"
	refute "step 11 — live push does not, because Universal Clipboard does" a.out "^live push  "

	# Prints the paired row this reads the fingerprint out of. Before the
	# pairing was accepted there is no such row, which is what the two `refute`s
	# above rely on.
	say_a peers
	sleep 2
	expect "step 11 — the row says the default is being followed" a.out "live push: followsPlatformDefault"
	PEER=$(grep -o '^  paired  [0-9a-f]*' "${WORK}/a.out" | head -1 | awk '{print $2}')
	say_a "unpair ${PEER}"
	sleep 3
	expect "step 12 — the pin is forgotten" a.out "forgot "
	# The ex-peer keeps trying, and its handshake is now refused at TLS. Its own
	# retry backoff is seconds, so this waits for one full cycle rather than for
	# the next `sync`, which only shortens a wait the link is not in.
	say_b sync
	sleep 12
	say_b peers
	sleep 2
	expect "step 12 — the ex-peer's certificate is no longer accepted" b.out "sslError"

	stop_peers
}

case "${SCENARIO}" in
	cross) scenario_cross ;;
	apple) scenario_apple ;;
	all)
		scenario_cross
		scenario_apple
		;;
	*)
		echo "usage: scripts/probe-runbook.sh [cross|apple|all]"
		exit 2
		;;
esac

printf '\n'
if ((FAILED)); then
	printf '\033[31m✗ %d check(s) failed\033[0m\n' "${FAILED}"
	exit 1
fi
printf '\033[32m✓ probe runbook clean\033[0m\n'
